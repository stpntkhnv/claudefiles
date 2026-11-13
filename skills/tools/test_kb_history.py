#!/usr/bin/env python3
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'lib/py'))
import kb_history as kh


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.vault = base / 'kb'
        self.state = base / 'state'
        (self.vault / 'global').mkdir(parents=True)
        (self.vault / 'global/a.md').write_text('one\n')
        (self.vault / 'personal.kdbx').write_bytes(b'secret')
        (self.vault / '.obsidian').mkdir()
        (self.vault / '.obsidian/app.json').write_text('{}')
        (self.vault / 'global/.memory-init.lock').write_text('')
        self.h = kh.History(self.state, self.vault).init()

    def tracked(self):
        return set(self.h.out('ls-files').splitlines())

    def test_snapshot_excludes_and_is_noop_when_clean(self):
        self.assertTrue(self.h.snapshot('snapshot 1'))
        self.assertEqual(self.tracked(), {'global/a.md'})
        self.assertIsNone(self.h.snapshot('snapshot 2'))
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        self.assertFalse((self.vault / '.git').exists())
        kh.History(self.state, self.vault).init()
        self.assertEqual(self.tracked(), {'global/a.md'})

    def test_blobs_roundtrip(self):
        oid = self.h.store('global/a.md')
        self.assertEqual(self.h.read(oid), b'one\n')
        self.assertEqual(self.h.current('global/a.md'), oid)
        self.assertIsNone(self.h.current('global/missing.md'))
        self.assertIsNone(self.h.store('global/missing.md'))
        self.assertEqual(self.h.read(self.h.store_bytes(b'two\n')), b'two\n')

    def test_commit_paths_only_given(self):
        self.h.snapshot('base')
        (self.vault / 'global/a.md').write_text('changed\n')
        (self.vault / 'global/b.md').write_text('unrelated\n')
        (self.vault / 'global/c.md').write_text('new\n')
        sha = self.h.commit_paths(['global/a.md', 'global/c.md', 'global/never.md'], 'review x')
        self.assertEqual(set(self.h.out('show', '--name-only', '--format=', sha).splitlines()),
                         {'global/a.md', 'global/c.md'})
        (self.vault / 'global/c.md').unlink()
        sha = self.h.commit_paths(['global/c.md'], 'delete c')
        self.assertEqual(self.h.out('show', '--name-status', '--format=', sha), 'D\tglobal/c.md')
        self.assertIsNone(self.h.commit_paths(['global/c.md'], 'nothing'))
        self.assertTrue(self.h.snapshot('picks up b'))
        self.assertIn('global/b.md', self.tracked())


if __name__ == '__main__':
    unittest.main()
