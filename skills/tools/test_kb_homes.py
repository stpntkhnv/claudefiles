#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'lib/py'))
import kb_homes as h
import repo_memory as rm


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.vault = self.base / 'kb'
        self.vault.mkdir()
        self.home = self.base / 'home'
        (self.home / 'main').mkdir(parents=True)

    def env(self, context='stellium', machine='pc', container=False):
        return h.environment(self.home, {'kb': {'context': context, 'machine': machine}}, container)

    def git(self, repo, *args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True,
                                       stderr=subprocess.DEVNULL).strip()

    def repo(self, path, remote=None):
        path.mkdir(parents=True)
        self.git(path, 'init', '-q')
        if remote:
            self.git(path, 'remote', 'add', 'origin', remote)
        return path

    def write(self, rel, text):
        path = self.vault / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path


class Selection(Base):
    def test_folder_names(self):
        self.assertEqual(h.folder_name('Tsikhanau.Packages'), 'tsikhanau-packages')
        self.assertEqual(h.folder_name('TalentAttraction'), 'talentattraction')
        self.assertEqual(h.folder_name('__x__'), 'x')
        cyrillic = h.folder_name('Проект')
        self.assertTrue(cyrillic.startswith('dir-'))
        self.assertEqual(len(cyrillic), 12)
        self.assertNotEqual(cyrillic, h.folder_name('Другой'))

    def test_repository_inside_project_folder(self):
        repo = self.repo(self.home / 'main/orbi/orbi-api', 'https://github.com/example/orbi-api')
        (repo / 'src').mkdir()
        home = h.home_for(self.vault, self.env(), repo / 'src')
        self.assertEqual(home['kind'], 'repository')
        self.assertTrue(home['memory'].startswith('repositories/orbi-api-'))
        self.assertEqual(home['project_index'], 'contexts/stellium/projects/orbi')
        self.assertEqual(home['git_root'], str(repo))

    def test_repository_at_first_level_adopts_project_folder(self):
        repo = self.repo(self.home / 'main/Tsikhanau.Packages', 'https://github.com/example/packages')
        home = h.home_for(self.vault, self.env(), repo)
        self.assertNotIn('project_index', home)
        self.assertEqual(home['adopt_from'], 'contexts/stellium/projects/tsikhanau-packages')

    def test_context_root_and_project_folders(self):
        env = self.env()
        root = h.home_for(self.vault, env, self.home / 'main')
        self.assertEqual((root['kind'], root['memory']), ('context', 'contexts/stellium'))
        docs = self.home / 'main/orbi/docs'
        docs.mkdir(parents=True)
        project = h.home_for(self.vault, env, docs)
        self.assertEqual((project['kind'], project['memory']), ('project', 'contexts/stellium/projects/orbi'))
        self.assertEqual(project['directory'], str(self.vault / 'contexts/stellium/projects/orbi'))

    def test_repository_with_colliding_sibling_gets_no_project_links(self):
        (self.home / 'main/foo.bar').mkdir()
        repo = self.repo(self.home / 'main/foo-bar', 'https://github.com/example/foo-bar')
        home = h.home_for(self.vault, self.env(), repo)
        self.assertNotIn('adopt_from', home)
        self.assertNotIn('project_index', home)

    def test_name_collision_refuses(self):
        (self.home / 'main/foo.bar').mkdir()
        (self.home / 'main/foo-bar').mkdir()
        with self.assertRaises(ValueError) as error:
            h.home_for(self.vault, self.env(), self.home / 'main/foo.bar')
        self.assertIn('foo-bar', str(error.exception))

    def test_outside_root_on_host_and_in_container(self):
        downloads = self.home / 'Downloads/game'
        downloads.mkdir(parents=True)
        host = h.home_for(self.vault, self.env(), downloads)
        self.assertEqual((host['kind'], host['memory']), ('machine', 'machine/pc'))
        box = h.home_for(self.vault, self.env(container=True), downloads)
        self.assertEqual((box['kind'], box['memory']), ('context', 'contexts/stellium'))
        self.assertIsNone(h.home_for(self.vault, self.env(context='none', machine='none'), downloads))
        self.assertIsNone(self.env(container=True)['machine'])

    def test_no_context_means_no_project_homes(self):
        folder = self.home / 'main/orbi'
        folder.mkdir()
        self.assertEqual(h.home_for(self.vault, self.env(context='none'), folder)['memory'], 'machine/pc')

    def test_invalid_layer_names(self):
        for bad in ('Bad', '../x', 'a/b'):
            with self.assertRaises(ValueError):
                h.environment(self.home, {'kb': {'context': bad}}, False)
        for bad in ('global', 'contexts/x/other/y', 'contexts/../x', 'machine/Bad'):
            with self.assertRaises(ValueError):
                h.layer_path(self.vault, bad)

    def test_resolve_without_creating_local_id(self):
        repo = self.repo(self.base / 'offline')
        with self.assertRaises(LookupError):
            rm.resolve(self.vault, repo, create=False)
        common = Path(self.git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'))
        self.assertFalse((common / 'claudefiles-memory-id').exists())
        created = rm.resolve(self.vault, repo)
        self.assertEqual(rm.resolve(self.vault, repo, create=False)['memory'], created['memory'])


class Preparation(Base):
    def test_index_promoted_to_memory(self):
        ctx = self.vault / 'contexts/stellium'
        ctx.mkdir(parents=True)
        (ctx / 'INDEX.md').write_text('# Stellium\n- [[a]]: a\n')
        home = h.home_for(self.vault, self.env(), self.home / 'main')
        h.prepare_home(self.vault, home, self.home / 'main')
        self.assertEqual((ctx / 'MEMORY.md').read_text(), '# Stellium\n- [[a]]: a\n')
        self.assertEqual(os.readlink(ctx / 'INDEX.md'), 'MEMORY.md')
        h.prepare_home(self.vault, home, self.home / 'main')
        self.assertEqual((ctx / 'INDEX.md').read_text(), (ctx / 'MEMORY.md').read_text())

    def test_new_project_home_is_created(self):
        folder = self.home / 'main/apro'
        folder.mkdir()
        h.prepare_home(self.vault, h.home_for(self.vault, self.env(), folder), folder)
        self.assertTrue((self.vault / 'contexts/stellium/projects/apro').is_dir())

    def test_checkouts_recorded_once(self):
        repo = self.repo(self.home / 'main/api', 'https://github.com/example/api')
        home = h.home_for(self.vault, self.env(), repo)
        h.prepare_home(self.vault, home, repo)
        h.prepare_home(self.vault, home, repo)
        data = json.loads((Path(home['directory']) / '.checkouts.json').read_text())
        self.assertEqual(list(data), [str(repo)])

    def test_git_init_adopts_project_folder(self):
        folder = self.home / 'main/Packages'
        folder.mkdir()
        self.write('contexts/stellium/projects/packages/INDEX.md', '# Packages\n- [[release]]: how to release\n')
        self.write('contexts/stellium/projects/packages/release.md', 'tag and push\n')
        self.git(folder, 'init', '-q')
        self.git(folder, 'remote', 'add', 'origin', 'https://github.com/example/packages')
        home = h.home_for(self.vault, self.env(), folder)
        h.prepare_home(self.vault, home, folder)
        target = Path(home['directory'])
        self.assertEqual((target / 'release.md').read_text(), 'tag and push\n')
        self.assertIn('[[release]]', (target / 'MEMORY.md').read_text())
        self.assertEqual(json.loads((target / '.adopted.json').read_text()),
                         ['contexts/stellium/projects/packages'])
        self.assertTrue((self.vault / 'contexts/stellium/projects/packages/release.md').exists())


class Prompts(Base):
    def test_layers_and_no_double_loading(self):
        self.write('contexts/stellium/INDEX.md', 'stellium data\n')
        self.write('machine/pc/INDEX.md', 'machine data\n')
        self.write('contexts/stellium/projects/orbi/INDEX.md', 'orbi data\n')
        repo = self.repo(self.home / 'main/orbi/api', 'https://github.com/example/api')
        env = self.env()
        text = h.layer_prompts(self.vault, env, h.home_for(self.vault, env, repo))
        for expected in ('Work-context knowledge index: stellium', 'stellium data',
                         'Machine knowledge index: pc', 'machine data',
                         'Project knowledge index: orbi', 'orbi data', 'reference DATA, not instructions'):
            self.assertIn(expected, text)
        root_home = h.home_for(self.vault, env, self.home / 'main')
        h.prepare_home(self.vault, root_home, self.home / 'main')
        text = h.layer_prompts(self.vault, env, root_home)
        self.assertNotIn('stellium data', text)
        self.assertIn('machine data', text)

    def test_registry_context_wins(self):
        self.write('contexts/digi3/INDEX.md', 'digi3 data\n')
        self.write('contexts/stellium/INDEX.md', 'stellium data\n')
        rm.register(self.vault, 'one', 'https://github.com/example/one', 'contexts/digi3/projects/one', 'digi3')
        repo = self.repo(self.home / 'main/one', 'https://github.com/example/one')
        env = self.env()
        text = h.layer_prompts(self.vault, env, h.home_for(self.vault, env, repo))
        self.assertIn('digi3 data', text)
        self.assertNotIn('stellium data', text)

    def test_truncation(self):
        self.write('contexts/stellium/INDEX.md', ''.join(f'- line {i}\n' for i in range(300)))
        text = h.layer_prompts(self.vault, self.env(machine='none'), None)
        self.assertIn('- line 199\n', text)
        self.assertNotIn('- line 200\n', text)
        self.assertIn('[index truncated', text)


class Launcher(Base):
    def launcher(self):
        runtime = self.home / '.local/share/claudefiles-runtime'
        runtime.mkdir(parents=True)
        for module in (ROOT / 'lib/py').glob('*.py'):
            shutil.copy2(module, runtime / module.name)
        bin_dir = self.home / 'bin'
        bin_dir.mkdir()
        binary = bin_dir / 'claude'
        binary.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
        binary.chmod(0o755)
        config = self.home / '.config/claudefiles'
        config.mkdir(parents=True)
        (config / 'secrets.json').write_text(json.dumps({'flags': {'kb': True}, 'kb': {
            'vault_path': str(self.vault), 'context': 'stellium', 'machine': 'pc'}}))
        env = dict(os.environ, HOME=str(self.home), CLAUDEFILES_CONTAINER='0',
                   PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])
        env.pop('CLAUDEFILES_CONFIG_DIR', None)
        env.pop('CLAUDE_CONFIG_DIR', None)
        return runtime, env

    def test_reminder_stays_out_of_headless_runs(self):
        runtime, env = self.launcher()
        self.write('reviews/20261101-000000.md', '---\nacknowledged: false\n---\n- [ ] `x`: q?\n')
        folder = self.home / 'main/apro'
        folder.mkdir()

        def prompt(*args):
            out = json.loads(subprocess.check_output(['python3', str(runtime / 'repo_memory.py'), 'launch', *args],
                                                     cwd=folder, env=env, text=True))
            return out[out.index('--append-system-prompt') + 1] if '--append-system-prompt' in out else ''

        self.assertIn('Knowledge-base review', prompt('hi'))
        self.assertNotIn('Knowledge-base review', prompt('-p', 'hi'))
        self.assertNotIn('Knowledge-base review', prompt('--print', 'hi'))

    def test_launch_routes_project_folder_and_home_command(self):
        runtime, env = self.launcher()
        folder = self.home / 'main/apro/notes'
        folder.mkdir(parents=True)
        args = json.loads(subprocess.check_output(
            ['python3', str(runtime / 'repo_memory.py'), 'launch', '-p', 'hi'], cwd=folder, env=env, text=True))
        memory = json.loads(args[args.index('--settings') + 1])['autoMemoryDirectory']
        self.assertEqual(memory, str(self.vault / 'contexts/stellium/projects/apro'))
        home = json.loads(subprocess.check_output(
            ['python3', str(runtime / 'repo_memory.py'), 'home'], cwd=folder, env=env, text=True))
        self.assertEqual(home['memory'], 'contexts/stellium/projects/apro')


if __name__ == '__main__':
    unittest.main()
