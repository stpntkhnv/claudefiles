#!/usr/bin/env python3
import contextlib
import io
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
import kb_homes
import kb_review as kr

FAKE = '''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
Path(os.environ['CLAUDE_FAKE_ARGS']).write_text(json.dumps(sys.argv[1:] + ['STDIN:' + sys.stdin.read()[:40]]))
if os.environ.get('CLAUDE_FAKE_STAGING'):
    shutil.copytree(os.environ['CLAUDE_FAKE_STAGING'], 'staging', dirs_exist_ok=True)
if os.environ.get('CLAUDE_FAKE_TOUCH'):
    with open(os.environ['CLAUDE_FAKE_TOUCH'], 'a') as handle:
        handle.write('session edit\\n')
sys.stdout.write(Path(os.environ['CLAUDE_FAKE_ENVELOPE']).read_text())
sys.exit(int(os.environ.get('CLAUDE_FAKE_EXIT', '0')))
'''

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
        self.systemd_log = self.base / 'systemctl.log'
        bin_dir = self.home / '.local/bin'
        bin_dir.mkdir(parents=True, exist_ok=True)
        fake_systemctl = bin_dir / 'systemctl'
        fake_systemctl.write_text('#!/usr/bin/env python3\nimport sys\n'
                                  f'with open({str(self.systemd_log)!r}, "a") as f:\n'
                                  '    f.write(" ".join(sys.argv[1:]) + "\\n")\n')
        fake_systemctl.chmod(0o755)
        patch = mock.patch.dict(os.environ, {
            'HOME': str(self.home), 'CLAUDEFILES_KB_STATE': str(self.state),
            'CLAUDEFILES_KB_BOX_HOMES': str(self.home / 'homes'),
            'CLAUDEFILES_CONFIG_DIR': str(self.home / '.config/claudefiles'), 'CLAUDEFILES_CONTAINER': '0',
            'XDG_CONFIG_HOME': str(self.home / '.config'),
            'PATH': str(bin_dir) + os.pathsep + os.environ['PATH']})
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

    def quiet(self, func, *args, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            return func(*args, **kwargs)


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

    def test_undo_restores_a_deleted_duplicate(self):
        orbi = self.box / 'main/orbi'
        orbi.mkdir()
        self.write('contexts/stellium/projects/orbi/same.md', 'same\n')
        copy = self.write(f'projects/{kr.slug(orbi)}/memory/same.md', 'same\n')
        history = kh.History(self.state, self.vault).init()
        history.snapshot('base')
        journal = ka.Journal(self.state / 'runs/r/journal.json', 'r')
        journal.save()
        _, _, records, _ = kr.autofix(history, self.vault, journal, kr.environments())
        self.assertFalse(copy.exists())
        delete = next(r for r in records if r['kind'] == 'delete')
        results = dict(ka.undo(history, self.vault, journal.path))
        self.assertEqual(results[delete['id']], 'undone')
        self.assertNotIn('conflict', results.values())
        self.assertEqual(copy.read_text(), 'same\n')

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

    def test_worklist_lists_index_mismatches_and_conflict_copies(self):
        self.note('global/a.md', 'a', 'current wording')
        self.note('contexts/stellium/b.md', 'b', 'b now')
        self.write('global/INDEX.md', '# g\n- [[a]]: older wording\n')
        self.write('contexts/stellium/MEMORY.md', '- [[b]]: b then\n')
        conflict = 'global/a.sync-conflict-20261001-101010-ABCDEF7.md'
        self.write(conflict, 'older a\n')
        _, conflicts = kr.conflict_ops(self.vault)
        work = kr.build_worklist(self.vault, 'r', [], [], conflicts, {}, False, {})
        self.assertEqual(work['index_mismatch'], [
            {'index': 'global/INDEX.md', 'note': 'global/a.md', 'line': '- [[a]]: older wording',
             'description': 'current wording'},
            {'index': 'contexts/stellium/MEMORY.md', 'note': 'contexts/stellium/b.md', 'line': '- [[b]]: b then',
             'description': 'b now'}])
        self.assertIn(conflict, work['hashes'])
        self.assertNotIn(conflict, work['selection'])

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


class FullRun(ReviewBase):
    def setUp(self):
        super().setUp()
        bin_dir = self.home / '.local/bin'
        bin_dir.mkdir(parents=True, exist_ok=True)
        fake = bin_dir / 'claude'
        fake.write_text(FAKE)
        fake.chmod(0o755)
        self.stage = self.base / 'stage'
        self.stage.mkdir()
        self.envelope = self.base / 'envelope.json'
        self.args = self.base / 'args.json'
        patch = mock.patch.dict(os.environ, {'CLAUDE_FAKE_ENVELOPE': str(self.envelope),
                                             'CLAUDE_FAKE_STAGING': str(self.stage),
                                             'CLAUDE_FAKE_ARGS': str(self.args)})
        patch.start()
        self.addCleanup(patch.stop)
        self.note('global/a.md', 'a', 'a')
        self.note('global/host.md', 'host', 'host fact')
        self.write('global/INDEX.md', '# g\n- [[a]]: a\n- [[host]]: host fact\n')
        (self.vault / 'machine/pc').mkdir(parents=True)

    def decide(self, operations, questions=(), envelope=None):
        self.envelope.write_text(json.dumps(envelope or {
            'type': 'result', 'subtype': 'success', 'is_error': False, 'result': '',
            'structured_output': {'operations': operations, 'questions': list(questions)}}))

    def report(self):
        return next((self.vault / 'reviews').glob('*.md'))

    def test_review_applies_reports_and_undoes(self):
        (self.stage / 'a.md').write_text('---\nname: a\ndescription: a short\n---\nshort\n')
        self.decide([{'op': 'write', 'path': 'global/a.md', 'staged': 'staging/a.md', 'reason': 'ужата',
                      'evidence': 'длинная'},
                     {'op': 'move', 'path': 'global/host.md', 'to': 'machine/pc/', 'reason': 'про хост',
                      'evidence': 'только tsikhanau-pc'}],
                    [{'path': 'global/a.md', 'question': 'Оставить?'}])
        self.assertEqual(self.quiet(kr.review, self.vault, full=True), 0)
        text = self.report().read_text()
        for expected in ('status: ok', 'acknowledged: false', '- [ ] `global/a.md`: Оставить?', '## Перенесено',
                         '## Переписано', 'claudefiles-kb undo'):
            self.assertIn(expected, text)
        self.assertTrue((self.vault / 'machine/pc/host.md').exists())
        args = json.loads(self.args.read_text())
        for flag in ('--restricted', '--strict-mcp-config', '--json-schema', '--no-session-persistence'):
            self.assertIn(flag, args)
        self.assertEqual(args[args.index('--permission-mode') + 1], 'dontAsk')
        self.assertEqual(args[args.index('--output-format') + 1], 'json')
        self.assertTrue(args[-1].startswith('STDIN:# Curating the knowledge base'))
        settings = json.loads(args[args.index('--settings') + 1])
        self.assertTrue(all('staging' in rule for rule in settings['permissions']['allow']))
        add_dirs = [args[i + 1] for i, a in enumerate(args) if a == '--add-dir']
        self.assertIn(str(self.vault), add_dirs)
        self.assertGreater(len(add_dirs), 1)
        for directory in add_dirs:
            directory_rule = kr.rule(directory)
            self.assertIn(f'Edit({directory_rule})', settings['permissions']['deny'])
            self.assertIn(f'Write({directory_rule})', settings['permissions']['deny'])
        self.assertTrue((self.state / 'initialized').exists())
        self.assertEqual(self.quiet(kr.undo_run, self.vault, self.report().stem), 0)
        self.assertTrue((self.vault / 'global/host.md').exists())
        self.assertFalse((self.vault / 'machine/pc/host.md').exists())

    def test_session_edit_during_run_is_not_in_review_commit(self):
        self.decide([])
        with mock.patch.dict(os.environ, {'CLAUDE_FAKE_TOUCH': str(self.vault / 'global/side.md')}):
            self.assertEqual(self.quiet(kr.review, self.vault), 0)
        history = kh.History(self.state, self.vault)
        files = history.out('show', '--name-only', '--format=', 'HEAD').splitlines()
        self.assertNotIn('global/side.md', files)
        self.assertTrue(any(f.startswith('reviews/') for f in files))
        self.assertTrue(history.snapshot('next snapshot'))

    def test_model_failure_is_partial_and_keeps_cursor(self):
        self.decide([], envelope={'type': 'result', 'subtype': 'error_max_turns', 'is_error': True, 'result': 'limit'})
        self.assertEqual(self.quiet(kr.review, self.vault, full=True), 0)
        self.assertIn('status: partial', self.report().read_text())
        self.assertFalse((self.state / 'cursor.json').exists())
        self.assertFalse((self.state / 'initialized').exists())
        self.assertFalse(self.systemd_log.exists())

    def test_missing_structured_output_is_partial(self):
        self.decide([], envelope={'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'text'})
        self.assertEqual(self.quiet(kr.review, self.vault), 0)
        self.assertIn('status: partial', self.report().read_text())

    def test_full_ok_run_enables_timer_but_partial_does_not(self):
        unit_dir = Path(os.environ['XDG_CONFIG_HOME']) / 'systemd/user'
        unit_dir.mkdir(parents=True, exist_ok=True)
        (unit_dir / kr.TIMER).write_text(f'[Unit]\n{kr.UNIT_TAG}\n')
        (unit_dir / kr.SERVICE).write_text(f'[Unit]\n{kr.UNIT_TAG}\n')
        self.decide([])
        self.assertEqual(self.quiet(kr.review, self.vault, full=True), 0)
        self.assertEqual(self.systemd_log.read_text().strip(), f'--user enable --now {kr.TIMER}')
        self.systemd_log.unlink()
        self.decide([], envelope={'type': 'result', 'subtype': 'error_max_turns', 'is_error': True, 'result': 'limit'})
        self.assertEqual(self.quiet(kr.review, self.vault, full=True), 0)
        self.assertFalse(self.systemd_log.exists())

    def test_foreign_timer_is_not_enabled(self):
        unit_dir = Path(os.environ['XDG_CONFIG_HOME']) / 'systemd/user'
        unit_dir.mkdir(parents=True, exist_ok=True)
        (unit_dir / kr.TIMER).write_text('[Unit]\nDescription=mine\n')
        self.decide([])
        self.assertEqual(self.quiet(kr.review, self.vault, full=True), 0)
        self.assertFalse(self.systemd_log.exists())

    def test_failure_mid_operation_is_rolled_back_and_reported(self):
        (self.stage / 'a.md').write_text('---\nname: a\ndescription: a\n---\nmerged\n')
        self.decide([{'op': 'merge', 'sources': ['global/host.md'], 'target': 'global/a.md',
                      'staged': 'staging/a.md', 'reason': 'r', 'evidence': 'e'}])
        with mock.patch.object(kr.ka.kv, 'remove_file', side_effect=OSError('disk gone')):
            self.assertEqual(self.quiet(kr.review, self.vault), 1)
        self.assertIn('body of a', (self.vault / 'global/a.md').read_text())
        self.assertTrue((self.vault / 'global/host.md').exists())
        self.assertIn('status: failed', self.report().read_text())
        journal = json.loads(next(self.state.glob('runs/*/journal.json')).read_text())
        self.assertEqual(journal['state'], 'closed')
        self.assertNotIn('intent', [record['state'] for record in journal['ops']])

    def test_second_review_waits(self):
        handle = kr.lock(self.state)
        try:
            self.assertEqual(self.quiet(kr.review, self.vault), 0)
            self.assertFalse((self.vault / 'reviews').exists())
        finally:
            handle.close()

    def test_interrupted_run_is_recovered_by_snapshot(self):
        history = kh.History(self.state, self.vault).init()
        history.snapshot('base')
        before = history.store('global/a.md')
        after = history.store_bytes(b'half written\n')
        self.write('global/a.md', 'half written\n')
        run = '20261101-000000'
        journal = self.state / 'runs' / run / 'journal.json'
        journal.parent.mkdir(parents=True)
        journal.write_text(json.dumps({'run': run, 'state': 'open', 'ops': [{
            'id': 1, 'kind': 'write', 'origin': 'model', 'subject': 'global/a.md', 'dest': None, 'reason': 'r',
            'evidence': 'e', 'paths': {'global/a.md': {'before': before, 'after': after}}, 'state': 'intent',
            'at': 0}]}))
        self.assertEqual(kr.snapshot(self.vault), 0)
        self.assertIn('body of a', (self.vault / 'global/a.md').read_text())
        text = (self.vault / f'reviews/{run}.md').read_text()
        self.assertIn('status: failed', text)
        self.assertIn('откатана после обрыва прогона', text)

    def test_interrupted_run_conflict_is_reported_without_claiming_rollback(self):
        history = kh.History(self.state, self.vault).init()
        history.snapshot('base')
        before = history.store('global/a.md')
        after = history.store_bytes(b'half written\n')
        self.write('global/a.md', 'something else entirely\n')
        run = '20261102-000000'
        journal = self.state / 'runs' / run / 'journal.json'
        journal.parent.mkdir(parents=True)
        journal.write_text(json.dumps({'run': run, 'state': 'open', 'ops': [{
            'id': 1, 'kind': 'write', 'origin': 'model', 'subject': 'global/a.md', 'dest': None, 'reason': 'r',
            'evidence': 'e', 'paths': {'global/a.md': {'before': before, 'after': after}}, 'state': 'intent',
            'at': 0}]}))
        self.assertEqual(kr.snapshot(self.vault), 0)
        text = (self.vault / f'reviews/{run}.md').read_text()
        self.assertIn('status: failed', text)
        self.assertIn('не откатана после обрыва', text)
        self.assertNotIn('незавершённая операция откатана', text)
        self.assertEqual((self.vault / 'global/a.md').read_text(), 'something else entirely\n')

    def test_undo_crash_is_recovered_consistently(self):
        (self.stage / 'a.md').write_text('---\nname: a\ndescription: a short\n---\nshort\n')
        self.decide([{'op': 'write', 'path': 'global/a.md', 'staged': 'staging/a.md', 'reason': 'ужата',
                      'evidence': 'длинная'}])
        self.assertEqual(self.quiet(kr.review, self.vault, full=True), 0)
        run = self.report().stem
        real_write_file = kr.ka.kv.write_file
        calls = []

        def flaky(vault, rel, data):
            calls.append(1)
            if len(calls) == 1:
                raise OSError('disk gone')
            return real_write_file(vault, rel, data)

        with mock.patch.object(kr.ka.kv, 'write_file', side_effect=flaky):
            with self.assertRaises(OSError):
                self.quiet(kr.undo_run, self.vault, run)
        log = next(self.state.glob(f'runs/{run}/undo-*.journal.json'))
        data = json.loads(log.read_text())
        self.assertNotEqual(data['state'], 'open')
        self.assertNotIn('intent', [record['state'] for record in data['ops']])
        self.assertEqual((self.vault / 'global/a.md').read_text(), '---\nname: a\ndescription: a short\n---\nshort\n')

    def test_undo_recovers_other_interrupted_runs_first(self):
        self.decide([])
        self.assertEqual(self.quiet(kr.review, self.vault, full=True), 0)
        run = self.report().stem
        history = kh.History(self.state, self.vault).init()
        history.snapshot('base')
        before = history.store('global/a.md')
        after = history.store_bytes(b'half written\n')
        self.write('global/a.md', 'half written\n')
        stale = '20261101-000000'
        stale_journal = self.state / 'runs' / stale / 'journal.json'
        stale_journal.parent.mkdir(parents=True)
        stale_journal.write_text(json.dumps({'run': stale, 'state': 'open', 'ops': [{
            'id': 1, 'kind': 'write', 'origin': 'model', 'subject': 'global/a.md', 'dest': None, 'reason': 'r',
            'evidence': 'e', 'paths': {'global/a.md': {'before': before, 'after': after}}, 'state': 'intent',
            'at': 0}]}))
        self.assertEqual(self.quiet(kr.undo_run, self.vault, run), 0)
        self.assertEqual(json.loads(stale_journal.read_text())['state'], 'recovered')

    def test_reminder(self):
        self.assertEqual(kb_homes.review_reminder(self.vault), '')
        self.write('reviews/20261101-000000.md', '---\nacknowledged: true\n---\n- [ ] `x`: q?\n')
        self.write('reviews/20261108-000000.md', '---\nacknowledged: false\n---\n- [x] `y`: done\n')
        text = kb_homes.review_reminder(self.vault)
        self.assertIn('1 report(s) not acknowledged', text)
        self.assertIn('1 open question(s)', text)
        self.assertIn('20261101-000000.md', text)

    def test_reminder_skips_unreadable_entries(self):
        (self.vault / 'reviews/x.md').mkdir(parents=True)
        self.write('reviews/20261101-000000.md', '---\nacknowledged: false\n---\n- [ ] `x`: q?\n')
        text = kb_homes.review_reminder(self.vault)
        self.assertIn('1 report(s) not acknowledged', text)
        self.assertIn('1 open question(s)', text)

    def test_cli_requires_reviewer(self):
        self.config(self.home, {'flags': {'kb': True}, 'kb': {'vault_path': str(self.vault), 'context': 'personal',
                                                              'reviewer': False}})
        result = subprocess.run(['python3', str(ROOT / 'lib/py/repo_memory.py'), 'snapshot'],
                                env=os.environ.copy(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('kb.reviewer', result.stderr)


if __name__ == '__main__':
    unittest.main()
