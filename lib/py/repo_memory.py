#!/usr/bin/env python3
# claudefiles-memory-runtime
"""Resolve a Git remote to shared memory; launch Claude without changing profile settings."""
import argparse
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid
from urllib.parse import unquote, urlsplit

REGISTRY = 'repositories.json'
LAYER = re.compile(r'[a-z0-9][a-z0-9-]*\Z')


def canonical_remote(value):
    """Transport-independent identity. Never retain userinfo, query strings or fragments."""
    value = value.strip()
    if value.startswith('azure:'):
        parts = value[6:].split('/')
        if len(parts) != 3 or not all(parts) or any(p in ('.', '..') for p in parts):
            raise ValueError('invalid Azure repository identity')
        return 'azure:' + '/'.join(parts)
    if '://' in value:
        u = urlsplit(value)
        if u.scheme not in ('https', 'http', 'ssh', 'git') or not u.hostname:
            raise ValueError('unsupported Git remote; use a network URL')
        host = u.hostname.lower()
        port = u.port
        if port and port != {'https': 443, 'http': 80, 'ssh': 22, 'git': 9418}[u.scheme]:
            host += ':' + str(port)
        path = u.path
    else:
        m = re.fullmatch(r'(?:[^@/:]+@)?([^/:]+):(.+)', value)
        if not m:
            # Already canonical, e.g. github.com/owner/repo.
            m = re.fullmatch(r'([^/:]+(?:\.[^/:]+)+)/(.+)', value)
        if not m:
            raise ValueError('unsupported Git remote; local paths need an explicit project binding')
        host, path = m.groups()
        host = host.lower()
    path = unquote(path.split('?', 1)[0].split('#', 1)[0]).strip('/')
    if path.endswith('.git'):
        path = path[:-4]
    parts = path.split('/')
    if not path or any(p in ('', '.', '..') for p in parts) or '\\' in path:
        raise ValueError('invalid Git repository path')
    if host == 'ssh.dev.azure.com' and len(parts) == 4 and parts[0] == 'v3':
        return 'azure:' + '/'.join(parts[1:])
    if host == 'dev.azure.com' and len(parts) == 4 and parts[2] == '_git':
        return 'azure:' + '/'.join((parts[0], parts[1], parts[3]))
    if host.endswith('.visualstudio.com') and len(parts) == 3 and parts[1] == '_git':
        return 'azure:' + '/'.join((host[:-len('.visualstudio.com')], parts[0], parts[2]))
    if host == 'github.com':
        path = path.lower()
    return host + '/' + path


def json_read(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def atomic_json(path, value):
    atomic_text(path, json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def atomic_text(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.repo-memory-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def memory_path(vault, relative):
    rel = Path(relative)
    if not relative or rel.is_absolute() or '..' in rel.parts or str(rel) == '.':
        raise ValueError('memory must be a relative project directory inside the vault')
    vault = Path(vault).resolve()
    path = (vault / rel).resolve()
    if not path.is_relative_to(vault) or path == vault:
        raise ValueError('memory directory escapes the vault')
    if not ((rel.parts[0] == 'contexts' and len(rel.parts) >= 4 and rel.parts[2] == 'projects') or
            (rel.parts[0] == 'repositories' and len(rel.parts) == 2)):
        raise ValueError('memory must be under repositories/<id> or contexts/<context>/projects/<project>')
    return path


def validate_registry(data, vault):
    if not isinstance(data, dict) or data.get('version') != 1 or not isinstance(data.get('projects'), list):
        raise ValueError('unsupported repository registry format')
    ids, remotes, locations = set(), set(), set()
    for p in data['projects']:
        if not isinstance(p, dict) or not isinstance(p.get('id'), str) or not LAYER.fullmatch(p['id']):
            raise ValueError('invalid project id in registry')
        if p['id'] in ids:
            raise ValueError('duplicate project id in registry')
        ids.add(p['id'])
        if not isinstance(p.get('context'), str) or not LAYER.fullmatch(p['context']):
            raise ValueError('invalid project context in registry')
        loc = memory_path(vault, p.get('memory', ''))
        if loc in locations:
            raise ValueError('multiple project ids share a memory directory; use remote aliases on one project')
        locations.add(loc)
        if not isinstance(p.get('remotes'), list) or not p['remotes']:
            raise ValueError('project must have remote aliases')
        for remote in p['remotes']:
            canonical = canonical_remote(remote)
            if canonical in remotes:
                raise ValueError('duplicate remote binding in registry')
            remotes.add(canonical)
    return data


def registry_read(vault):
    return validate_registry(json_read(Path(vault) / REGISTRY, {'version': 1, 'projects': []}), vault)


def git_value(cwd, *args):
    result = subprocess.run(['git', '-C', str(cwd), *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ''


def local_memory_id(common, create):
    marker = common / 'claudefiles-memory-id'
    if not create:
        local_id = marker.read_text().strip() if marker.is_file() else ''
        if not local_id:
            raise LookupError('repository has no local memory id yet')
        return str(uuid.UUID(local_id))
    with marker.open('a+') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.seek(0)
        local_id = handle.read().strip()
        if not local_id:
            local_id = str(uuid.uuid4())
            handle.write(local_id + '\n')
            handle.flush()
        uuid.UUID(local_id)
    return local_id


def resolve(vault, cwd, create=True):
    data = registry_read(vault)
    root = git_value(cwd, 'rev-parse', '--show-toplevel')
    if not root:
        return None
    # Explicit local override supports offline repos and intentional fork sharing.
    explicit = git_value(cwd, 'config', '--get', 'claudefiles.memoryProject')
    remote = git_value(cwd, 'config', '--get', 'remote.origin.url')
    if not remote:
        remotes = git_value(cwd, 'remote').splitlines()
        if remotes:
            remote = git_value(cwd, 'config', '--get', f'remote.{remotes[0]}.url')
    identity = None
    if not explicit and remote:
        try:
            identity = canonical_remote(remote)
        except ValueError:
            pass  # Local filesystem remotes have no cross-machine network identity.
    for p in data['projects']:
        if (explicit and p['id'] == explicit) or (not explicit and identity in [canonical_remote(r) for r in p['remotes']]):
            return dict(p, directory=str(memory_path(vault, p['memory'])))
    if explicit:
        raise ValueError('explicit memory project is absent from the registry')
    if identity is None:
        # Shared by worktrees, retained when the repository moves. No tracked files change.
        common = Path(git_value(cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir'))
        if not common.is_absolute():
            raise ValueError('cannot find the shared Git metadata directory')
        identity = 'local:' + local_memory_id(common, create)
        label = 'local'
    else:
        label = re.sub(r'[^a-z0-9]+', '-', identity.rsplit('/', 1)[-1].lower()).strip('-')[:60] or 'repo'
    # No shared registry write is needed: independent machines derive the same relative path.
    project_id = label + '-' + hashlib.sha256(identity.encode()).hexdigest()[:24]
    relative = 'repositories/' + project_id
    return dict(id=project_id, identity=identity, memory=relative, automatic=True,
                directory=str(memory_path(vault, relative)))


def register(vault, project_id, remote, memory, context):
    vault = Path(vault)
    vault.mkdir(parents=True, exist_ok=True)
    # Serialize local edits. Cross-device registry changes still use Syncthing conflict handling.
    with (vault / '.repositories.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = registry_read(vault)
        identity = canonical_remote(remote)
        current = next((p for p in data['projects'] if p['id'] == project_id), None)
        if current:
            if current['memory'] != memory or current['context'] != context:
                raise ValueError('existing project location differs; edit its record explicitly to relocate it')
            if identity not in [canonical_remote(r) for r in current['remotes']]:
                current['remotes'].append(identity)
        else:
            data['projects'].append(dict(id=project_id, context=context, memory=memory, remotes=[identity]))
        # Validate against the actual vault, including symlinks and alias/path collisions.
        validate_registry(data, vault)
        atomic_json(vault / REGISTRY, data)
        return current or data['projects'][-1]


def deep_merge(base, overlay):
    result = copy.deepcopy(base)
    for k, v in overlay.items():
        if isinstance(v, dict) and isinstance(result.get(k), dict):
            result[k] = deep_merge(result[k], v)
        else:
            result[k] = copy.deepcopy(v)
    return result


def launch_args(args, memory, context_text):
    """Combine injected and explicit settings without losing user CLI options."""
    remaining, settings, prompts = [], {}, []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == '--':
            remaining.extend(args[i:])
            break
        key, equal, value = arg.partition('=')
        if key in ('--settings', '--append-system-prompt', '--append-system-prompt-file'):
            if not equal:
                i += 1
                if i >= len(args):
                    raise ValueError('missing value for ' + key)
                value = args[i]
            if key == '--settings':
                obj = json.loads(value) if value.lstrip().startswith('{') else json_read(Path(value).expanduser())
                if not isinstance(obj, dict):
                    raise ValueError('--settings must contain a JSON object')
                settings = deep_merge(settings, obj)
            elif key.endswith('-file'):
                prompts.append(Path(value).expanduser().read_text())
            else:
                prompts.append(value)
        else:
            remaining.append(arg)
        i += 1
    # Explicit per-session settings take precedence over automatic routing.
    if memory and 'autoMemoryDirectory' not in settings:
        settings['autoMemoryDirectory'] = memory
    if context_text:
        prompts.append(context_text)
    prefix = []
    if settings:
        prefix += ['--settings', json.dumps(settings, ensure_ascii=False)]
    if prompts:
        prefix += ['--append-system-prompt', '\n\n'.join(prompts)]
    return prefix + remaining


def config_dir():
    return Path(os.environ.get('CLAUDEFILES_CONFIG_DIR', str(Path.home() / '.config/claudefiles')))


def in_container():
    flag = os.environ.get('CLAUDEFILES_CONTAINER')
    return flag == '1' or (flag != '0' and
                           any(Path(p).exists() for p in ('/run/.containerenv', '/run/host', '/.dockerenv')))


def configured_vault(config, container):
    kb = config.get('kb', {})
    if container and not kb.get('vault_path'):
        raise ValueError('kb.vault_path must explicitly point to the shared vault in a container')
    vault = Path(kb.get('vault_path') or str(Path.home() / 'Documents/Notes/kb')).expanduser()
    if not vault.is_absolute() or '..' in vault.parts or vault == Path('/'):
        raise ValueError('kb.vault_path must be absolute or start with ~/')
    return vault


def real_claude():
    runtime_bin = Path(__file__).resolve().parent / 'bin'
    # distrobox's `enter -- command` may inherit host PATH without reading a shell rc.
    # Prefer installations in this HOME so a host shim cannot launch the host CLI there.
    search = [str(Path.home() / '.npm-global/bin'), str(Path.home() / '.local/bin'), *os.get_exec_path()]
    for part in search:
        candidate = Path(part) / 'claude'
        if candidate.parent.resolve() == runtime_bin:
            continue
        if candidate.is_file() and os.access(candidate, os.X_OK):
            # Also skip copies/symlinks of our managed shim appearing elsewhere on PATH.
            with candidate.open('rb') as f:
                if b'claudefiles-memory-launcher' in f.read(256):
                    continue
            return str(candidate)
    raise ValueError('Claude CLI not found on PATH')


def launch(args):
    binary = real_claude()
    admin = {'auth', 'config', 'doctor', 'install', 'update', 'upgrade', 'mcp', 'plugin',
             'plugins', 'setup-token', 'agents', 'auto-mode', 'remote-control', 'web', 'desktop'}
    if args and (args[0] in admin or args[0] in ('--help', '-h', '--version', '-v')):
        os.execv(binary, [binary, *args])
    config = json_read(config_dir() / 'secrets.json', {})
    if config.get('flags', {}).get('kb') is not True:
        os.execv(binary, [binary, *args])
    import kb_homes
    container = in_container()
    vault = configured_vault(config, container)
    env = kb_homes.environment(Path.home(), config, container)
    home = kb_homes.home_for(vault, env, Path.cwd())
    if home:
        kb_homes.prepare_home(vault, home, Path.cwd())
    reminder = '' if {'-p', '--print'} & set(args) else kb_homes.review_reminder(vault)
    prompt = '\n\n'.join(p for p in (kb_homes.layer_prompts(vault, env, home), reminder) if p)
    os.execv(binary, [binary, *launch_args(args, home['directory'] if home else None, prompt)])


def prepare_memory(vault, project, cwd, extra_sources=()):
    """Adopt this checkout's legacy notes once, before the CLI starts writing new memory."""
    target = memory_path(vault, project['memory'])
    target.mkdir(parents=True, exist_ok=True)
    with (target / '.memory-init.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if (target / 'MEMORY.md').exists():
            return
        root = git_value(cwd, 'rev-parse', '--show-toplevel')
        slug = re.sub(r'[^a-zA-Z0-9]', '-', root)
        source = Path(vault) / 'projects' / slug / 'memory'
        sources = []
        if source.is_dir() and any(source.glob('*.md')):
            if not source.resolve().is_relative_to(Path(vault).resolve()):
                raise ValueError('legacy memory directory escapes the vault')
            sources.append(source)
        # Adding origin to a previously offline repository must retain its existing notes.
        common = Path(git_value(cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir'))
        marker = common / 'claudefiles-memory-id'
        if marker.is_file() and not project.get('identity', '').startswith('local:'):
            local_id = str(uuid.UUID(marker.read_text().strip()))
            digest = hashlib.sha256(('local:' + local_id).encode()).hexdigest()[:24]
            local_memory = memory_path(vault, 'repositories/local-' + digest)
            if local_memory.is_dir() and any(local_memory.glob('*.md')):
                sources.append(local_memory)
        sources += [Path(s) for s in extra_sources if Path(s) not in sources]
        if sources:
            migrate_project(vault, project, sources, apply=True)
            record_adopted(target, vault, sources)


def record_adopted(target, vault, sources):
    path = Path(target) / '.adopted.json'
    data = json_read(path, []) or []
    base = Path(vault).resolve()
    for source in sources:
        relative = Path(source).resolve().relative_to(base).as_posix()
        if relative not in data:
            data.append(relative)
    atomic_json(path, data)


def migrate(vault, project_id, sources, apply=False, cwd=None):
    project = (resolve(vault, cwd) if cwd is not None else
               next((p for p in registry_read(vault)['projects'] if p['id'] == project_id), None))
    if not project:
        raise ValueError('no matching repository; specify --cwd or a registered --id')
    return migrate_project(vault, project, sources, apply)


def source_index(directory):
    for name in ('MEMORY.md', 'INDEX.md'):
        if (Path(directory) / name).is_file():
            return Path(directory) / name
    return None


def migrate_project(vault, project, sources, apply=False):
    """Lossless import. Refuse filename conflicts rather than guess which note is newer."""
    project_id = project['id']
    target = memory_path(vault, project['memory'])
    primary = target / 'MEMORY.md'
    index = target / 'INDEX.md'
    original_primary = primary.read_bytes() if primary.exists() else None
    original_index = index.read_bytes() if index.exists() else None
    text = (original_primary or original_index or f'# {project_id}\n'.encode()).decode()
    if original_primary is None and original_index is None and sources:
        # Initial adoption retains prose and headings too, including links to curated KB areas.
        first_index = source_index(sources[0])
        if first_index:
            text = first_index.read_text()
    additions = []
    copies = {}
    for source in sources:
        source = Path(source).resolve()
        if not source.is_dir() or source == target:
            raise ValueError('migration source must be an existing, separate memory directory')
        for note in sorted(source.rglob('*.md')):
            if note.name in ('MEMORY.md', 'INDEX.md') and note.parent == source:
                continue
            if note.is_symlink():
                raise ValueError('migration source contains a symlink; inspect it before importing')
            relative = note.relative_to(source)
            dest = target / relative
            if not dest.resolve().is_relative_to(target):
                raise ValueError('migration destination escapes project memory')
            content = note.read_bytes()
            if dest.exists() and dest.read_bytes() != content:
                raise ValueError('note conflict: ' + str(relative))
            if dest in copies and copies[dest] != content:
                raise ValueError('source note conflict: ' + str(relative))
            if not dest.exists():
                copies[dest] = content
        index_file = source_index(source)
        if index_file:
            for line in index_file.read_text().splitlines():
                if line.startswith('- ') and line not in text.splitlines() and line not in additions:
                    additions.append(line)
    if additions:
        text = text.rstrip() + '\n\n## Imported project notes\n\n' + '\n'.join(additions) + '\n'
    if len(text.splitlines()) > 200 or len(text.encode()) > 25000:
        raise ValueError('merged index exceeds the auto-memory startup budget')
    plan = dict(project=project_id, directory=str(target), new_notes=len(copies),
                index_lines=len(text.splitlines()), apply=apply)
    if not apply:
        return plan
    # Back up both entrypoints before replacing anything; leave all source notes intact.
    backup = Path(vault) / '.migration-backups' / project_id
    backup.mkdir(parents=True, exist_ok=True)
    for name, raw in [('MEMORY.md', original_primary), ('INDEX.md', original_index)]:
        if raw is not None:
            saved = backup / (name + '.' + hashlib.sha256(raw).hexdigest()[:12])
            if not saved.exists():
                saved.write_bytes(raw)
    target.mkdir(parents=True, exist_ok=True)
    for dest, content in copies.items():
        dest.parent.mkdir(parents=True, exist_ok=True)
        with dest.open('xb') as f:
            f.write(content)
    if (primary.read_bytes() if primary.exists() else None) != original_primary:
        raise ValueError('memory index changed during migration; imported notes preserved, rerun after review')
    if (index.read_bytes() if index.exists() else None) != original_index:
        raise ValueError('knowledge index changed during migration; imported notes preserved, rerun after review')
    if text.encode() != original_primary:
        atomic_text(primary, text)
    if not (index.is_symlink() and os.readlink(index) == 'MEMORY.md'):
        fd, tmp = tempfile.mkstemp(prefix='.repo-index-', dir=target)
        os.close(fd)
        os.unlink(tmp)
        try:
            os.symlink('MEMORY.md', tmp)
            os.replace(tmp, index)
        finally:
            if os.path.lexists(tmp):
                os.unlink(tmp)
    return plan


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'launch':
        launch(sys.argv[2:])
        return
    if len(sys.argv) > 1 and sys.argv[1] == 'home':
        import kb_homes
        config = json_read(config_dir() / 'secrets.json', {})
        container = in_container()
        env = kb_homes.environment(Path.home(), config, container)
        cwd = Path(sys.argv[2]) if len(sys.argv) > 2 else Path.cwd()
        home = kb_homes.home_for(configured_vault(config, container), env, cwd, create_local_id=False)
        print(json.dumps(home, ensure_ascii=False, indent=2))
        return
    if len(sys.argv) > 1 and sys.argv[1] in ('snapshot', 'review', 'undo'):
        import kb_review
        config = json_read(config_dir() / 'secrets.json', {})
        if config.get('kb', {}).get('reviewer') is not True:
            raise ValueError('this machine is not the knowledge-base reviewer (kb.reviewer)')
        vault = configured_vault(config, in_container())
        if sys.argv[1] == 'snapshot':
            sys.exit(kb_review.snapshot(vault))
        if sys.argv[1] == 'review':
            sys.exit(kb_review.review(vault, full='--full' in sys.argv[2:]))
        if len(sys.argv) < 3:
            raise ValueError('usage: claudefiles-kb undo <run> [<operation>]')
        sys.exit(kb_review.undo_run(vault, sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else None))
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for command in ('resolve', 'register', 'migrate'):
        p = sub.add_parser(command)
        p.add_argument('--vault', required=True, type=lambda p: Path(p).expanduser())
        if command == 'resolve':
            p.add_argument('--cwd', default='.')
        elif command == 'register':
            p.add_argument('--id', required=True)
        if command == 'register':
            p.add_argument('--remote', required=True)
            p.add_argument('--memory', required=True)
            p.add_argument('--context', required=True)
        if command == 'migrate':
            selector = p.add_mutually_exclusive_group(required=True)
            selector.add_argument('--id')
            selector.add_argument('--cwd')
            p.add_argument('--source', action='append', required=True)
            p.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if args.command == 'resolve':
        result = resolve(args.vault, args.cwd)
    elif args.command == 'register':
        result = register(args.vault, args.id, args.remote, args.memory, args.context)
    else:
        result = migrate(args.vault, args.id, args.source, args.apply, args.cwd)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, LookupError, OSError, TypeError, KeyError) as error:
        # Do not include input JSON or remote URLs (they can contain credentials).
        message = str(error) if not isinstance(error, json.JSONDecodeError) else 'invalid JSON configuration'
        print('kb: ' + message, file=sys.stderr)
        sys.exit(2)
