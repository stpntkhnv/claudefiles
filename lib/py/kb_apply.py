from collections import Counter
from datetime import datetime
import fcntl
import os
from pathlib import Path
import shutil
import time

import kb_vault as kv
import repo_memory as rm


class Stale(Exception):
    pass


def op(kind, origin, writes=None, removes=None, reason='', evidence='', subject=None, dest=None, dirs=None,
       links=None, merged=None, deps=None, base=None):
    writes = dict(writes or {})
    removes = list(removes or [])
    return dict(kind=kind, origin=origin, writes=writes, removes=removes, dirs=list(dirs or []),
                reason=reason, evidence=evidence, dest=dest, links=dict(links or {}), merged=list(merged or []),
                deps=list(deps or []), guard={}, base=dict(base or {}),
                subject=subject or (removes[0] if removes else next(iter(writes), '')))


def touched(entry):
    return set(entry['writes']) | set(entry['removes'])


class Journal:
    def __init__(self, path, run=None):
        self.path = Path(path)
        self.data = rm.json_read(self.path, None) or dict(run=run, state='open', ops=[], pending=None)

    @property
    def run(self):
        return self.data['run']

    def save(self):
        rm.atomic_json(self.path, self.data)

    def next_id(self):
        return len(self.data['ops']) + 1

    def add(self, record):
        self.data['ops'].append(record)
        self.save()

    def close(self, state='closed'):
        self.data['state'] = state
        self.save()

    def done(self):
        return [record for record in self.data['ops'] if record['state'] == 'done']

    def paths(self):
        return sorted({path for record in self.data['ops'] for path in record['paths']})


def relink(text, old_dir, new_dir):
    def swap(match):
        link, anchor = match.group(1), match.group(2) or ''
        if '://' in link:
            return match.group(0)
        absolute = os.path.normpath(os.path.join(old_dir, link))
        return '](' + os.path.relpath(absolute, new_dir) + anchor + ')'
    return kv.MDLINK.sub(swap, text)


def _staged(run_dir, rel):
    base = (Path(run_dir) / 'staging').resolve()
    path = (Path(run_dir) / rel).resolve()
    if not path.is_relative_to(base) or not path.is_file():
        raise ValueError('staged file is missing or outside staging: ' + str(rel))
    return path.read_bytes()


def destination(vault, source, to):
    to = to.strip()
    if to.endswith('/') or (Path(vault) / to).is_dir():
        to = to.rstrip('/') + '/' + Path(source).name
    kv.target(vault, to)
    return Path(to).as_posix()


def from_model(vault, run_dir, decision):
    vault = Path(vault)
    ops, skipped = [], []
    for raw in decision.get('operations', []):
        kind = raw.get('op')
        reason, evidence = str(raw.get('reason') or '').strip(), str(raw.get('evidence') or '').strip()
        try:
            if not reason or not evidence:
                raise ValueError('нет причины или доказательства')
            if kind == 'write':
                entry = op('write', 'model', {raw['path']: _staged(run_dir, raw['staged'])}, [], reason, evidence)
            elif kind == 'merge':
                target = raw['target']
                sources = [s for s in raw['sources'] if s != target]
                if not sources:
                    raise ValueError('merge needs at least one source besides the target')
                entry = op('merge', 'model', {target: _staged(run_dir, raw['staged'])}, sources, reason, evidence,
                           subject=target, links={s: target for s in sources}, merged=sources)
            elif kind == 'move':
                source = raw['path']
                dest = destination(vault, source, raw['to'])
                data = (vault / source).read_bytes()
                if source.endswith('.md'):
                    data = relink(data.decode(errors='replace'), str((vault / source).parent),
                                  str((vault / dest).parent)).encode()
                entry = op('move', 'model', {dest: data}, [source], reason, evidence, subject=source, dest=dest,
                           links={source: dest})
            elif kind == 'delete':
                entry = op('delete', 'model', {}, [raw['path']], reason, evidence)
            else:
                raise ValueError('unknown operation ' + str(kind))
        except (KeyError, OSError, ValueError, TypeError) as error:
            skipped.append(dict(kind=str(kind), origin='model', reason=reason, evidence=evidence,
                                subject=str(raw.get('path') or raw.get('target') or ''), problem=str(error)))
            continue
        ops.append(entry)
    return ops, skipped


def _closable(vault, path, text, tasks):
    info = tasks.get(path, {})
    if info.get('status') == 'merged' and info.get('sha'):
        return True
    return kv.meta(text).get('status') in ('done', 'dropped')


def _task_problem(vault, entry, tasks):
    for path in entry['removes']:
        if path.endswith('.md') and (vault / path).is_file():
            text = kv.read(vault, path)
            if kv.note_type(text) == 'task' and not _closable(vault, path, text, tasks):
                return 'заметку о задаче можно удалить только после подтверждённого мержа: ' + path
    for path, data in entry['writes'].items():
        if path.endswith('.md') and (vault / path).is_file():
            text = kv.read(vault, path)
            if kv.note_type(text) != 'task' or _closable(vault, path, text, tasks):
                continue
            new = data.decode(errors='replace')
            if kv.note_type(new) != 'task' or kv.meta(new).get('link') != kv.meta(text).get('link'):
                return 'заметку о незакрытой задаче можно только ужать, сохранив тип и ссылку: ' + path
    return None


def _name_clashes(vault, ops, table):
    final = {stem: set(rels) for stem, rels in table.items()}
    creators = {}
    for index, entry in enumerate(ops):
        for path in entry['removes']:
            final.get(Path(path).stem, set()).discard(path)
        for path in entry['writes']:
            if (path.endswith('.md') and Path(path).name not in kv.INDEX_NAMES
                    and not (vault / path).exists()):
                stem = Path(path).stem
                final.setdefault(stem, set()).add(path)
                creators.setdefault(stem, []).append(index)
    clashes = {}
    for stem, indexes in creators.items():
        if len(final.get(stem, ())) > 1:
            for index in indexes:
                clashes[index] = stem
    return clashes


def _layer_problem(vault, path):
    layer = kv.layer_of(path)
    if not layer or layer.startswith('projects/'):
        return 'запись вне слоёв памяти: ' + path
    parts = Path(layer).parts
    anchor = Path(*parts[:2]) if parts[0] == 'contexts' and len(parts) == 4 else Path(layer)
    if not (Path(vault) / anchor).is_dir():
        return 'такого слоя нет, новые слои ревизия не создаёт: ' + anchor.as_posix()
    return None


def _problem(vault, entry, expected, tasks, counts, canon):
    for path in sorted(touched(entry)):
        if kv.protected(path, script=entry['origin'] == 'script'):
            return 'защищённый путь ' + path
        if counts[canon[path]] > 1:
            return 'путь участвует в нескольких операциях: ' + path
        if expected is not None and kv.file_hash(vault / path) != expected.get(path):
            return 'изменён во время прогона: ' + path
    for path in sorted(entry['deps']):
        if counts[canon[path]]:
            return 'путь участвует в нескольких операциях: ' + path
    if entry['kind'] == 'move' and (vault / entry['dest']).exists():
        return 'путь назначения уже существует: ' + entry['dest']
    if entry['origin'] == 'model':
        for path in entry['writes']:
            problem = _layer_problem(vault, path)
            if problem:
                return problem
        return _task_problem(vault, entry, tasks)
    return None


def validate(vault, ops, expected=None, tasks=None, table=None):
    vault = Path(vault)
    tasks = tasks or {}
    table = kv.names(vault) if table is None else table
    canon, broken = {}, {}
    for index, entry in enumerate(ops):
        for path in touched(entry) | set(entry['deps']):
            try:
                canon[path] = kv.canonical(vault, path)
            except ValueError as error:
                broken[index] = ('защищённый путь ' + path if kv.protected(path, script=entry['origin'] == 'script')
                                 else str(error))
    counts = Counter(canon[path] for index, entry in enumerate(ops) if index not in broken
                     for path in touched(entry))
    problems = [broken.get(index) or _problem(vault, entry, expected, tasks, counts, canon)
                for index, entry in enumerate(ops)]
    while True:
        candidates = [index for index, problem in enumerate(problems) if not problem]
        clashes = _name_clashes(vault, [ops[index] for index in candidates], table)
        if not clashes:
            break
        for local, stem in clashes.items():
            problems[candidates[local]] = f'имя {stem} станет неоднозначным'
    accepted, skipped = [], []
    for index, entry in enumerate(ops):
        problem = problems[index]
        if problem:
            skipped.append(dict(kind=entry['kind'], origin=entry['origin'], subject=entry['subject'],
                                reason=entry['reason'], evidence=entry['evidence'], problem=problem))
            continue
        for path in touched(entry):
            entry['guard'][path] = (expected.get(path) if expected is not None
                                     else entry['base'].get(path, kv.file_hash(vault / path)))
        for path in entry['deps']:
            entry['guard'][path] = entry['base'].get(path, kv.file_hash(vault / path))
        accepted.append(entry)
    return accepted, skipped


def _remove_dir(root):
    handles = []
    try:
        for lock in sorted(root.rglob('*.lock')):
            handle = lock.open('a')
            handles.append(handle)
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if not [p for p in root.rglob('*') if (p.is_file() or p.is_symlink()) and not p.name.endswith('.lock')]:
            shutil.rmtree(root, ignore_errors=True)
    except BlockingIOError:
        pass
    finally:
        for handle in handles:
            handle.close()


def apply_op(history, vault, journal, entry):
    for path, expected in entry['guard'].items():
        if kv.file_hash(Path(vault) / path) != expected:
            raise Stale(path)
    paths = {}
    for path in sorted(touched(entry)):
        after = history.store_bytes(entry['writes'][path]) if path in entry['writes'] else None
        paths[path] = dict(before=history.store(path), after=after)
    record = dict(id=journal.next_id(), kind=entry['kind'], origin=entry['origin'], subject=entry['subject'],
                  dest=entry['dest'], reason=entry['reason'], evidence=entry['evidence'], links=entry['links'],
                  merged=entry['merged'], paths=paths, state='intent', at=time.time())
    journal.add(record)
    for path, data in entry['writes'].items():
        kv.write_file(vault, path, data)
    for path in entry['removes']:
        if path not in entry['writes']:
            kv.remove_file(vault, path)
    for directory in entry['dirs']:
        _remove_dir(kv.target(vault, directory))
    record['state'] = 'done'
    journal.save()
    return record


def run_ops(history, vault, journal, ops, expected=None, tasks=None):
    accepted, skipped = validate(vault, ops, expected, tasks)
    records = []
    for entry in accepted:
        try:
            records.append(apply_op(history, vault, journal, entry))
        except Stale as stale:
            skipped.append(dict(kind=entry['kind'], origin=entry['origin'], subject=entry['subject'],
                                reason=entry['reason'], evidence=entry['evidence'],
                                problem='изменён во время прогона: ' + str(stale)))
    return records, skipped


def _index_rel(vault, layer):
    index = kv.index_path(vault, layer)
    return index.relative_to(vault).as_posix() if index.is_file() else None


def unindex_ops(vault, links, merged):
    vault = Path(vault)
    plans = {}
    for old, new in links.items():
        layer = kv.layer_of(old)
        if not layer or (old not in merged and layer == kv.layer_of(new)):
            continue
        rel = _index_rel(vault, layer)
        if rel:
            plans.setdefault(rel, set()).add(old)
    ops = []
    for rel, olds in sorted(plans.items()):
        stems = {Path(old).stem for old in olds}
        directory = (vault / rel).parent
        base_hash = kv.file_hash(vault / rel)
        original = kv.read(vault, rel)
        kept = []
        for line in original.splitlines():
            wikis, refs = kv.refs(line)
            hit = (any(name in stems for name in wikis) or
                   any(os.path.relpath(os.path.normpath(directory / link), vault) in olds for link, _ in refs))
            if not hit:
                kept.append(line)
        text = '\n'.join(kept) + '\n'
        if text != original:
            ops.append(op('unindex', 'script', {rel: text.encode()}, [],
                          'строки перенесённых и слитых заметок убраны из оглавления', ', '.join(sorted(olds)),
                          base={rel: base_hash}))
    return ops


def relink_ops(vault, links):
    vault = Path(vault)
    if not links:
        return []
    table = kv.names(vault)
    renames = {Path(old).stem: Path(new).stem for old, new in links.items()
               if Path(old).stem != Path(new).stem and not kv.lookup(table, Path(old).stem)}
    files = set(kv.all_notes(vault))
    files.update(rel for rel in (_index_rel(vault, layer) for layer in kv.layers(vault)) if rel)
    ops = []
    for rel in sorted(files):
        directory = (vault / rel).parent
        base_hash = kv.file_hash(vault / rel)
        text = kv.read(vault, rel)

        def swap(match, directory=directory):
            link, anchor = match.group(1), match.group(2) or ''
            if '://' in link:
                return match.group(0)
            old = os.path.relpath(os.path.normpath(directory / link), vault)
            if old not in links:
                return match.group(0)
            return '](' + os.path.relpath(vault / links[old], directory) + anchor + ')'

        new = kv.rename_wiki(kv.MDLINK.sub(swap, text), renames)
        if new != text:
            ops.append(op('relink', 'script', {rel: new.encode()}, [], 'ссылки на перенесённые и слитые заметки',
                          ', '.join(sorted(links)), base={rel: base_hash}))
    return ops


def reindex_ops(vault, layers):
    vault = Path(vault)
    table = kv.names(vault)
    ops = []
    for layer in sorted(set(layers)):
        rel = kv.index_path(vault, layer).relative_to(vault).as_posix()
        base_hash = kv.file_hash(vault / rel)
        text = kv.reindex(vault, layer, table)
        if text is None:
            continue
        ops.append(op('reindex', 'script', {rel: text.encode()}, [], 'оглавление приведено к заметкам слоя', layer,
                      base={rel: base_hash}))
    return ops


def layers_of(paths):
    found = set()
    for path in paths:
        layer = kv.layer_of(path)
        if layer and not layer.startswith('projects/'):
            found.add(layer)
    return found


def collect_links(records):
    links, merged = {}, set()
    for record in records:
        links.update(record.get('links') or {})
        merged.update(record.get('merged') or [])
    return links, merged


def run_fixups(history, vault, journal, layers, links=None, merged=None):
    links, merged = dict(links or {}), set(merged or ())
    journal.data['pending'] = dict(layers=sorted(set(layers)), links=links, merged=sorted(merged))
    journal.save()
    layers = set(layers) | layers_of(links) | layers_of(links.values())
    records, skipped = [], []
    for build in (lambda: unindex_ops(vault, links, merged), lambda: relink_ops(vault, links),
                  lambda: reindex_ops(vault, layers)):
        for _ in range(3):
            done, attempt = run_ops(history, vault, journal, build())
            records += done
            if not attempt:
                break
        skipped += attempt
    journal.data['pending'] = None
    journal.save()
    return records, skipped


def restore(history, vault, record, side):
    for path, versions in record['paths'].items():
        oid = versions[side]
        if oid is None:
            kv.remove_file(vault, path)
        else:
            kv.write_file(vault, path, history.read(oid))


def settle(history, vault, journal):
    for record in journal.data['ops']:
        if record['state'] != 'intent':
            continue
        if all(history.current(p) in (v['before'], v['after']) for p, v in record['paths'].items()):
            restore(history, vault, record, 'before')
            record['state'] = 'rolled-back'
        else:
            record['state'] = 'conflict'
    journal.save()
    pending = journal.data.get('pending') or {}
    links, merged = collect_links(journal.done())
    links.update(pending.get('links') or {})
    merged |= set(pending.get('merged') or ())
    layers = layers_of(p for r in journal.done() for p in r['paths']) | set(pending.get('layers') or ())
    if layers or links:
        run_fixups(history, vault, journal, layers, links, merged)


def recover(history, vault, journal_path):
    journal = Journal(journal_path)
    if journal.data['state'] != 'open':
        return None
    settle(history, vault, journal)
    history.commit_paths(journal.paths(), f'review {journal.run} (recovered)')
    journal.close('recovered')
    return journal


def undo(history, vault, journal_path, op_id=None):
    journal = Journal(journal_path)
    records = [r for r in journal.done() if op_id is None or r['id'] == op_id]
    if op_id is not None and not records:
        raise ValueError(f'operation {op_id} is not an applied operation of run {journal.run}')
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    log = Journal(journal.path.with_name(f'undo-{stamp}.journal.json'), journal.run)
    log.save()
    results, links, layers = [], {}, set()
    for record in reversed(records):
        base = {p: kv.file_hash(vault / p) for p in record['paths']}
        if any(history.current(p) != v['after'] for p, v in record['paths'].items()):
            results.append((record['id'], 'conflict'))
            continue
        writes = {p: history.read(v['before']) for p, v in record['paths'].items() if v['before']}
        removes = [p for p, v in record['paths'].items() if not v['before']]
        entry_links = {new: old for old, new in record['links'].items()} if record['kind'] == 'move' else None
        entry = op('undo', 'script', writes, removes, f'откат операции {record["id"]}', record['subject'],
                   subject=record['subject'], base=base, links=entry_links)
        done, skipped = run_ops(history, vault, log, [entry])
        if not done:
            results.append((record['id'], 'conflict'))
            continue
        record['state'] = 'undone'
        journal.save()
        layers |= layers_of(record['paths'])
        if record['kind'] == 'move':
            links.update({new: old for old, new in (record.get('links') or {}).items()})
        results.append((record['id'], 'undone'))
    if layers:
        run_fixups(history, vault, log, layers, links, set())
    history.commit_paths(log.paths(), f'undo {journal.run}' + (f' {op_id}' if op_id else ''))
    log.close()
    return list(reversed(results))
