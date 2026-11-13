import os
from pathlib import Path
import subprocess

EXCLUDE = ('.obsidian/', '*.kdbx', '.stfolder', '.stversions/', '.stignore', '.trash/', '*.lock')


class History:
    def __init__(self, state, vault):
        self.state = Path(state)
        self.vault = Path(vault).resolve()
        self.git_dir = self.state / 'history.git'

    def git(self, *args, data=None, check=True):
        result = subprocess.run(['git', '--literal-pathspecs', f'--git-dir={self.git_dir}',
                                 f'--work-tree={self.vault}', *args],
                                cwd=self.vault, input=data, capture_output=True)
        if check and result.returncode != 0:
            raise RuntimeError(f'git {args[0]}: ' + result.stderr.decode(errors='replace').strip())
        return result

    def out(self, *args, **kw):
        return self.git(*args, **kw).stdout.decode(errors='replace').strip()

    def init(self):
        self.state.mkdir(parents=True, exist_ok=True)
        os.chmod(self.state, 0o700)
        if not (self.git_dir / 'HEAD').is_file():
            subprocess.run(['git', 'init', '-q', '--bare', str(self.git_dir)], check=True, capture_output=True)
            for key, value in (('core.bare', 'false'), ('user.name', 'claudefiles-kb'),
                               ('user.email', 'claudefiles-kb@localhost'), ('core.quotepath', 'false')):
                self.git('config', key, value)
        self.git('config', 'gc.pruneExpire', 'never')
        exclude = self.git_dir / 'info' / 'exclude'
        exclude.parent.mkdir(exist_ok=True)
        exclude.write_text('\n'.join(EXCLUDE) + '\n')
        return self

    def head(self):
        return self.out('rev-parse', '-q', '--verify', 'HEAD', check=False) or None

    def snapshot(self, message):
        self.git('add', '-A', '.')
        if self.head() and self.git('diff', '--cached', '--quiet', check=False).returncode == 0:
            return None
        self.git('commit', '-q', '--allow-empty', '--no-verify', '-m', message)
        return self.head()

    def store(self, rel):
        return self.out('hash-object', '-w', '--', str(rel)) if (self.vault / rel).is_file() else None

    def store_bytes(self, data):
        return self.out('hash-object', '-w', '--stdin', data=data)

    def current(self, rel):
        return self.out('hash-object', '--', str(rel)) if (self.vault / rel).is_file() else None

    def read(self, oid):
        return self.git('cat-file', 'blob', oid).stdout

    def commit_paths(self, paths, message):
        paths = sorted(set(paths))
        if not paths:
            return None
        tracked = set(self.out('ls-files', '--', *paths).splitlines())
        present = [p for p in paths if (self.vault / p).exists() or p in tracked]
        if not present:
            return None
        self.git('add', '-A', '--', *present)
        if self.git('diff', '--cached', '--quiet', '--', *present, check=False).returncode == 0:
            return None
        self.git('commit', '-q', '--no-verify', '-m', message, '--', *present)
        return self.head()
