#!/usr/bin/env python3
"""Behavioral tests with real local Git repositories and a recording Claude executable."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / 'lib/py/repo_memory.py'
spec = importlib.util.spec_from_file_location('repo_memory', MODULE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class MemoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.vault = self.base / 'shared kb'
        self.vault.mkdir()
        self.relative = 'contexts/digi3/projects/1anv'
        self.remote = 'git@ssh.dev.azure.com:v3/digi3/1ANV/1ANV'
        self.https = 'https://dev.azure.com/digi3/1ANV/_git/1ANV'
        m.register(self.vault, 'digi3-1anv', self.remote, self.relative, 'digi3')

    def git(self, repo, *args):
        return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.DEVNULL, text=True).strip()

    def repo(self, name, remote=None):
        path = self.base / name
        path.mkdir()
        self.git(path, 'init', '-q')
        if remote:
            self.git(path, 'remote', 'add', 'origin', remote)
        return path

    def test_transport_normalization_and_credentials(self):
        variants = [self.remote, self.https, 'ssh://git@ssh.dev.azure.com:22/v3/digi3/1ANV/1ANV',
                    'https://user:private@dev.azure.com/digi3/1ANV/_git/1ANV.git?token=secret',
                    'https://digi3.visualstudio.com/1ANV/_git/1ANV']
        self.assertEqual({m.canonical_remote(v) for v in variants}, {'azure:digi3/1ANV/1ANV'})
        self.assertEqual(m.canonical_remote('git@github.com:Owner/Repo.git'), 'github.com/owner/repo')
        self.assertEqual(m.canonical_remote('https://github.com/owner/repo/'), 'github.com/owner/repo')
        self.assertNotEqual(m.canonical_remote('ssh://git@example.com:2222/a/b'),
                            m.canonical_remote('ssh://git@example.com/a/b'))
        for value in ('/tmp/local', '../relative', 'file:///tmp/x', 'https://example.com/a/../b'):
            with self.assertRaises(ValueError):
                m.canonical_remote(value)

    def test_clones_rename_subdirectory_and_worktree_share_memory(self):
        first = self.repo('main original', self.remote)
        second = self.repo('sources renamed', self.https)
        nested = second / 'a/b'
        nested.mkdir(parents=True)
        expected = str(self.vault / self.relative)
        for p in (first, second, nested):
            self.assertEqual(m.resolve(self.vault, p)['directory'], expected)
        renamed = self.base / 'completely different'
        first.rename(renamed)
        self.assertEqual(m.resolve(self.vault, renamed)['directory'], expected)
        self.git(second, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-q', '--allow-empty', '-m', 'fixture')
        worktree = self.base / 'feature worktree'
        self.git(second, 'worktree', 'add', '-q', '-b', 'fixture-feature', str(worktree))
        self.assertEqual(m.resolve(self.vault, worktree)['directory'], expected)

    def test_unknown_fork_and_missing_remote_do_not_share_by_name(self):
        fork = self.repo('1ANV', 'git@ssh.dev.azure.com:v3/someone/1ANV/1ANV')
        offline = self.repo('offline')
        self.assertTrue(m.resolve(self.vault, fork)['automatic'])
        self.assertNotEqual(m.resolve(self.vault, fork)['memory'], self.relative)
        self.assertTrue(m.resolve(self.vault, offline)['identity'].startswith('local:'))
        self.assertIsNone(m.resolve(self.vault, self.base))
        self.git(offline, 'config', 'claudefiles.memoryProject', 'digi3-1anv')
        self.assertEqual(m.resolve(self.vault, offline)['id'], 'digi3-1anv')
        self.git(offline, 'config', 'claudefiles.memoryProject', 'missing')
        with self.assertRaises(ValueError):
            m.resolve(self.vault, offline)

    def test_automatic_identity_across_machines_without_registration(self):
        other_vault = self.base / 'another machine/notes'
        other_vault.mkdir(parents=True)
        # Neither machine needs a registry, a profile-specific entry or a context folder.
        first_vault = self.base / 'clean machine/notes'
        first_vault.mkdir(parents=True)
        a = m.resolve(first_vault, self.repo('machine A sources', 'git@github.com:Example/Widget.git'))
        b = m.resolve(other_vault, self.repo('machine B arbitrary', 'https://github.com/example/widget'))
        self.assertEqual(a['memory'], b['memory'])
        self.assertEqual(a['id'], b['id'])
        self.assertNotEqual(a['directory'], b['directory'])
        self.assertTrue(a['memory'].startswith('repositories/widget-'))
        self.assertNotIn('context', a)
        self.assertFalse((first_vault / m.REGISTRY).exists())
        self.assertFalse((other_vault / m.REGISTRY).exists())
        fork = m.resolve(first_vault, self.repo('fork', 'https://github.com/someone/widget.git'))
        self.assertNotEqual(fork['memory'], a['memory'])

    def test_offline_repository_identity_survives_move_and_worktrees(self):
        repo = self.repo('no remote')
        first = m.resolve(self.vault, repo)
        renamed = self.base / 'moved local repository'
        repo.rename(renamed)
        self.assertEqual(m.resolve(self.vault, renamed)['memory'], first['memory'])
        self.git(renamed, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-q', '--allow-empty', '-m', 'fixture')
        worktree = self.base / 'offline worktree'
        self.git(renamed, 'worktree', 'add', '-q', '-b', 'offline-feature', str(worktree))
        self.assertEqual(m.resolve(self.vault, worktree)['memory'], first['memory'])
        self.assertNotEqual(m.resolve(self.vault, self.repo('unrelated local'))['memory'], first['memory'])

    def test_adding_origin_adopts_offline_notes(self):
        repo = self.repo('initially offline')
        project = m.resolve(self.vault, repo)
        m.prepare_memory(self.vault, project, repo)
        target = Path(project['directory'])
        (target / 'MEMORY.md').write_text('# Notes\n\nRead the curated project index.\n- [Build](build.md)\n')
        (target / 'build.md').write_text('offline work\n')
        self.git(repo, 'remote', 'add', 'origin', 'https://github.com/example/published')
        published = m.resolve(self.vault, repo)
        self.assertNotEqual(published['memory'], project['memory'])
        m.prepare_memory(self.vault, published, repo)
        self.assertEqual((Path(published['directory']) / 'MEMORY.md').read_text(),
                         (target / 'MEMORY.md').read_text())
        self.assertEqual((Path(published['directory']) / 'build.md').read_text(), 'offline work\n')

    def test_first_launch_adopts_current_legacy_memory_without_registry(self):
        repo = self.repo('existing checkout', 'https://github.com/example/existing.git')
        slug = m.re.sub(r'[^a-zA-Z0-9]', '-', str(repo))
        source = self.vault / 'projects' / slug / 'memory'
        source.mkdir(parents=True)
        (source / 'MEMORY.md').write_text('# Existing\n\n- [Build](build.md): test instructions\n')
        (source / 'build.md').write_text('run the existing build\n')
        before = {p.name: p.read_bytes() for p in source.iterdir()}
        project = m.resolve(self.vault, repo)
        m.prepare_memory(self.vault, project, repo)
        target = Path(project['directory'])
        self.assertEqual((target / 'build.md').read_bytes(), (source / 'build.md').read_bytes())
        self.assertIn('(build.md)', (target / 'MEMORY.md').read_text())
        # Older notes can also be imported explicitly after moving a checkout.
        self.assertEqual(m.migrate(self.vault, None, [source], cwd=repo)['project'], project['id'])
        (target / 'build.md').write_text('newer facts\n')
        m.prepare_memory(self.vault, project, repo)
        self.assertEqual((target / 'build.md').read_text(), 'newer facts\n')
        self.assertEqual(before, {p.name: p.read_bytes() for p in source.iterdir()})

    def test_relocation_adds_alias_and_collisions_do_not_publish(self):
        other = 'git@git.example.com:team/1ANV.git'
        m.register(self.vault, 'digi3-1anv', other, self.relative, 'digi3')
        self.assertEqual(m.resolve(self.vault, self.repo('new server', other))['memory'], self.relative)
        registry = self.vault / m.REGISTRY
        before = registry.read_bytes()
        with self.assertRaises(ValueError):
            m.register(self.vault, 'other', self.https, 'contexts/digi3/projects/other', 'digi3')
        self.assertEqual(before, registry.read_bytes())
        with self.assertRaises(ValueError):
            m.register(self.vault, 'other', 'https://example.com/other', self.relative, 'digi3')
        self.assertEqual(before, registry.read_bytes())

    def test_paths_cannot_escape_vault(self):
        for relative in ('../outside', '/tmp/outside', '.', 'global'):
            with self.assertRaises(ValueError):
                m.memory_path(self.vault, relative)
        target = self.vault / 'contexts/digi3/projects'
        target.mkdir(parents=True)
        (target / 'escape').symlink_to(self.base, target_is_directory=True)
        with self.assertRaises(ValueError):
            m.memory_path(self.vault, 'contexts/digi3/projects/escape')

    def test_migration_is_lossless_and_repeatable(self):
        target = self.vault / self.relative
        target.mkdir(parents=True)
        (target / 'INDEX.md').write_text('# Curated\n\n- [[old]]: curated note\n')
        (target / 'old.md').write_text('curated contents\n')
        source = self.base / 'legacy-memory'
        source.mkdir()
        (source / 'MEMORY.md').write_text('- [New](new.md): recent note\n')
        (source / 'new.md').write_text('recent contents\n')
        old_source = {p.name: p.read_bytes() for p in source.iterdir()}
        self.assertEqual(m.migrate(self.vault, 'digi3-1anv', [source])['new_notes'], 1)
        self.assertFalse((target / 'MEMORY.md').exists())
        m.migrate(self.vault, 'digi3-1anv', [source], apply=True)
        self.assertTrue((target / 'INDEX.md').is_symlink())
        self.assertEqual((target / 'INDEX.md').read_bytes(), (target / 'MEMORY.md').read_bytes())
        self.assertIn('[[old]]', (target / 'MEMORY.md').read_text())
        self.assertIn('(new.md)', (target / 'MEMORY.md').read_text())
        before = {p.name: p.read_bytes() for p in target.iterdir()}
        self.assertEqual(m.migrate(self.vault, 'digi3-1anv', [source], apply=True)['new_notes'], 0)
        self.assertEqual(before, {p.name: p.read_bytes() for p in target.iterdir()})
        self.assertEqual(old_source, {p.name: p.read_bytes() for p in source.iterdir()})
        self.assertTrue(list((self.vault / '.migration-backups/digi3-1anv').glob('INDEX.md.*')))

    def test_conflicting_notes_abort_before_mutations(self):
        target = self.vault / self.relative
        target.mkdir(parents=True)
        (target / 'existing.md').write_text('original')
        source = self.base / 'legacy'
        source.mkdir()
        (source / 'new.md').write_text('new')
        (source / 'existing.md').write_text('conflicting')
        with self.assertRaises(ValueError):
            m.migrate(self.vault, 'digi3-1anv', [source], apply=True)
        self.assertEqual((target / 'existing.md').read_text(), 'original')
        self.assertFalse((target / 'new.md').exists())

    def test_user_settings_and_prompt_are_preserved(self):
        settings = self.base / 'user settings.json'
        settings.write_text(json.dumps({'env': {'USER_VALUE': 'keep'}, 'autoMemoryEnabled': False}))
        result = m.launch_args(['--settings', str(settings), '--append-system-prompt', 'user instruction',
                                '-p', 'hello', '--', '--settings'], '/memory', 'context data')
        combined = json.loads(result[result.index('--settings') + 1])
        self.assertEqual(combined['env'], {'USER_VALUE': 'keep'})
        self.assertIs(combined['autoMemoryEnabled'], False)
        self.assertEqual(combined['autoMemoryDirectory'], '/memory')
        self.assertIn('user instruction', result[result.index('--append-system-prompt') + 1])
        self.assertEqual(result[-4:], ['-p', 'hello', '--', '--settings'])
        result = m.launch_args(['--settings={"autoMemoryDirectory":"/explicit"}'], '/automatic', '')
        self.assertEqual(json.loads(result[1])['autoMemoryDirectory'], '/explicit')

    def test_real_launcher_argv_profiles_and_admin_passthrough(self):
        home = self.base / 'home'
        runtime = home / '.local/share/claudefiles-runtime'
        runtime.mkdir(parents=True)
        for module in MODULE.parent.glob('*.py'):
            shutil.copy2(module, runtime / module.name)
        shimdir = runtime / 'bin'
        shimdir.mkdir()
        shim = shimdir / 'claude'
        shim.write_text('#!/bin/sh\n# claudefiles-memory-launcher\nexit 99\n')
        shim.chmod(0o755)
        bin_dir = home / 'bin'
        bin_dir.mkdir()
        binary = bin_dir / 'claude'
        binary.write_text('#!/usr/bin/env python3\nimport json,os,sys\nprint(json.dumps({"args":sys.argv[1:],"profile":os.environ.get("CLAUDE_CONFIG_DIR")}))\n')
        binary.chmod(0o755)
        config = home / '.config/claudefiles'
        config.mkdir(parents=True)
        (config / 'secrets.json').write_text(json.dumps({'flags': {'kb': True}, 'kb': {
            'vault_path': str(self.vault), 'context': 'personal'}}))
        (self.vault / 'contexts/digi3').mkdir(parents=True)
        (self.vault / 'contexts/digi3/INDEX.md').write_text('Digi3 reference note\n')
        repo = self.repo('outside-main', self.https)
        env = dict(os.environ, HOME=str(home), PATH=os.pathsep.join([str(shimdir), str(bin_dir), os.environ['PATH']]))
        env.pop('CLAUDEFILES_CONFIG_DIR', None)
        for profile in ('.claude', '.claude-super', '.claude-g'):
            env['CLAUDE_CONFIG_DIR'] = str(home / profile)
            result = subprocess.check_output(['python3', str(runtime / 'repo_memory.py'), 'launch', '-p', 'hello'],
                                             cwd=repo, env=env, text=True)
            recorded = json.loads(result)
            self.assertEqual(recorded['profile'], str(home / profile))
            args = recorded['args']
            self.assertEqual(json.loads(args[1])['autoMemoryDirectory'], str(self.vault / self.relative))
            self.assertIn('Digi3 reference note', args[args.index('--append-system-prompt') + 1])
        (self.vault / m.REGISTRY).write_text('bad JSON')
        result = subprocess.check_output(['python3', str(runtime / 'repo_memory.py'), 'launch', 'mcp', 'list'],
                                         cwd=repo, env=env, text=True)
        self.assertEqual(json.loads(result)['args'], ['mcp', 'list'])

    def test_installation_on_two_clean_homes_routes_plain_claude(self):
        locations = []
        for name, context, remote in [('laptop', 'personal', 'https://github.com/example/new-project.git'),
                                       ('workstation', 'work', 'git@github.com:example/new-project')]:
            home = self.base / name
            binary = home / 'bin/claude'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
            binary.chmod(0o755)
            vault = home / 'notes'
            index = vault / 'contexts' / context / 'INDEX.md'
            index.parent.mkdir(parents=True)
            index.write_text(f'{context} reference data\n')
            config = home / '.config/claudefiles/secrets.json'
            config.parent.mkdir(parents=True)
            config.write_text(json.dumps({'flags': {'kb': True}, 'kb': {
                'vault_path': str(vault), 'context': context}}))
            (home / '.bashrc').write_text('# user shell preferences\nexport USER_SHELL_VALUE=keep\n')
            env = dict(os.environ, HOME=str(home), SHELL='/bin/bash', CLAUDEFILES_CONTAINER='0',
                       PATH=str(binary.parent) + os.pathsep + os.environ['PATH'])
            env.pop('CLAUDEFILES_CONFIG_DIR', None)
            env.pop('CLAUDE_CONFIG_DIR', None)
            install = 'source "$1/lib/common.sh"; source "$1/lib/kb.sh"; kb_launchers_apply "$1"'
            subprocess.check_call(['bash', '-c', install, 'install', str(ROOT)], env=env)
            first = (home / '.bashrc').read_bytes()
            subprocess.check_call(['bash', '-c', install, 'install', str(ROOT)], env=env)
            self.assertEqual(first, (home / '.bashrc').read_bytes())
            self.assertIn(b'export USER_SHELL_VALUE=keep', first)
            repo = self.repo(name + ' arbitrary folder', remote)
            for invocation in [
                ['bash', '--noprofile', '--rcfile', str(home / '.bashrc'), '-ic', 'claude -p hello'],
                ['bash', '--noprofile', '--norc', '-c', '. "$HOME/.profile"; claude -p hello'],
            ]:
                args = json.loads(subprocess.check_output(invocation, cwd=repo, env=env, text=True,
                                                           stderr=subprocess.DEVNULL))
                memory = json.loads(args[args.index('--settings') + 1])['autoMemoryDirectory']
                self.assertTrue(Path(memory).is_dir())
                locations.append(Path(memory).relative_to(vault).as_posix())
                self.assertIn(f'{context} reference data', args[args.index('--append-system-prompt') + 1])
            self.assertFalse((vault / m.REGISTRY).exists())
        self.assertEqual(len(set(locations)), 1)


if __name__ == '__main__':
    unittest.main()
