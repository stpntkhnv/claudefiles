#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'lib/py'))
import kb_apply as ka
import kb_history as kh
import kb_review as kr

class ReviewBase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.home = self.base / 'home'
        self.vault = self.base / 'kb'
        self.state = self.base / 'state'
        self.box = self.home / 'homes/stellium'
        for path in (self.home / 'main', self.box / 'main', self.vault):
            path.mkdir(parents=True, exist_ok=True)
        self.config(self.home, {'flags': {'kb': True}, 'kb': {
            'vault_path': str(self.vault), 'context': 'personal', 'machine': 'pc', 'reviewer': True}})
        self.config(self.box, {'flags': {'kb': True}, 'kb': {'vault_path': str(self.vault), 'context': 'stellium'}})
        patch = mock.patch.dict(os.environ, {
            'HOME': str(self.home), 'CLAUDEFILES_KB_STATE': str(self.state),
            'CLAUDEFILES_KB_BOX_HOMES': str(self.home / 'homes'),
            'CLAUDEFILES_CONFIG_DIR': str(self.home / '.config/claudefiles'), 'CLAUDEFILES_CONTAINER': '0'})
        patch.start()
        self.addCleanup(patch.stop)

    def config(self, home, data):
        path = home / '.config/claudefiles/secrets.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data))

    def write(self, rel, text):
        path = self.vault / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def note(self, rel, name, description):
        return self.write(rel, f'---\nname: {name}\ndescription: {description}\nmetadata:\n  type: project\n'
                               f'---\n\nbody of {name}\n')


class Autofix(ReviewBase):
    def test_environments(self):
        self.assertEqual([(e['context'], e['container']) for e in kr.environments()],
                         [('personal', False), ('stellium', True)])

    def test_legacy_mapping_uses_the_box_environment(self):
        orbi = self.box / 'main/orbi'
        orbi.mkdir()
        self.write(f'projects/{kr.slug(orbi)}/memory/note.md', 'x')
        self.write('projects/-gone-folder/memory/g.md', 'g')
        mapping = {e['source']: e for e in kr.legacy(self.vault, kr.environments())}
        self.assertEqual(mapping[f'projects/{kr.slug(orbi)}/memory']['home'], 'contexts/stellium/projects/orbi')
        self.assertIsNone(mapping['projects/-gone-folder/memory']['home'])
        self.assertEqual(mapping['projects/-gone-folder/memory']['reason'], 'папка не найдена')

    def test_autofix_and_empty_dirs(self):
        orbi = self.box / 'main/orbi'
        orbi.mkdir()
        self.write('contexts/stellium/projects/orbi/same.md', 'same\n')
        legacy = self.vault / 'projects' / kr.slug(orbi) / 'memory'
        self.write(f'projects/{kr.slug(orbi)}/memory/same.md', 'same\n')
        self.write(f'projects/{kr.slug(orbi)}/memory/other.md', 'different\n')
        self.write(f'projects/{kr.slug(orbi)}/memory/workbook/build.py', 'print(1)\n')
        self.write(f'projects/{kr.slug(orbi)}/memory/MEMORY.md', '- [Same](same.md): s\n')
        self.write('projects/-home-x/memory/.memory-init.lock', '')
        self.write('projects/-home-y/memory/MEMORY.md', '# y\n- [Gone](gone.md): gone\n')
        self.write('projects/-home-z/memory/MEMORY.md', '# z\nprose that nobody else holds\n')
        self.note('global/n.md', 'n', 'n')
        self.write('global/n.sync-conflict-20261001-101010-ABCDEF7.md', (self.vault / 'global/n.md').read_text())
        self.write('global/INDEX.md', '# g\n- [[n]]: n\n- [[gone]]: gone\n')
        history = kh.History(self.state, self.vault).init()
        history.snapshot('base')
        journal = ka.Journal(self.state / 'runs/r/journal.json', 'r')
        mapping, conflicts, records, skipped = kr.autofix(history, self.vault, journal, kr.environments())
        self.assertFalse((legacy / 'same.md').exists())
        self.assertTrue((legacy / 'other.md').exists())
        self.assertEqual((self.vault / 'contexts/stellium/projects/orbi/workbook/build.py').read_text(), 'print(1)\n')
        self.assertFalse((self.vault / 'global/n.sync-conflict-20261001-101010-ABCDEF7.md').exists())
        self.assertNotIn('gone', (self.vault / 'global/INDEX.md').read_text())
        self.assertEqual((conflicts, skipped), ([], []))
        ka.run_ops(history, self.vault, journal, kr.empty_dir_ops(self.vault))
        self.assertFalse((self.vault / 'projects/-home-x').exists())
        self.assertTrue((self.vault / 'projects/-home-y').exists())
        self.assertTrue((self.vault / 'projects/-home-z').exists())
        self.assertTrue(legacy.exists())

    def test_duplicate_op_skipped_when_copy_changes_during_run(self):
        self.write('contexts/stellium/projects/orbi/same.md', 'same\n')
        copy = self.write('projects/-x/memory/same.md', 'same\n')
        ops = kr.duplicate_ops(self.vault, [('projects/-x/memory', 'contexts/stellium/projects/orbi')])
        copy.write_text('changed\n')
        history = kh.History(self.state, self.vault).init()
        history.snapshot('base')
        journal = ka.Journal(self.state / 'runs/r/journal.json', 'r')
        records, skipped = ka.run_ops(history, self.vault, journal, ops)
        self.assertTrue(copy.exists())
        self.assertEqual(records, [])
        self.assertEqual(len(skipped), 1)

    def test_duplicate_op_skipped_when_twin_changes_during_run(self):
        twin = self.write('contexts/stellium/projects/orbi/same.md', 'same\n')
        copy = self.write('projects/-x/memory/same.md', 'same\n')
        ops = kr.duplicate_ops(self.vault, [('projects/-x/memory', 'contexts/stellium/projects/orbi')])
        twin.write_text('changed\n')
        history = kh.History(self.state, self.vault).init()
        history.snapshot('base')
        journal = ka.Journal(self.state / 'runs/r/journal.json', 'r')
        records, skipped = ka.run_ops(history, self.vault, journal, ops)
        self.assertTrue(copy.exists())
        self.assertEqual(records, [])
        self.assertEqual(len(skipped), 1)

    def test_report_retention(self):
        for day in range(1, 16):
            self.write(f'reviews/202611{day:02d}-000000.md', '---\nacknowledged: true\n---\nnothing\n')
        self.write('reviews/20261100-000000.md', '---\nacknowledged: true\n---\n- [ ] `x`: open\n')
        removed = sorted(op['subject'] for op in kr.report_ops(self.vault))
        self.assertEqual(removed, [f'reviews/202611{day:02d}-000000.md' for day in (1, 2, 3)])

    def test_worklist(self):
        self.write('global/big.md', '---\nname: big\ndescription: big\nmetadata:\n  type: project\n---\n' + 'x' * 11000)
        self.write('global/plain.md', 'no frontmatter, see ~/nowhere/here\n')
        self.write('global/INDEX.md', ''.join(f'- line {i}\n' for i in range(60)))
        self.write('contexts/stellium/projects/chat-jti/note.md', 'x')
        (self.vault / 'repositories/chatjti-0123456789abcdef01234567').mkdir(parents=True)
        work = kr.build_worklist(self.vault, 'r', [], [], [], {}, True, {})
        self.assertEqual(work['oversize'], ['global/big.md'])
        self.assertEqual(work['untyped'], ['contexts/stellium/projects/chat-jti/note.md', 'global/plain.md'])
        self.assertEqual(work['dead_paths'], {'global/plain.md': ['~/nowhere/here']})
        self.assertEqual(work['over_cap'][0]['index'], 'global/INDEX.md')
        self.assertIn('global/INDEX.md', work['hashes'])
        self.assertEqual(work['curated'], [{'folder': 'contexts/stellium/projects/chat-jti',
                                            'candidates': ['repositories/chatjti-0123456789abcdef01234567']}])

    def test_rotation(self):
        for i in range(8):
            self.write(f'global/n{i}.md', f'n{i}')
        old = time.time() - 1000
        for path in (self.vault / 'global').glob('*.md'):
            os.utime(path, (old, old))
        cursor = {'cursor': 0, 'last_run': time.time() - 10}
        first = kr.build_worklist(self.vault, 'r', [], [], [], {}, False, cursor)
        self.assertEqual(len(first['selection']), 2)
        second = kr.build_worklist(self.vault, 'r', [], [], [], {}, False,
                                   {'cursor': first['next_cursor'], 'last_run': cursor['last_run']})
        self.assertFalse(set(first['selection']) & set(second['selection']))
        self.write('global/n0.md', 'changed')
        third = kr.build_worklist(self.vault, 'r', [], [], [], {}, False, cursor)
        self.assertIn('global/n0.md', third['selection'])


if __name__ == '__main__':
    unittest.main()
