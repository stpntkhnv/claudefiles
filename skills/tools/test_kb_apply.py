#!/usr/bin/env python3
import fcntl
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'lib/py'))
import kb_apply as ka
import kb_history as kh
import kb_vault as kv


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.vault = base / 'kb'
        self.note('global/a.md', 'a', 'note a')
        self.note('global/b.md', 'b', 'note b')
        self.write('global/INDEX.md', '# Global\n- [[a]]: note a\n- [[b]]: note b\n')
        (self.vault / 'machine/pc').mkdir(parents=True)
        self.history = kh.History(base / 'state', self.vault).init()
        self.history.snapshot('base')
        self.run_dir = base / 'state/runs/r1'
        (self.run_dir / 'staging').mkdir(parents=True)
        self.journal = ka.Journal(self.run_dir / 'journal.json', 'r1')

    def write(self, rel, text):
        path = self.vault / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def note(self, rel, name, description, extra=''):
        return self.write(rel, f'---\nname: {name}\ndescription: {description}\nmetadata:\n  type: project\n'
                               f'{extra}---\n\nbody of {name}\n')

    def stage(self, name, text):
        (self.run_dir / 'staging' / name).write_text(text)
        return 'staging/' + name

    def expected(self):
        return {rel: kv.file_hash(self.vault / rel) for rel in kv.all_notes(self.vault) + ['global/INDEX.md']}

    def decide(self, *operations):
        return ka.from_model(self.vault, self.run_dir, {'operations': list(operations), 'questions': []})

    def apply(self, ops, tasks=None):
        records, skipped = ka.run_ops(self.history, self.vault, self.journal, ops, self.expected(), tasks or {})
        links, merged = ka.collect_links(records)
        fixed, fixup_skipped = ka.run_fixups(self.history, self.vault, self.journal,
                                             ka.layers_of(p for r in records for p in r['paths']), links, merged)
        records += fixed
        skipped += fixup_skipped
        return records, skipped

    def test_write_move_and_undo_run(self):
        ops, bad = self.decide(
            {'op': 'write', 'path': 'global/a.md', 'staged': self.stage('a.md', 'new a\n'), 'reason': 'r',
             'evidence': 'e'},
            {'op': 'move', 'path': 'global/b.md', 'to': 'machine/pc/', 'reason': 'r', 'evidence': 'e'})
        self.assertEqual(bad, [])
        records, skipped = self.apply(ops)
        self.assertEqual(skipped, [])
        self.assertEqual((self.vault / 'global/a.md').read_text(), 'new a\n')
        self.assertTrue((self.vault / 'machine/pc/b.md').is_file())
        self.assertFalse((self.vault / 'global/b.md').exists())
        self.assertNotIn('[[b]]', (self.vault / 'global/INDEX.md').read_text())
        self.assertIn('- [[b]]: note b', (self.vault / 'machine/pc/MEMORY.md').read_text())
        results = ka.undo(self.history, self.vault, self.journal.path)
        self.assertTrue(results and all(outcome == 'undone' for _, outcome in results))
        self.assertIn('body of a', (self.vault / 'global/a.md').read_text())
        self.assertIn('body of b', (self.vault / 'global/b.md').read_text())
        self.assertFalse((self.vault / 'machine/pc/b.md').exists())
        self.assertFalse((self.vault / 'machine/pc/MEMORY.md').exists())
        self.assertIn('[[b]]', (self.vault / 'global/INDEX.md').read_text())

    def test_validation_rules(self):
        (self.vault / 'contexts/s').mkdir(parents=True)
        self.note('global/task.md', 'task', 'open task', extra='  status: active\n  link: branch:x\n')
        task = self.vault / 'global/task.md'
        task.write_text(task.read_text().replace('type: project', 'type: task'))
        self.write('machine/pc/b.md', 'clash\n')
        expected = self.expected()
        ops, bad = self.decide(
            {'op': 'delete', 'path': 'global/task.md', 'reason': 'r', 'evidence': 'e'},
            {'op': 'move', 'path': 'global/b.md', 'to': 'machine/pc/', 'reason': 'r', 'evidence': 'e'},
            {'op': 'write', 'path': 'global/a.md', 'staged': self.stage('a2.md', 'a2'), 'reason': 'r', 'evidence': 'e'},
            {'op': 'delete', 'path': 'global/a.md', 'reason': 'r', 'evidence': 'e'},
            {'op': 'write', 'path': 'contexts/s/a.md', 'staged': self.stage('c.md', 'c'), 'reason': 'r',
             'evidence': 'e'},
            {'op': 'delete', 'path': '.obsidian/app.json', 'reason': 'r', 'evidence': 'e'},
            {'op': 'write', 'path': 'global/x.md', 'staged': '../escape.md', 'reason': 'r', 'evidence': 'e'})
        self.assertEqual(len(bad), 1)
        accepted, skipped = ka.validate(self.vault, ops, expected, {})
        problems = {s['subject']: s['problem'] for s in skipped}
        self.assertIn('мержа', problems['global/task.md'])
        self.assertIn('существует', problems['global/b.md'])
        self.assertIn('нескольких', problems['global/a.md'])
        self.assertIn('неоднозначным', problems['contexts/s/a.md'])
        self.assertIn('защищённый', problems['.obsidian/app.json'])
        self.assertEqual(accepted, [])
        accepted, _ = ka.validate(self.vault, [ops[0]], expected, {'global/task.md': {'status': 'merged'}})
        self.assertEqual(accepted, [])
        accepted, _ = ka.validate(self.vault, [ops[0]], expected,
                                  {'global/task.md': {'status': 'merged', 'sha': 'abc123'}})
        self.assertEqual(len(accepted), 1)

    def test_model_cannot_invent_layers_or_write_legacy(self):
        self.write('projects/-old/memory/n.md', 'n')
        expected = self.expected()
        ops, _ = self.decide(
            {'op': 'move', 'path': 'global/b.md', 'to': 'machine/other-pc/', 'reason': 'r', 'evidence': 'e'},
            {'op': 'write', 'path': 'projects/-old/memory/n.md', 'staged': self.stage('n.md', 'x'), 'reason': 'r',
             'evidence': 'e'},
            {'op': 'move', 'path': 'global/a.md', 'to': 'contexts/missing/projects/new/', 'reason': 'r',
             'evidence': 'e'})
        accepted, skipped = ka.validate(self.vault, ops, expected, {})
        self.assertEqual(accepted, [])
        self.assertEqual(len(skipped), 3)
        (self.vault / 'contexts/s').mkdir(parents=True)
        ops, _ = self.decide({'op': 'move', 'path': 'global/a.md', 'to': 'contexts/s/projects/new/', 'reason': 'r',
                              'evidence': 'e'})
        self.assertEqual(len(ka.validate(self.vault, ops, self.expected(), {})[0]), 1)

    def test_decisions_need_reason_and_evidence(self):
        ops, bad = self.decide({'op': 'delete', 'path': 'global/a.md', 'reason': 'r', 'evidence': ' '},
                               {'op': 'delete', 'path': 'global/b.md'})
        self.assertEqual(ops, [])
        self.assertEqual(len(bad), 2)

    def test_open_task_can_only_be_shortened(self):
        self.note('global/task.md', 'task', 'open task', extra='  status: active\n  link: branch:x\n')
        task = self.vault / 'global/task.md'
        task.write_text(task.read_text().replace('type: project', 'type: task'))
        expected = self.expected()
        wipe, _ = self.decide({'op': 'write', 'path': 'global/task.md', 'staged': self.stage('t1.md', 'gone\n'),
                               'reason': 'r', 'evidence': 'e'})
        merge, _ = self.decide({'op': 'merge', 'sources': ['global/a.md'], 'target': 'global/task.md',
                                'staged': self.stage('t2.md', 'merged\n'), 'reason': 'r', 'evidence': 'e'})
        short = ('---\nname: task\ndescription: open task\nmetadata:\n  type: task\n  status: active\n'
                 '  link: branch:x\n---\nshort\n')
        keep, _ = self.decide({'op': 'write', 'path': 'global/task.md', 'staged': self.stage('t3.md', short),
                               'reason': 'r', 'evidence': 'e'})
        self.assertEqual(ka.validate(self.vault, wipe, expected, {})[0], [])
        self.assertEqual(ka.validate(self.vault, merge, expected, {})[0], [])
        self.assertEqual(len(ka.validate(self.vault, keep, expected, {})[0]), 1)

    def test_two_new_notes_with_one_name_are_refused(self):
        ops, _ = self.decide(
            {'op': 'write', 'path': 'global/x.md', 'staged': self.stage('x1.md', 'x'), 'reason': 'r', 'evidence': 'e'},
            {'op': 'write', 'path': 'machine/pc/x.md', 'staged': self.stage('x2.md', 'x'), 'reason': 'r',
             'evidence': 'e'})
        accepted, skipped = ka.validate(self.vault, ops, self.expected(), {})
        self.assertEqual(accepted, [])
        self.assertTrue(all('неоднозначным' in s['problem'] for s in skipped))

    def test_change_between_validation_and_application_is_skipped(self):
        ops, _ = self.decide(
            {'op': 'write', 'path': 'global/a.md', 'staged': self.stage('a.md', 'new a\n'), 'reason': 'r',
             'evidence': 'e'},
            {'op': 'delete', 'path': 'global/b.md', 'reason': 'r', 'evidence': 'e'})
        original = kv.write_file

        def write_and_touch(vault, rel, data):
            original(vault, rel, data)
            if rel == 'global/a.md':
                original(vault, 'global/b.md', b'edited by a session\n')

        with mock.patch.object(ka.kv, 'write_file', side_effect=write_and_touch):
            records, skipped = ka.run_ops(self.history, self.vault, self.journal, ops, self.expected(), {})
        self.assertEqual([r['subject'] for r in records], ['global/a.md'])
        self.assertIn('изменён во время прогона', skipped[0]['problem'])
        self.assertEqual((self.vault / 'global/b.md').read_text(), 'edited by a session\n')

    def test_merge_redirects_links_to_the_target(self):
        self.write('global/c.md', '---\nname: c\ndescription: c\n---\nsee [[b]] and [b](b.md)\n')
        ops, _ = self.decide({'op': 'merge', 'sources': ['global/b.md'], 'target': 'global/a.md',
                              'staged': self.stage('a.md', '---\nname: a\ndescription: note a\n---\na and b\n'),
                              'reason': 'r', 'evidence': 'e'})
        self.apply(ops)
        text = (self.vault / 'global/c.md').read_text()
        self.assertIn('[[a]]', text)
        self.assertIn('[b](a.md)', text)
        self.assertNotIn('[[b]]', (self.vault / 'global/INDEX.md').read_text())

    def test_single_undo_of_a_move_restores_inbound_links(self):
        self.write('global/c.md', '---\nname: c\ndescription: c\n---\nsee [b](b.md)\n')
        ops, _ = self.decide({'op': 'move', 'path': 'global/b.md', 'to': 'machine/pc/', 'reason': 'r',
                              'evidence': 'e'})
        records, _ = self.apply(ops)
        self.assertIn('[b](../machine/pc/b.md)', (self.vault / 'global/c.md').read_text())
        move = next(r for r in records if r['kind'] == 'move')
        self.assertEqual(ka.undo(self.history, self.vault, self.journal.path, move['id']), [(move['id'], 'undone')])
        self.assertIn('[b](b.md)', (self.vault / 'global/c.md').read_text())
        self.assertIn('[[b]]', (self.vault / 'global/INDEX.md').read_text())

    def test_interrupted_undo_is_recovered(self):
        ops, _ = self.decide({'op': 'move', 'path': 'global/b.md', 'to': 'machine/pc/', 'reason': 'r',
                              'evidence': 'e'})
        records, _ = ka.run_ops(self.history, self.vault, self.journal, ops, self.expected(), {})
        with mock.patch.object(ka.kv, 'remove_file', side_effect=OSError('killed')):
            with self.assertRaises(OSError):
                ka.undo(self.history, self.vault, self.journal.path, records[0]['id'])
        logs = list(self.run_dir.glob('undo-*.journal.json'))
        ka.recover(self.history, self.vault, logs[0])
        self.assertTrue((self.vault / 'machine/pc/b.md').exists())
        self.assertFalse((self.vault / 'global/b.md').exists())
        self.assertEqual(ka.undo(self.history, self.vault, self.journal.path, records[0]['id']),
                         [(records[0]['id'], 'undone')])
        self.assertTrue((self.vault / 'global/b.md').exists())

    def test_recovery_finishes_pending_link_repairs(self):
        self.write('global/c.md', '---\nname: c\ndescription: c\n---\nsee [b](b.md)\n')
        ops, _ = self.decide({'op': 'move', 'path': 'global/b.md', 'to': 'machine/pc/', 'reason': 'r',
                              'evidence': 'e'})
        records, _ = ka.run_ops(self.history, self.vault, self.journal, ops, self.expected(), {})
        links, merged = ka.collect_links(records)
        self.journal.data['pending'] = dict(layers=['global'], links=links, merged=sorted(merged))
        self.journal.save()
        ka.recover(self.history, self.vault, self.journal.path)
        self.assertIn('[b](../machine/pc/b.md)', (self.vault / 'global/c.md').read_text())
        self.assertIn('[[b]]', (self.vault / 'machine/pc/MEMORY.md').read_text())

    def test_index_symlink_outside_the_vault_is_never_written(self):
        outside = self.vault.parent / 'elsewhere.md'
        outside.write_text('# elsewhere\n')
        (self.vault / 'machine/pc/INDEX.md').symlink_to(outside)
        self.note('machine/pc/n.md', 'n', 'n')
        records, skipped = ka.run_ops(self.history, self.vault, self.journal, ka.reindex_ops(self.vault, ['machine/pc']))
        self.assertEqual(records, [])
        self.assertEqual(outside.read_text(), '# elsewhere\n')

    def test_changed_during_run_is_skipped(self):
        expected = self.expected()
        ops, _ = self.decide({'op': 'delete', 'path': 'global/a.md', 'reason': 'r', 'evidence': 'e'})
        self.write('global/a.md', 'edited by a session\n')
        records, skipped = ka.run_ops(self.history, self.vault, self.journal, ops, expected, {})
        self.assertEqual(records, [])
        self.assertIn('изменён во время прогона', skipped[0]['problem'])
        self.assertTrue((self.vault / 'global/a.md').exists())

    def test_recover_rolls_back_interrupted_operation(self):
        expected = self.expected()
        ops, _ = self.decide({'op': 'merge', 'sources': ['global/b.md'], 'target': 'global/a.md',
                              'staged': self.stage('a.md', 'merged a and b\n'), 'reason': 'r', 'evidence': 'e'})
        with mock.patch.object(ka.kv, 'remove_file', side_effect=OSError('disk gone')):
            with self.assertRaises(OSError):
                ka.run_ops(self.history, self.vault, self.journal, ops, expected, {})
        self.assertEqual((self.vault / 'global/a.md').read_text(), 'merged a and b\n')
        recovered = ka.recover(self.history, self.vault, self.journal.path)
        self.assertEqual(recovered.data['ops'][0]['state'], 'rolled-back')
        self.assertEqual(recovered.data['state'], 'recovered')
        self.assertIn('body of a', (self.vault / 'global/a.md').read_text())
        self.assertTrue((self.vault / 'global/b.md').exists())
        self.assertIsNone(ka.recover(self.history, self.vault, self.journal.path))

    def test_undo_conflict_leaves_operation(self):
        ops, _ = self.decide({'op': 'delete', 'path': 'global/b.md', 'reason': 'r', 'evidence': 'e'})
        records, _ = ka.run_ops(self.history, self.vault, self.journal, ops, self.expected(), {})
        self.write('global/b.md', 'recreated by a session\n')
        op_id = records[0]['id']
        self.assertEqual(ka.undo(self.history, self.vault, self.journal.path, op_id), [(op_id, 'conflict')])
        self.assertEqual((self.vault / 'global/b.md').read_text(), 'recreated by a session\n')
        with self.assertRaises(ValueError):
            ka.undo(self.history, self.vault, self.journal.path, 99)

    def test_move_relinks_note_and_references(self):
        self.note('contexts/s/projects/p/x.md', 'x', 'x')
        self.write('contexts/s/projects/p/y.md', '---\nname: y\ndescription: y\n---\nsee [x](x.md)\n')
        self.write('global/c.md', '---\nname: c\ndescription: c\n---\nsee [y](../contexts/s/projects/p/y.md)\n')
        ops, _ = self.decide({'op': 'move', 'path': 'contexts/s/projects/p/y.md', 'to': 'contexts/s/',
                              'reason': 'r', 'evidence': 'e'})
        self.apply(ops)
        self.assertIn('[x](projects/p/x.md)', (self.vault / 'contexts/s/y.md').read_text())
        self.assertIn('[y](../contexts/s/y.md)', (self.vault / 'global/c.md').read_text())

    def test_rmdir_keeps_a_directory_whose_lock_is_held(self):
        busy = self.vault / 'repositories/busy-1'
        busy.mkdir(parents=True)
        (busy / '.memory-init.lock').write_text('')
        with (busy / '.memory-init.lock').open('a') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            ka.run_ops(self.history, self.vault, self.journal,
                       [ka.op('rmdir', 'script', dirs=['repositories/busy-1'], subject='repositories/busy-1')])
        self.assertTrue(busy.exists())

    def test_rmdir_removes_control_files_and_locks(self):
        legacy = self.vault / 'repositories/old-1'
        legacy.mkdir(parents=True)
        (legacy / '.checkouts.json').write_text('{}')
        (legacy / '.memory-init.lock').write_text('')
        entry = ka.op('rmdir', 'script', removes=['repositories/old-1/.checkouts.json'],
                      dirs=['repositories/old-1'], reason='пустая папка', subject='repositories/old-1')
        records, skipped = ka.run_ops(self.history, self.vault, self.journal, [entry])
        self.assertEqual(skipped, [])
        self.assertFalse(legacy.exists())
        ka.undo(self.history, self.vault, self.journal.path, records[0]['id'])
        self.assertEqual((legacy / '.checkouts.json').read_text(), '{}')

    def test_dependency_on_a_concurrently_touched_path_is_refused(self):
        self.write('global/a copy.md', 'dup\n')
        expected = self.expected()
        ops = [ka.op('dedupe', 'script', removes=['global/a copy.md'], deps=['global/a.md']),
               ka.op('delete', 'script', removes=['global/a.md'])]
        accepted, skipped = ka.validate(self.vault, ops, expected, {})
        problems = {s['subject']: s['problem'] for s in skipped}
        self.assertIn('нескольких', problems['global/a copy.md'])
        self.assertEqual([entry['subject'] for entry in accepted], ['global/a.md'])

    def test_relink_guards_against_an_edit_between_build_and_apply(self):
        self.write('global/c.md', '---\nname: c\ndescription: c\n---\nsee [b](b.md)\n')
        ops, _ = self.decide({'op': 'move', 'path': 'global/b.md', 'to': 'machine/pc/', 'reason': 'r',
                              'evidence': 'e'})
        ka.run_ops(self.history, self.vault, self.journal, ops, self.expected(), {})
        fixups = ka.relink_ops(self.vault, {'global/b.md': 'machine/pc/b.md'})
        c = self.vault / 'global/c.md'
        c.write_text(c.read_text() + 'extra line\n')
        records, skipped = ka.run_ops(self.history, self.vault, self.journal, fixups)
        self.assertEqual(records, [])
        self.assertIn('изменён во время прогона', skipped[0]['problem'])
        self.assertIn('extra line', c.read_text())
        self.assertIn('[b](b.md)', c.read_text())

    def test_fixup_retry_absorbs_a_single_concurrent_edit(self):
        self.write('global/c.md', '---\nname: c\ndescription: c\n---\nsee [b](b.md)\n')
        ops, _ = self.decide({'op': 'move', 'path': 'global/b.md', 'to': 'machine/pc/', 'reason': 'r',
                              'evidence': 'e'})
        records, _ = ka.run_ops(self.history, self.vault, self.journal, ops, self.expected(), {})
        links, merged = ka.collect_links(records)
        original = ka.relink_ops
        injected = []

        def wrapped(vault, links):
            result = original(vault, links)
            if not injected:
                injected.append(True)
                c = self.vault / 'global/c.md'
                c.write_text(c.read_text() + 'extra line\n')
            return result

        with mock.patch.object(ka, 'relink_ops', side_effect=wrapped):
            fixed, skipped = ka.run_fixups(self.history, self.vault, self.journal,
                                           ka.layers_of(p for r in records for p in r['paths']), links, merged)
        self.assertEqual(skipped, [])
        text = (self.vault / 'global/c.md').read_text()
        self.assertIn('[b](../machine/pc/b.md)', text)
        self.assertIn('extra line', text)

    def test_fixup_retries_exhausted_leave_a_skip(self):
        self.write('global/c.md', '---\nname: c\ndescription: c\n---\nsee [b](b.md)\n')
        ops, _ = self.decide({'op': 'move', 'path': 'global/b.md', 'to': 'machine/pc/', 'reason': 'r',
                              'evidence': 'e'})
        records, _ = ka.run_ops(self.history, self.vault, self.journal, ops, self.expected(), {})
        links, merged = ka.collect_links(records)
        original = ka.relink_ops

        def wrapped(vault, links):
            result = original(vault, links)
            c = self.vault / 'global/c.md'
            c.write_text(c.read_text() + 'extra line\n')
            return result

        with mock.patch.object(ka, 'relink_ops', side_effect=wrapped):
            fixed, skipped = ka.run_fixups(self.history, self.vault, self.journal,
                                           ka.layers_of(p for r in records for p in r['paths']), links, merged)
        self.assertTrue(skipped)

    def test_settle_runs_fixups_for_operations_done_before_an_interruption(self):
        self.write('global/c.md', '---\nname: c\ndescription: c\n---\nsee [b](b.md)\n')
        ops, _ = self.decide(
            {'op': 'move', 'path': 'global/b.md', 'to': 'machine/pc/', 'reason': 'r', 'evidence': 'e'},
            {'op': 'write', 'path': 'global/a.md', 'staged': self.stage('a.md', 'new a\n'), 'reason': 'r',
             'evidence': 'e'})
        expected = self.expected()
        original = kv.write_file

        def fail_on_a(vault, rel, data):
            if rel == 'global/a.md':
                raise OSError('disk gone')
            original(vault, rel, data)

        with mock.patch.object(ka.kv, 'write_file', side_effect=fail_on_a):
            with self.assertRaises(OSError):
                ka.run_ops(self.history, self.vault, self.journal, ops, expected, {})
        ka.recover(self.history, self.vault, self.journal.path)
        self.assertIn('[b](../machine/pc/b.md)', (self.vault / 'global/c.md').read_text())
        self.assertNotIn('[[b]]', (self.vault / 'global/INDEX.md').read_text())
        self.assertIn('- [[b]]: note b', (self.vault / 'machine/pc/MEMORY.md').read_text())

    def test_recovery_after_an_interrupted_undo_fixup_restores_links(self):
        self.write('global/c.md', '---\nname: c\ndescription: c\n---\nsee [b](b.md)\n')
        ops, _ = self.decide({'op': 'move', 'path': 'global/b.md', 'to': 'machine/pc/', 'reason': 'r',
                              'evidence': 'e'})
        records, _ = self.apply(ops)
        move = next(r for r in records if r['kind'] == 'move')
        self.assertIn('[b](../machine/pc/b.md)', (self.vault / 'global/c.md').read_text())
        with mock.patch.object(ka, 'run_fixups', side_effect=OSError('killed')):
            with self.assertRaises(OSError):
                ka.undo(self.history, self.vault, self.journal.path, move['id'])
        logs = sorted(self.run_dir.glob('undo-*.journal.json'))
        ka.recover(self.history, self.vault, logs[-1])
        self.assertIn('[b](b.md)', (self.vault / 'global/c.md').read_text())


if __name__ == '__main__':
    unittest.main()
