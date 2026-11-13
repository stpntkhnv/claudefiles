---
name: kb-curate
description: Use when the knowledge base needs a pass - duplicate notes, stale facts, task notes whose work has landed, an index past its budget, notes in the wrong layer, sync conflict files, or before relying on the base after a long gap. Also the instruction set of the weekly background review.
---

# Curating the knowledge base

The vault path is in the `kb` rule of this profile (`rules/kb.md`). Layers inside it:

- `global/` — the user's preferences and working rules that apply everywhere. `global/INDEX.md` is
  loaded in every session and stays under 50 lines.
- `machine/<name>/` — facts about one computer; its index is shown in every session on that computer.
- `contexts/<context>/` — one work area. `contexts/<context>/projects/<folder>/` — a folder without Git
  under `~/main`, or a project bound in `repositories.json`.
- `repositories/<name>-<hash>/` — memory of one Git repository.
- `projects/<slug>/memory/` — legacy path-based memory. Everything in it moves to its new home or goes.

A layer's index is `MEMORY.md` (`INDEX.md` where there is no `MEMORY.md`; `global/INDEX.md` for global).
Index format: one line per note, `- [[name]]: what the note is about`.

## What stays

A note stays only if it changes a decision today: a preference or feedback rule, a live how-to, a live
access fact, a constraint that still holds, an open task. Everything else goes:

- logs of work that has landed: `type: task` notes with a confirmed merge, and untyped "progress",
  "state", "RESUME HERE" notes whose pull request is merged or abandoned;
- one-off incidents and meeting notes that left no lasting rule;
- facts the repository or a skill now states itself;
- descriptions of environments, paths and tools that no longer exist (check before deleting);
- duplicates: fold them into one note, keep the newer wording and the links of both.

Rewrite a kept note to its current state: drop "Update <date>" blocks and "outdated" banners, keep it
under 10 KB, make the description and the index line match the body. Put each note in the narrowest
layer that covers every place it is needed: repository, project, context, machine, global.

## Verify, never guess

Every deletion and every "this is no longer true" needs evidence: a merge commit, a path that does not
exist, a newer note that overrides it, a file in the repository that states the same. Read the
repository or the machine; never decide from the note alone. When evidence is missing, keep the note
and ask.

## Manual run

Curate the area the user asked about and nothing else. First present the proposal: what would be
merged, deleted, moved or rewritten, and the evidence for each. Wait for approval, apply exactly what
was approved, and report what changed on disk.

## Automatic run

The run directory holds `worklist.json`: content hashes of every note, the notes selected for this
run, task statuses checked against Git (`merged` with the merge commit, `branch-merged`,
`unconfirmed`, `declared-done`, `declared-dropped`), legacy folders with their new homes, oversize
notes, indexes over their caps, untyped notes, dead paths, unequal sync conflicts, curated folders
that duplicate a repository memory, layers with two indexes.

- You cannot change the vault. Write every new or rewritten file into `staging/` of the run directory
  and return decisions:
  - `write`: `path` in the vault and `staged` (the staged file with the full new content);
  - `merge`: `sources` folded into `target`, and `staged` with the full new content of the target;
  - `move`: `path` and `to` (a directory ending in `/`, or a full path); the script fixes links and
    index lines;
  - `delete`: `path`.
- Every decision has `reason` (one short sentence in Russian) and `evidence` (what you checked).
- A `type: task` note can be deleted or merged away only when its worklist status is `merged` or its
  own status is `done` or `dropped`. Move what stays useful out of it first with a `write` or `merge`.
- Legacy folders: move or merge every note into the folder's home. For a folder without a home,
  propose a home from the content, or delete stale notes on the usual evidence. Never delete a note
  only because its folder is gone.
- Indexes over their cap: move notes to narrower layers first, then shorten lines.
- Never touch `reviews/`, files and folders starting with a dot, `.obsidian/`, `*.kdbx`.
- Anything that needs the user goes into `questions`: the path and a short question in Russian.
