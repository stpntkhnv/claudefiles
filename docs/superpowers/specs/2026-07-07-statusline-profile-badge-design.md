# Statusline profile badge

## Problem

The `vanilla` (`~/.claude`, `claude`) and `super` (`~/.claude-super`, `claude-super`)
profiles differ visually only by `theme` (light vs dark). That is too subtle: when
the user forgets to launch `claude-super` and runs plain `claude` out of habit, they
do not notice for a long time. There is no explicit, always-visible signal of which
profile is active.

## Goal

Make the active profile unmistakable at a glance, from inside any session, without
per-profile duplication of the statusline logic.

## Approach

Both profiles' `settings.json` point `statusLine.command` at the same repo file
(`lib/settings.sh:8,10` renders `<STATUSLINE_PATH>` to
`$repo/claude/statusline/statusline.sh`). A single edit to that shared script renders
a profile badge for both profiles.

**Profile source (in priority order):**

1. **Explicit argument** — each profile's settings template passes the profile name as
   the first argument to the command (`<STATUSLINE_PATH> vanilla`, `<STATUSLINE_PATH>
   super`). This is deterministic and registry-backed: the name is exactly what the
   profile's recipe wrote, not a guess.
2. **`$CLAUDE_CONFIG_DIR` fallback** — if no argument is given (e.g. an already-deployed
   `settings.json` that predates this change), derive the name from the config dir
   basename. Confirmed inherited by statusline subprocesses in a `claude-super`
   session, so the badge works even before a `setup.sh` re-run.
3. **`[unknown]` fallback** — if neither yields a usable name.

Using the explicit argument as the primary source resolves the risk that env is not
passed to the statusline subprocess (the whole feature would otherwise silently
recreate the bug), while the env fallback keeps it working with no re-deploy.

## Change surface

- `claude/statusline/statusline.sh` — profile detection + badge render.
- `claude/settings/settings.vanilla.template.json` — append ` vanilla` to the
  `statusLine.command`.
- `claude/settings/settings.super.template.json` — append ` super` to the
  `statusLine.command`.
- `skills/tools/test-statusline.sh` — new cases.
- `skills/tools/test-settings.sh` — assert the rendered command carries the profile arg.

No changes to `lib/settings.sh` (its `<STATUSLINE_PATH>` sed leaves the trailing arg
intact) or any other `lib/` module. A future profile's template carries its own name
the same way; no parameterization machinery is added now (YAGNI).

## Detection

Resolve the profile name:

- `$1` non-empty -> use it (the explicit, registry-backed name).
- else `$CLAUDE_CONFIG_DIR` (or `$HOME/.claude` if unset): basename `.claude` ->
  `vanilla`; basename `.claude-<name>` -> `<name>`; anything else -> the basename.
- Sanitize the resolved name to `[A-Za-z0-9_-]`, cap to a small length (e.g. 16
  chars). If the result is empty after sanitizing -> `unknown`.

Sanitizing matters because the fallback derives from an environment variable, which
could carry newlines, ANSI, or absurd length; the badge must stay within the existing
injection-safe rendering discipline.

## Render

- Prepend a bold, bracketed badge as the very first token of the line, always shown:
  `[super] …`, `[vanilla] …`.
- Neutral per-profile color: `vanilla` cyan, `super` magenta, any other profile
  yellow.
- Emitted as data via the existing `printf` (never as part of the format string),
  consistent with the current injection-safe rendering.
- Example: `[super] Opus 4.8  claudefiles main  ctx 42% · xhigh`.

## Tests

`skills/tools/test-statusline.sh` — drive the profile both ways:

- arg `super` -> badge `[super]`; arg `vanilla` -> `[vanilla]`.
- no arg, `CLAUDE_CONFIG_DIR=$HOME/.claude-super` -> `[super]`.
- no arg, `CLAUDE_CONFIG_DIR=$HOME/.claude` -> `[vanilla]`.
- no arg, unset env -> `[vanilla]`.
- no arg, `CLAUDE_CONFIG_DIR=$HOME/.claude-work` -> `[work]`.
- sanitize: a config dir basename with ANSI/newline/over-length content -> badge is a
  bounded `[A-Za-z0-9_-]` token (or `[unknown]`), no raw control content leaks.
- placement: strip ANSI from the output and assert the first printable token is
  exactly `[<profile>]` (guards the "very left, always shown" requirement).
- existing cases (model/dir/ctx, sparse, type-confused, format-injection) still pass:
  they call the script with no arg and no profile env, so they render `[vanilla]` and
  still match their assertions, exit 0, and print no traceback.

`skills/tools/test-settings.sh` — after rendering each template, assert the
`statusLine.command` ends with the expected profile arg (`… vanilla`, `… super`).

## Installation after an existing setup

- The `$CLAUDE_CONFIG_DIR` fallback means the badge appears immediately in a new
  session with no re-deploy, because `settings.json` already points at the repo script
  and the env is inherited.
- To get the deterministic explicit argument, re-run `setup.sh` once so each profile's
  `settings.json` is regenerated from the updated template. Idempotent; safe to run.
- dev clone: commit, re-run `./setup.sh`.
- chezmoi external (`~/.local/share/claudefiles`): `chezmoi update` lands the new HEAD
  and re-runs `setup.sh` via its trigger.
