import hashlib
from pathlib import Path
import re

import repo_memory as rm


def folder_name(raw):
    name = re.sub(r'[^a-z0-9]+', '-', raw.lower()).strip('-')
    return name or 'dir-' + hashlib.sha256(raw.encode()).hexdigest()[:8]


def layer_name(value):
    if not value or value == 'none':
        return None
    if not isinstance(value, str) or not rm.LAYER.fullmatch(value):
        raise ValueError('invalid layer name: ' + str(value))
    return value


def environment(home, config, container):
    kb = config.get('kb', {})
    return dict(home=Path(home), context=layer_name(kb.get('context')),
                machine=None if container else layer_name(kb.get('machine')), container=container)


def context_root(env):
    return (env['home'] / 'main').resolve() if env['context'] else None


def layer_path(vault, relative):
    parts = Path(relative).parts
    if len(parts) == 2 and parts[0] in ('contexts', 'machine'):
        names = [parts[1]]
    elif len(parts) == 4 and parts[0] == 'contexts' and parts[2] == 'projects':
        names = [parts[1], parts[3]]
    else:
        raise ValueError('invalid memory home: ' + str(relative))
    if not all(rm.LAYER.fullmatch(name) for name in names):
        raise ValueError('invalid memory home: ' + str(relative))
    base = Path(vault).resolve()
    path = (base / relative).resolve()
    if not path.is_relative_to(base) or path == base:
        raise ValueError('memory home escapes the vault')
    return path


def _project_name(root, first):
    name = folder_name(first)
    for entry in root.iterdir():
        if entry.name != first and entry.is_dir() and folder_name(entry.name) == name:
            raise ValueError(f'folders {first!r} and {entry.name!r} in {root} share the memory name '
                             f'{name!r}; rename one')
    return name


def _home(vault, kind, relative, context):
    return dict(kind=kind, memory=relative, directory=str(layer_path(vault, relative)), context=context)


def home_for(vault, env, cwd, create_local_id=True):
    cwd = Path(cwd).resolve()
    root = context_root(env)
    project = rm.resolve(vault, cwd, create=create_local_id)
    if project:
        home = dict(project, kind='repository', context=project.get('context', env['context']))
        git_root = Path(rm.git_value(cwd, 'rev-parse', '--show-toplevel')).resolve()
        home['git_root'] = str(git_root)
        if root and git_root != root and git_root.is_relative_to(root):
            parts = git_root.relative_to(root).parts
            try:
                name = _project_name(root, parts[0])
            except ValueError:
                name = None
            if name:
                key = 'project_index' if len(parts) > 1 else 'adopt_from'
                home[key] = f"contexts/{env['context']}/projects/{name}"
        return home
    if root and cwd == root:
        return _home(vault, 'context', f"contexts/{env['context']}", env['context'])
    if root and cwd.is_relative_to(root):
        name = _project_name(root, cwd.relative_to(root).parts[0])
        return _home(vault, 'project', f"contexts/{env['context']}/projects/{name}", env['context'])
    if env['machine']:
        return _home(vault, 'machine', f"machine/{env['machine']}", env['context'])
    if env['container'] and env['context']:
        return _home(vault, 'context', f"contexts/{env['context']}", env['context'])
    return None
