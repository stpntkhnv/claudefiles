---
name: kb-curate
description: Use when the knowledge base needs a pass - duplicate notes, stale facts, an index that grew past its budget, sync conflict files, or before relying on the base after a long gap.
---

# Curating the knowledge base

The base is two areas of one vault. The path is in the `kb` rule of this profile
(`rules/kb.md`); read it first, everything below is relative to that vault.

- `projects/<slug>/memory/` — one folder per repository, written by auto memory.
- `global/` — cross-project notes plus `global/INDEX.md`.

Curate ONE area per run, the one the user asked about. Never both silently.

The vault is the user's, and every change here is a deletion or a rewrite of something they may
never have read. So this skill runs in two passes: first REPORT what you would change and why, then
apply only what the user approves. Never delete or rewrite a note before that approval, and never
widen the run to notes the user did not ask about.

## Steps

1. Read the index of the area (`MEMORY.md` for a project, `global/INDEX.md` for the shared area)
   and every note it lists.
2. **Conflicts.** Delete `*.sync-conflict-*.md` and `*.conflicted copy*.md` after folding anything
   they hold that the surviving note does not.
3. **Duplicates.** Two notes stating the same fact become one. Keep the newer wording, keep both
   sets of `[[links]]`, delete the loser, fix every line that pointed at it.
4. **Stale facts.** A note whose claim no longer matches reality (a file that moved, a flag that
   was renamed, a machine that was rebuilt) is corrected or deleted. Verify before deleting: check
   the repository or the machine, do not guess from the note alone.
5. **Secrets.** Grep the area for tokens, keys and credentials (`ghp_`, `sk-`, `-----BEGIN`,
   `password`, `api_key`). Anything found is removed from the note and reported to the user, since
   the vault may be synced.
6. **Index format.** Every line is exactly `- [[name]]: what the note is about`. Lines that carry
   instructions, multi-line blocks, or entries for notes that no longer exist are rewritten or
   dropped. `global/INDEX.md` stays under 50 lines, `MEMORY.md` under 200 lines and 25 KB.
7. Present the whole set as a proposal: for each note, what would be merged, deleted or rewritten,
   and on what evidence. Wait for the user. Then apply exactly what they approved and report a
   diff-shaped summary. Do not present it as done until the files on disk match the report.
