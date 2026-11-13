import json
import math
import os
from pathlib import Path
import re

import kb_apply as ka
import kb_homes
import kb_tasks as kt
import kb_vault as kv
import repo_memory as rm

REPORT_KEEP = 12
SLICES = 4
WALK_DEPTH = 5
WALK_SKIP = {'node_modules', 'bin', 'obj', 'dist', 'build', 'target', '__pycache__'}


def environments():
    homes = [(Path.home(), rm.config_dir() / 'secrets.json', False)]
    roots = os.environ.get('CLAUDEFILES_KB_BOX_HOMES', str(Path.home() / 'homes'))
    for root in filter(None, roots.split(os.pathsep)):
        for home in sorted(Path(root).glob('*')):
            config = home / '.config/claudefiles/secrets.json'
            if config.is_file():
                homes.append((home, config, True))
    result = []
    for home, config, container in homes:
        try:
            result.append(kb_homes.environment(home, rm.json_read(config, {}) or {}, container))
        except (ValueError, json.JSONDecodeError):
            continue
    return result


def slug(path):
    return re.sub(r'[^a-zA-Z0-9]', '-', str(path))


def slug_table(envs):
    homes = {str(env['home'].resolve()) for env in envs}
    table = {}
    for env in envs:
        base = env['home'].resolve()
        for current, dirs, _ in os.walk(base):
            depth = len(Path(current).relative_to(base).parts)
            dirs[:] = [d for d in dirs if not d.startswith('.') and d not in WALK_SKIP and depth < WALK_DEPTH
                       and os.path.join(current, d) not in homes]
            table.setdefault(slug(current), []).append((Path(current), env))
    return table


def legacy(vault, envs):
    vault = Path(vault)
    sources = sorted(d for d in vault.glob('projects/*/memory') if d.is_dir())
    if not sources:
        return []
    table = slug_table(envs)
    result = []
    for source in sources:
        hits = table.get(source.parent.name, [])
        entry = dict(source=source.relative_to(vault).as_posix(), home=None, folder=None, reason=None)
        if len(hits) != 1:
            entry['reason'] = 'папка не найдена' if not hits else 'несколько подходящих папок'
        else:
            folder, env = hits[0]
            entry['folder'] = str(folder)
            try:
                home = kb_homes.home_for(vault, env, folder, create_local_id=False)
            except (LookupError, ValueError) as error:
                entry['reason'] = str(error)
            else:
                if home:
                    entry['home'] = home['memory']
                else:
                    entry['reason'] = 'для папки нет дома памяти'
        result.append(entry)
    return result


def adopted(vault):
    vault = Path(vault)
    pairs = []
    records = sorted(vault.glob('repositories/*/.adopted.json')) + sorted(vault.glob('contexts/*/projects/*/.adopted.json'))
    for record in records:
        home = record.parent.relative_to(vault).as_posix()
        for source in rm.json_read(record, []) or []:
            if (vault / source).is_dir():
                pairs.append((source, home))
    return pairs


def _plain_files(root):
    for path in sorted(root.rglob('*')):
        rel = path.relative_to(root)
        if path.is_file() and not path.is_symlink() and not any(part.startswith('.') for part in rel.parts):
            yield path, rel


def duplicate_ops(vault, pairs):
    vault = Path(vault)
    ops = []
    for source, home in pairs:
        for path, rel in _plain_files(vault / source):
            if len(rel.parts) == 1 and rel.name in kv.INDEX_NAMES:
                continue
            twin = vault / home / rel
            if not twin.is_file():
                continue
            copy_bytes, twin_bytes = path.read_bytes(), twin.read_bytes()
            if copy_bytes != twin_bytes:
                continue
            copy_rel = path.relative_to(vault).as_posix()
            twin_rel = (Path(home) / rel).as_posix()
            ops.append(ka.op('delete', 'script', removes=[copy_rel], reason='точная копия', evidence=twin_rel,
                             deps=[twin_rel], base={copy_rel: kv.sha(copy_bytes), twin_rel: kv.sha(twin_bytes)}))
    return ops


def legacy_file_ops(vault, mapping):
    vault = Path(vault)
    ops = []
    for entry in mapping:
        if not entry['home']:
            continue
        for path, rel in _plain_files(vault / entry['source']):
            if path.suffix == '.md':
                continue
            dest = (Path(entry['home']) / rel).as_posix()
            if (vault / dest).exists():
                continue
            source = path.relative_to(vault).as_posix()
            data = path.read_bytes()
            ops.append(ka.op('move', 'script', {dest: data}, [source],
                             'файл из старой папки переехал в её дом', entry['folder'] or '', dest=dest,
                             links={source: dest}, base={source: kv.sha(data), dest: None}))
    return ops


def conflict_ops(vault):
    vault = Path(vault)
    ops, rest = [], []
    for path in sorted(vault.rglob('*.md')):
        rel = path.relative_to(vault)
        if kv.protected(rel) or not kv.CONFLICT.search(path.name):
            continue
        base_path = path.with_name(kv.CONFLICT.sub('', path.name))
        if not base_path.is_file():
            rest.append(dict(path=rel.as_posix(), base=None))
            continue
        conflict_bytes, base_bytes = path.read_bytes(), base_path.read_bytes()
        base_rel = base_path.relative_to(vault).as_posix()
        if conflict_bytes == base_bytes:
            rel_posix = rel.as_posix()
            ops.append(ka.op('delete', 'script', removes=[rel_posix],
                             reason='копия конфликта синхронизации совпадает с оригиналом',
                             evidence=base_rel, deps=[base_rel],
                             base={rel_posix: kv.sha(conflict_bytes), base_rel: kv.sha(base_bytes)}))
        else:
            rest.append(dict(path=rel.as_posix(), base=base_rel))
    return ops, rest


def empty_dir_ops(vault):
    vault = Path(vault)
    candidates = (sorted(vault.glob('projects/*')) + sorted(vault.glob('repositories/*')) +
                  sorted(vault.glob('contexts/*/projects/*')))
    ops = []
    for directory in candidates:
        if not directory.is_dir() or directory.is_symlink():
            continue
        removable, empty = [], True
        for path in sorted(p for p in directory.rglob('*') if p.is_file() or p.is_symlink()):
            if path.name.endswith('.lock'):
                continue
            if path.name in kv.CONTROL_FILES:
                removable.append(path.relative_to(vault).as_posix())
                continue
            empty = False
            break
        if empty:
            rel = directory.relative_to(vault).as_posix()
            ops.append(ka.op('rmdir', 'script', removes=removable, dirs=[rel], reason='пустая папка',
                             evidence=rel, subject=rel,
                             base={r: kv.file_hash(vault / r) for r in removable}))
    return ops


def _report_closed(path):
    text = path.read_text(errors='replace')
    return (str(kv.frontmatter(text).get('acknowledged')).lower() == 'true' and
            not any(line.lstrip().startswith('- [ ]') for line in text.splitlines()))


def report_ops(vault):
    vault = Path(vault)
    closed = []
    for p in sorted((vault / kv.REPORTS).glob('*.md')):
        file_hash = kv.file_hash(p)
        if _report_closed(p):
            closed.append((p, file_hash))
    return [ka.op('delete', 'script', removes=[p.relative_to(vault).as_posix()], reason='старый закрытый отчёт',
                  base={p.relative_to(vault).as_posix(): file_hash})
            for p, file_hash in closed[:-REPORT_KEEP]]


def autofix(history, vault, journal, envs):
    vault = Path(vault)
    mapping = legacy(vault, envs)
    pairs = [(e['source'], e['home']) for e in mapping if e['home']] + adopted(vault)
    fixes, conflicts = conflict_ops(vault)
    ops = duplicate_ops(vault, pairs) + legacy_file_ops(vault, mapping) + fixes + report_ops(vault)
    records, skipped = ka.run_ops(history, vault, journal, ops)
    links, merged = ka.collect_links(records)
    done, missed = ka.run_fixups(history, vault, journal, kv.layers(vault), links, merged)
    records += done
    skipped += missed
    return mapping, conflicts, records, skipped


def over_cap(vault, indexes):
    result = []
    for rel in indexes:
        text = kv.read(vault, rel)
        lines, size = len(text.splitlines()), len(text.encode())
        max_lines, max_bytes = ((kv.GLOBAL_LINES, None) if rel == 'global/INDEX.md'
                                else (kv.INDEX_LINES, kv.INDEX_BYTES))
        if lines > max_lines or (max_bytes and size > max_bytes):
            result.append(dict(index=rel, lines=lines, bytes=size, max_lines=max_lines, max_bytes=max_bytes))
    return result


def curated(vault):
    vault = Path(vault)
    bound = {p['memory'] for p in rm.registry_read(vault)['projects']}
    repos = [d.name for d in sorted((vault / 'repositories').glob('*')) if d.is_dir()]
    result = []
    for folder in sorted(vault.glob('contexts/*/projects/*')):
        rel = folder.relative_to(vault).as_posix()
        if not folder.is_dir() or rel in bound:
            continue
        key = folder.name.replace('-', '')
        hits = [f'repositories/{r}' for r in repos if r.rsplit('-', 1)[0].replace('-', '') == key]
        if hits:
            result.append(dict(folder=rel, candidates=hits))
    return result


def double_index(vault):
    vault = Path(vault)
    return [layer for layer in kv.layers(vault)
            if (vault / layer / 'MEMORY.md').is_file() and (vault / layer / 'INDEX.md').is_file()
            and not (vault / layer / 'INDEX.md').is_symlink()]


def build_worklist(vault, run, envs, mapping, conflicts, tasks, full, cursor):
    vault = Path(vault)
    notes = kv.all_notes(vault)
    hashes = {rel: kv.file_hash(vault / rel) for rel in notes}
    indexes = []
    for layer in kv.layers(vault):
        index = kv.index_path(vault, layer)
        if index.is_file():
            rel = index.relative_to(vault).as_posix()
            hashes[rel] = kv.file_hash(index)
            indexes.append(rel)
    legacy_work = []
    for entry in mapping:
        root = vault / entry['source']
        for path in root.rglob('*'):
            if path.is_file() and not path.name.endswith('.lock'):
                hashes[path.relative_to(vault).as_posix()] = kv.file_hash(path)
        files = sorted(p.relative_to(vault).as_posix() for p in root.rglob('*.md') if p.is_file())
        if files:
            legacy_work.append(dict(entry, files=files))
    last = cursor.get('last_run', 0)
    changed = [n for n in notes if (vault / n).stat().st_mtime > last]
    rest = [n for n in notes if n not in set(changed)]
    start = size = 0
    if full:
        selection = notes
    else:
        size = math.ceil(len(rest) / SLICES) if rest else 0
        start = cursor.get('cursor', 0) % len(rest) if rest else 0
        selection = changed + (rest[start:] + rest[:start])[:size]
    questions = []
    for rel, info in sorted(tasks.items()):
        text = kt.question(info)
        if text:
            questions.append(dict(path=rel, question=text))
    return dict(
        run=run, vault=str(vault), full=full, selection=selection, hashes=hashes, tasks=tasks,
        questions=questions, legacy=legacy_work,
        oversize=[n for n in notes if (vault / n).stat().st_size > kv.NOTE_BYTES],
        over_cap=over_cap(vault, indexes),
        untyped=[n for n in selection if not kv.note_type(kv.read(vault, n))],
        dead_paths={n: dead for n in selection if (dead := kv.dead_paths(vault, n, Path.home()))},
        conflicts=conflicts, curated=curated(vault), double_index=double_index(vault),
        next_cursor=(start + size) if not full and rest else 0)
