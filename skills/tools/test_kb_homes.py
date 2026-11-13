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


if __name__ == '__main__':
    unittest.main()
