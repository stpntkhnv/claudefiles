#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'lib/py'))
import kb_tasks as kt
import repo_memory as rm


class TaskTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.vault = self.base / 'kb'
        self.vault.mkdir()

    def git(self, repo, *args):
        return subprocess.check_output(['git', '-C', str(repo), '-c', 'user.name=t', '-c', 'user.email=t@t',
                                        *args], text=True, stderr=subprocess.DEVNULL).strip()

    def clone(self, name, remote, subjects):
        path = self.base / name
        path.mkdir()
        self.git(path, 'init', '-q', '-b', 'main')
        self.git(path, 'remote', 'add', 'origin', remote)
        for subject in subjects:
            self.git(path, 'commit', '-q', '--allow-empty', '-m', subject)
        self.git(path, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
        return path

    def bind(self, clone):
        layer = rm.resolve(self.vault, clone)['memory']
        (self.vault / layer).mkdir(parents=True, exist_ok=True)
        rm.atomic_json(self.vault / layer / '.checkouts.json', {str(clone): '2026-11-13'})
        return layer

    def task(self, layer, name, link, age_days=0, status='active'):
        rel = f'{layer}/{name}.md'
        path = self.vault / rel
        path.write_text(f'---\nname: {name}\ndescription: d\nmetadata:\n  type: task\n  status: {status}\n'
                        f'  link: {link}\n---\nbody\n')
        if age_days:
            stamp = time.time() - age_days * 86400
            os.utime(path, (stamp, stamp))
        return rel

    def test_parse_link(self):
        self.assertEqual(kt.parse_link('https://dev.azure.com/org/My%20Proj/_git/Repo/pullrequest/12'),
                         ('ado', 'azure:org/My Proj/Repo', 12))
        self.assertEqual(kt.parse_link('https://org.visualstudio.com/Proj/_git/Repo/pullrequest/7'),
                         ('ado', 'azure:org/Proj/Repo', 7))
        self.assertEqual(kt.parse_link('https://github.com/Owner/Repo/pull/5'), ('github', 'github.com/owner/repo', 5))
        self.assertEqual(kt.parse_link('branch:feature/x'), ('branch', None, 'feature/x'))
        self.assertIsNone(kt.parse_link('https://example.com/ticket/1'))
        self.assertIsNone(kt.parse_link(None))

    def test_ado_merge_found_only_in_matching_checkout(self):
        remote = 'https://dev.azure.com/org/Proj/_git/Api'
        clone = self.clone('api', remote, ['init', 'Merged PR 42: add thing'])
        layer = self.bind(clone)
        info = kt.status(self.vault, self.task(layer, 'pr-42', remote + '/pullrequest/42'))
        self.assertEqual((info['status'], info['sha']), ('merged', self.git(clone, 'rev-parse', 'HEAD')))
        self.assertEqual(info['checkout'], str(clone))
        self.assertEqual(kt.status(self.vault, self.task(layer, 'pr-43', remote + '/pullrequest/43'))['status'],
                         'unconfirmed')
        foreign = self.task(layer, 'foreign', 'https://dev.azure.com/org/Proj/_git/Other/pullrequest/42')
        self.assertEqual(kt.status(self.vault, foreign)['status'], 'unconfirmed')

    def test_github_subject_forms(self):
        remote = 'https://github.com/example/web'
        clone = self.clone('web', remote, ['init', 'Fix login (#7)', 'Merge pull request #9 from x/y'])
        layer = self.bind(clone)
        for number in (7, 9):
            rel = self.task(layer, f'pr-{number}', f'{remote}/pull/{number}')
            self.assertEqual(kt.status(self.vault, rel)['status'], 'merged')
        self.assertEqual(kt.status(self.vault, self.task(layer, 'pr-8', f'{remote}/pull/8'))['status'], 'unconfirmed')

    def test_reused_checkout_path_is_ignored(self):
        remote = 'https://github.com/example/web'
        clone = self.clone('web', remote, ['init', 'Fix (#7)'])
        layer = self.bind(clone)
        self.git(clone, 'remote', 'set-url', 'origin', 'https://github.com/example/other')
        self.assertEqual(kt.status(self.vault, self.task(layer, 'pr-7', f'{remote}/pull/7'))['status'], 'unconfirmed')

    def test_branch_staleness_and_declared(self):
        remote = 'https://github.com/example/svc'
        clone = self.clone('svc', remote, ['init'])
        self.git(clone, 'update-ref', 'refs/remotes/origin/feature/x', 'HEAD')
        layer = self.bind(clone)
        branch = self.task(layer, 'branch', 'branch:feature/x')
        info = kt.status(self.vault, branch)
        self.assertEqual(info['status'], 'branch-merged')
        self.assertIn('Ветка', kt.question(info))
        old = self.task(layer, 'old', f'{remote}/pull/99', age_days=45)
        self.assertIn('45', kt.question(kt.status(self.vault, old)))
        fresh = self.task(layer, 'fresh', f'{remote}/pull/98')
        self.assertIsNone(kt.question(kt.status(self.vault, fresh)))
        done = self.task(layer, 'done', f'{remote}/pull/97', age_days=90, status='done')
        self.assertEqual(kt.status(self.vault, done)['status'], 'declared-done')
        self.assertIsNone(kt.question(kt.status(self.vault, done)))
        (self.vault / layer / 'plain.md').write_text('---\nname: plain\nmetadata:\n  type: project\n---\nx\n')
        self.assertEqual(set(kt.task_notes(self.vault)), {branch, old, fresh, done})


if __name__ == '__main__':
    unittest.main()
