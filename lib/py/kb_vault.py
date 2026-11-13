import hashlib
import os
from pathlib import Path
import re
import tempfile

EXCLUDED_DIRS = ('.obsidian', '.stfolder', '.stversions', '.trash')
EXCLUDED_FILES = ('.stignore',)
EXCLUDED_SUFFIXES = ('.kdbx', '.lock')
CONTROL_FILES = ('.checkouts.json', '.adopted.json')
INDEX_NAMES = ('MEMORY.md', 'INDEX.md')
REPORTS = 'reviews'
NOTE_BYTES = 10240
GLOBAL_LINES = 50
INDEX_LINES = 200
INDEX_BYTES = 25000
WIKI = re.compile(r'\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]')
WIKI_PARTS = re.compile(r'\[\[([^\]|#]+)((?:#[^\]|]*)?(?:\|[^\]]*)?)\]\]')
INDEX_LINE = re.compile(r'^(\s*[-*] \[\[([^\]|#]+)\]\]:\s*)(.*)$')
MDLINK = re.compile(r'\]\(([^)\s]+?\.md)(#[^)\s]*)?\)')
CONFLICT = re.compile(r'(?:\.sync-conflict-\d{8}-\d{6}-[A-Z0-9]+| \(conflicted copy[^)]*\))(?=\.md$)')
PATHS = re.compile(r'(?<![\w.~/-])((?:~|/home|/srv|/opt|/etc|/var|/usr|/mnt|/media)/[^\s`\'"<>()\[\]{}*$,;]*)')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    path = Path(path)
    return sha(path.read_bytes()) if path.is_file() else None


def read(vault, rel):
    return (Path(vault) / rel).read_text(errors='replace')


def excluded(rel):
    rel = Path(rel)
    return (any(part in EXCLUDED_DIRS for part in rel.parts) or rel.name in EXCLUDED_FILES
            or rel.name.endswith(EXCLUDED_SUFFIXES))


def protected(rel, script=False):
    rel = Path(rel)
    if rel.is_absolute() or not rel.parts or '..' in rel.parts or excluded(rel):
        return True
    hidden = [part for part in rel.parts if part.startswith('.')]
    if hidden and not (script and hidden == [rel.name] and rel.name in CONTROL_FILES):
        return True
    return rel.parts[0] == REPORTS and not script


def target(vault, rel):
    rel = Path(rel)
    if rel.is_absolute() or not rel.parts or '..' in rel.parts:
        raise ValueError('path must stay inside the vault: ' + str(rel))
    if protected(rel, script=True):
        raise ValueError('path points into a protected area: ' + str(rel))
    base = Path(vault).resolve()
    path = base / rel
    real = path.resolve()
    if not real.is_relative_to(base) or real == base:
        raise ValueError('path escapes the vault: ' + str(rel))
    if real != path and protected(real.relative_to(base), script=True):
        raise ValueError('path points into a protected area: ' + str(rel))
    return path


def canonical(vault, rel):
    return target(vault, rel).resolve().relative_to(Path(vault).resolve()).as_posix()


def write_file(vault, rel, data):
    path = target(vault, rel)
    if path.is_symlink():
        path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    fd, tmp = tempfile.mkstemp(prefix='.kb-write-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def remove_file(vault, rel):
    path = target(vault, rel)
    if path.is_file() or path.is_symlink():
        path.unlink()


def frontmatter(text):
    if not text.startswith('---\n'):
        return {}
    end = text.find('\n---', 3)
    if end < 0:
        return {}
    data, key = {}, None
    for line in text[4:end].splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        nested = line[:1] in (' ', '\t')
        if (stripped.startswith('- ') and key is not None and
                (nested or data.get(key) is None or isinstance(data.get(key), list))):
            if not isinstance(data.get(key), list):
                data[key] = []
            data[key].append(stripped[2:].strip().strip('"\''))
            continue
        name, sep, value = stripped.partition(':')
        if not sep:
            continue
        value = value.strip().strip('"\'')
        if nested and key is not None:
            if not isinstance(data.get(key), dict):
                data[key] = {}
            data[key][name.strip()] = value
        else:
            key = name.strip()
            data[key] = value or None
    return data


def body(text):
    if text.startswith('---\n'):
        end = text.find('\n---', 3)
        if end >= 0:
            newline = text.find('\n', end + 1)
            return text[newline + 1:].lstrip('\n') if newline >= 0 else ''
    return text


def meta(text):
    nested = frontmatter(text).get('metadata')
    return nested if isinstance(nested, dict) else {}


def note_type(text):
    value = meta(text).get('type') or frontmatter(text).get('type')
    return value if isinstance(value, str) and value else None


def description(text, fallback):
    value = frontmatter(text).get('description')
    if isinstance(value, str) and value:
        return value
    for line in body(text).splitlines():
        line = line.strip().lstrip('#').strip()
        if line:
            return line[:120]
    return fallback


def layer_of(rel):
    parts = Path(rel).parts
    if len(parts) >= 2 and parts[0] == 'global':
        return 'global'
    if len(parts) >= 3 and parts[0] in ('machine', 'repositories'):
        return '/'.join(parts[:2])
    if len(parts) >= 5 and parts[0] == 'contexts' and parts[2] == 'projects':
        return '/'.join(parts[:4])
    if len(parts) >= 3 and parts[0] == 'contexts' and parts[2] != 'projects':
        return '/'.join(parts[:2])
    if len(parts) >= 4 and parts[0] == 'projects' and parts[2] == 'memory':
        return '/'.join(parts[:3])
    return None


def _subdirs(path):
    return [d for d in sorted(Path(path).glob('*')) if d.is_dir() and not d.name.startswith('.')]


def layers(vault):
    vault = Path(vault)
    found = ['global'] if (vault / 'global').is_dir() else []
    for top in ('machine', 'repositories'):
        found += [f'{top}/{d.name}' for d in _subdirs(vault / top)]
    for context in _subdirs(vault / 'contexts'):
        found.append(f'contexts/{context.name}')
        found += [f'contexts/{context.name}/projects/{p.name}' for p in _subdirs(context / 'projects')]
    return found


def index_path(vault, layer):
    directory = Path(vault) / layer
    if layer == 'global':
        return directory / 'INDEX.md'
    primary = directory / 'MEMORY.md'
    if primary.is_file():
        return primary
    index = directory / 'INDEX.md'
    return index if index.is_file() else primary


def layer_notes(vault, layer):
    vault = Path(vault)
    root = vault / layer
    result = []
    for path in sorted(root.rglob('*.md')):
        rel = path.relative_to(vault)
        if path.is_symlink() or protected(rel) or layer_of(rel) != layer or CONFLICT.search(path.name):
            continue
        if path.parent == root and path.name in INDEX_NAMES:
            continue
        result.append(rel.as_posix())
    return result


def all_notes(vault):
    vault = Path(vault)
    result = []
    for path in sorted(vault.rglob('*.md')):
        rel = path.relative_to(vault)
        if (len(rel.parts) < 2 or path.is_symlink() or protected(rel) or path.name in INDEX_NAMES
                or CONFLICT.search(path.name)):
            continue
        result.append(rel.as_posix())
    return result


def names(vault):
    table = {}
    for rel in all_notes(vault):
        table.setdefault(Path(rel).stem, []).append(rel)
        aliases = frontmatter(read(vault, rel)).get('aliases')
        for alias in aliases if isinstance(aliases, list) else []:
            table.setdefault(alias, []).append(rel)
    return table


def refs(line):
    return ([name.strip() for name in WIKI.findall(line)],
            [(link, anchor) for link, anchor in MDLINK.findall(line) if '://' not in link])


def lookup(table, name):
    return table.get(name) or table.get(name.rsplit('/', 1)[-1]) or []


def _repair(vault, link, table):
    parts = [part for part in Path(link).parts if part not in ('..', '.')]
    if parts and (Path(vault) / Path(*parts)).is_file():
        return Path(*parts).as_posix()
    hits = table.get(Path(link).stem, [])
    return hits[0] if len(hits) == 1 else None


def rename_wiki(text, renames):
    def swap(match):
        name = match.group(1).strip()
        return f'[[{renames[name]}{match.group(2)}]]' if name in renames else match.group(0)
    return WIKI_PARTS.sub(swap, text)


def description_mismatches(vault, layer, table=None):
    vault = Path(vault)
    index = index_path(vault, layer)
    if not index.is_file():
        return []
    table = names(vault) if table is None else table
    rel = index.relative_to(vault).as_posix()
    result = []
    for line in index.read_text(errors='replace').splitlines():
        match = INDEX_LINE.match(line)
        if not match:
            continue
        hits = lookup(table, match.group(2).strip())
        if len(hits) != 1 or layer_of(hits[0]) != layer:
            continue
        value = frontmatter(read(vault, hits[0])).get('description')
        if isinstance(value, str) and value and value != match.group(3).strip():
            result.append(dict(index=rel, note=hits[0], line=line, description=value))
    return result


def reindex(vault, layer, table=None):
    vault = Path(vault)
    table = names(vault) if table is None else table
    notes = set(all_notes(vault))
    index = index_path(vault, layer)
    original = index.read_text(errors='replace') if index.is_file() else ''
    directory = index.parent
    out, referenced = [], set()
    for line in original.splitlines():
        wikis, links = refs(line)
        if not line.lstrip().startswith(('- ', '* ')) or not (wikis or links):
            out.append(line)
            continue
        keep, fixed = True, line
        for name in wikis:
            hits = lookup(table, name)
            keep = keep and bool(hits)
            referenced.update(hits)
        for link, _ in links:
            resolved = Path(os.path.normpath(directory / link))
            if resolved.is_file():
                referenced.add(os.path.relpath(resolved, vault))
                continue
            repaired = _repair(vault, link, table)
            if repaired is None:
                keep = False
                continue
            stem = Path(repaired).stem
            if repaired in notes and table.get(stem) == [repaired]:
                fixed = re.sub(r'\[[^\]]*\]\(' + re.escape(link) + r'(#[^)]*)?\)', f'[[{stem}]]', fixed, count=1)
            else:
                fixed = fixed.replace('](' + link, '](' + os.path.relpath(vault / repaired, directory), 1)
            referenced.add(repaired)
        if keep:
            out.append(fixed)
    missing = [rel for rel in layer_notes(vault, layer) if rel not in referenced]
    if missing and not out:
        out += [f'# {layer}', '']
    for rel in missing:
        out.append(f'- [[{Path(rel).stem}]]: {description(read(vault, rel), Path(rel).stem)}')
    text = '\n'.join(out) + '\n' if out else ''
    return None if text == original else text


def dead_paths(vault, rel, home):
    found = []
    for raw in PATHS.findall(read(vault, rel)):
        raw = raw.rstrip('.:!?')
        if raw.count('/') < 2 and not raw.startswith('~/'):
            continue
        path = Path(home) / raw[2:] if raw.startswith('~/') else Path(raw)
        if raw not in found and not path.exists():
            found.append(raw)
    return found
