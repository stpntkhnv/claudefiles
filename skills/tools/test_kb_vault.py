#!/usr/bin/env python3
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'lib/py'))
import kb_vault as kv


class VaultTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.vault = Path(self.temp.name).resolve() / 'kb'
        self.vault.mkdir()

    def write(self, rel, text):
        path = self.vault / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def note(self, rel, name, description, kind='project'):
        return self.write(rel, f'---\nname: {name}\ndescription: {description}\nmetadata:\n  type: {kind}\n---\n\nbody of {name}\n')

    def test_frontmatter(self):
        text = ('---\nname: a\ndescription: "quoted"\naliases:\n  - old-a\n  - older-a\nmetadata:\n'
                '  type: task\n  status: active\n  link: branch:feature/x\n---\nbody\n')
        data = kv.frontmatter(text)
        self.assertEqual(data['description'], 'quoted')
        self.assertEqual(data['aliases'], ['old-a', 'older-a'])
        self.assertEqual(kv.meta(text), {'type': 'task', 'status': 'active', 'link': 'branch:feature/x'})
        self.assertEqual(kv.note_type(text), 'task')
        self.assertEqual(kv.body(text), 'body\n')
        self.assertEqual(kv.frontmatter('no frontmatter'), {})
        self.assertEqual(kv.description('# Title\n\ntext', 'x'), 'Title')
        self.assertEqual(kv.description('---\nname: n\n---\n\nfirst line\n', 'x'), 'first line')

    def test_layers(self):
        cases = {'global/a.md': 'global', 'machine/pc/a.md': 'machine/pc',
                 'repositories/r-1/a.md': 'repositories/r-1', 'repositories/r-1/sub/a.md': 'repositories/r-1',
                 'contexts/s/a.md': 'contexts/s', 'contexts/s/pats/a.md': 'contexts/s',
                 'contexts/s/projects/p/a.md': 'contexts/s/projects/p',
                 'projects/-x/memory/a.md': 'projects/-x/memory', 'README.md': None}
        for rel, layer in cases.items():
            self.assertEqual(kv.layer_of(rel), layer, rel)

    def test_protected(self):
        for rel in ('.obsidian/a.md', 'personal.kdbx', 'a/.memory-init.lock', 'reviews/1.md', '../x.md',
                    '/abs.md', 'repositories/r/.checkouts.json'):
            self.assertTrue(kv.protected(rel), rel)
        self.assertFalse(kv.protected('reviews/1.md', script=True))
        self.assertFalse(kv.protected('repositories/r/.checkouts.json', script=True))
        self.assertTrue(kv.protected('.obsidian/x.md', script=True))
        self.assertFalse(kv.protected('global/a.md'))
        self.assertTrue(kv.excluded('x/.stversions/a.md'))

    def test_layer_notes_skip_sublayers_and_indexes(self):
        self.note('contexts/s/a.md', 'a', 'a')
        self.note('contexts/s/pats/b.md', 'b', 'b')
        self.note('contexts/s/projects/p/c.md', 'c', 'c')
        self.write('contexts/s/MEMORY.md', '# s\n')
        self.assertEqual(kv.layer_notes(self.vault, 'contexts/s'), ['contexts/s/a.md', 'contexts/s/pats/b.md'])
        self.assertEqual(kv.layers(self.vault), ['contexts/s', 'contexts/s/projects/p'])
        self.assertEqual(sorted(kv.all_notes(self.vault)),
                         ['contexts/s/a.md', 'contexts/s/pats/b.md', 'contexts/s/projects/p/c.md'])

    def test_index_path_prefers_memory(self):
        self.write('contexts/s/INDEX.md', 'old')
        self.assertEqual(kv.index_path(self.vault, 'contexts/s').name, 'INDEX.md')
        self.write('contexts/s/MEMORY.md', 'new')
        self.assertEqual(kv.index_path(self.vault, 'contexts/s').name, 'MEMORY.md')
        self.assertEqual(kv.index_path(self.vault, 'global'), self.vault / 'global/INDEX.md')

    def test_reindex_drops_keeps_and_adds(self):
        self.note('global/kept.md', 'kept', 'kept note')
        self.note('global/new.md', 'new', 'new note')
        self.note('contexts/s/projects/p/target.md', 'target', 'target')
        self.write('global/INDEX.md', '# Global\n\nprose stays\n- [[kept]]: kept note\n- [[gone]]: missing\n'
                                      '- [[target]]: other layer\n')
        text = kv.reindex(self.vault, 'global')
        self.assertIn('prose stays', text)
        self.assertIn('- [[kept]]: kept note', text)
        self.assertNotIn('gone', text)
        self.assertIn('- [[target]]: other layer', text)
        self.assertIn('- [[new]]: new note', text)
        self.write('global/INDEX.md', text)
        self.assertIsNone(kv.reindex(self.vault, 'global'))

    def test_reindex_repairs_relative_links(self):
        self.write('contexts/p/projects/c/INDEX.md', '# c\n')
        self.note('repositories/c-1/a.md', 'a', 'a note')
        self.note('global/moved.md', 'moved', 'moved note')
        self.write('repositories/c-1/MEMORY.md', '# c\n- [canon](../../../contexts/p/projects/c/INDEX.md): curated\n'
                                                 '- [A](a.md): a note\n- [Gone](gone.md): gone\n'
                                                 '- [Moved](old/moved.md): moved note\n')
        text = kv.reindex(self.vault, 'repositories/c-1')
        self.assertIn('](../../contexts/p/projects/c/INDEX.md)', text)
        self.assertIn('- [A](a.md): a note', text)
        self.assertIn('- [[moved]]: moved note', text)
        self.assertNotIn('gone.md', text)

    def test_reindex_syncs_descriptions_of_own_notes(self):
        self.note('global/a.md', 'a', 'new wording')
        self.note('machine/pc/b.md', 'b', 'machine wording')
        self.write('global/INDEX.md', '- [[a]]: old wording\n- [[b]]: kept as written\n')
        text = kv.reindex(self.vault, 'global')
        self.assertIn('- [[a]]: new wording', text)
        self.assertIn('- [[b]]: kept as written', text)

    def test_rename_wiki(self):
        self.assertEqual(kv.rename_wiki('see [[old]], [[old|alias]], [[old#part]], [[other]]', {'old': 'new'}),
                         'see [[new]], [[new|alias]], [[new#part]], [[other]]')

    def test_symlinks_cannot_escape_or_reach_protected_areas(self):
        outside = self.vault.parent / 'outside.md'
        outside.write_text('outside\n')
        (self.vault / 'global').mkdir()
        (self.vault / 'global/INDEX.md').symlink_to(outside)
        with self.assertRaises(ValueError):
            kv.write_file(self.vault, 'global/INDEX.md', b'x')
        self.assertEqual(outside.read_text(), 'outside\n')
        (self.vault / '.obsidian').mkdir()
        (self.vault / '.obsidian/app.json').write_text('{}')
        (self.vault / 'global/link.md').symlink_to(self.vault / '.obsidian/app.json')
        with self.assertRaises(ValueError):
            kv.target(self.vault, 'global/link.md')
        self.assertEqual(kv.canonical(self.vault, 'global/missing.md'), 'global/missing.md')

    def test_reindex_creates_missing_index(self):
        self.note('machine/pc/sound.md', 'sound', 'sound card')
        self.assertEqual(kv.reindex(self.vault, 'machine/pc'), '# machine/pc\n\n- [[sound]]: sound card\n')

    def test_conflict_names(self):
        self.assertTrue(kv.CONFLICT.search('MEMORY.sync-conflict-20261001-101010-ABCDEF7.md'))
        self.assertEqual(kv.CONFLICT.sub('', 'note.sync-conflict-20261001-101010-ABCDEF7.md'), 'note.md')
        self.assertEqual(kv.CONFLICT.sub('', 'note (conflicted copy 2026-10-01).md'), 'note.md')
        self.assertIsNone(kv.CONFLICT.search('note.md'))

    def test_dead_paths(self):
        home = self.vault.parent
        (home / 'exists').mkdir()
        self.write('global/a.md', 'see ~/exists and ~/missing/dir, also /home/nobody-here/x.\n')
        self.assertEqual(kv.dead_paths(self.vault, 'global/a.md', home), ['~/missing/dir', '/home/nobody-here/x'])

    def test_write_file_follows_symlink_and_keeps_mode(self):
        memory = self.write('contexts/s/MEMORY.md', 'one\n')
        memory.chmod(0o640)
        (self.vault / 'contexts/s/INDEX.md').symlink_to('MEMORY.md')
        kv.write_file(self.vault, 'contexts/s/INDEX.md', b'two\n')
        self.assertTrue((self.vault / 'contexts/s/INDEX.md').is_symlink())
        self.assertEqual(memory.read_text(), 'two\n')
        self.assertEqual(memory.stat().st_mode & 0o777, 0o640)
        kv.write_file(self.vault, 'global/new.md', b'x')
        self.assertEqual((self.vault / 'global/new.md').read_bytes(), b'x')
        kv.remove_file(self.vault, 'global/new.md')
        self.assertFalse((self.vault / 'global/new.md').exists())
        with self.assertRaises(ValueError):
            kv.write_file(self.vault, '../outside.md', b'x')


if __name__ == '__main__':
    unittest.main()
