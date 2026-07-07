# Statusline profile badge

## Problem

The `vanilla` (`~/.claude`, `claude`) and `super` (`~/.claude-super`, `claude-super`)
profiles differ visually only by `theme` (light vs dark). That is too subtle: when
the user forgets to launch `claude-super` and runs plain `claude` out of habit, they
do not notice for a long time. There is no explicit, always-visible signal of which
profile is active.

## Goal

Make the active profile unmistakable at a glance, from inside any session, without
per-profile duplication.

## Approach

Both profiles' `settings.json` point `statusLine.command` at the same repo file
(`lib/settings.sh:8` renders `<STATUSLINE_PATH>` to `$repo/claude/statusline/statusline.sh`).
So a single edit to that shared script fixes both profiles at once.

The reliable runtime signal is `$CLAUDE_CONFIG_DIR`, inherited by the statusline
process: the `claude-super` wrapper sets it to `~/.claude-super`; plain `claude`
leaves it unset (defaulting to `~/.claude`). The script derives the profile name from
it and renders a badge.

## Change surface

- `claude/statusline/statusline.sh` — detection + render.
- `skills/tools/test-statusline.sh` — new cases.

No changes to `settings.json`, the profile templates, or any `lib/` module.

## Detection

Read `$CLAUDE_CONFIG_DIR` and derive the profile name:

- empty/unset -> treat as `$HOME/.claude` -> `vanilla`
- basename `.claude` -> `vanilla`
- basename `.claude-<name>` -> `<name>` (covers `super` and any future profile)
- anything else -> basename as-is (fallback; must never crash)

## Render

- Prepend a bold, bracketed badge at the very left of the line, always shown.
- Neutral per-profile color: `vanilla` cyan, `super` magenta, any other profile
  yellow. Position plus brackets make it distinct regardless of color reuse
  elsewhere in the line.
- Example: `[super] Opus 4.8  claudefiles main  ctx 42% · xhigh`.

The badge is emitted as data via the existing `printf` (never as part of the format
string), consistent with the current injection-safe rendering.

## Tests

Extend `skills/tools/test-statusline.sh`, driving the profile via the env var:

- `CLAUDE_CONFIG_DIR=$HOME/.claude-super` -> output contains `[super]`
- `CLAUDE_CONFIG_DIR=$HOME/.claude` -> output contains `[vanilla]`
- unset -> output contains `[vanilla]`
- `CLAUDE_CONFIG_DIR=$HOME/.claude-work` -> output contains `[work]`

Existing cases keep passing: they do not set the env, so they render `[vanilla]` and
still match the model/dir/ctx assertions. Sparse/type-confused/format-injection cases
must still exit 0 with no traceback.

## Installation after an existing setup

No re-deploy step: `settings.json` references the repo script directly, so the next
statusline render runs the new code.

- dev clone: commit the change; a new `claude` session shows the badge.
- chezmoi external (`~/.local/share/claudefiles`): `chezmoi update` (or git pull
  there) to land the new HEAD. Re-running `setup.sh` is harmless but not required.
