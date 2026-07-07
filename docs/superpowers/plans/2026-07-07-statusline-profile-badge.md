# Statusline Profile Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render an always-visible `[super]`/`[vanilla]` profile badge at the left of the Claude Code statusline so the active profile is unmistakable.

**Architecture:** Both profiles share one statusline script (`claude/statusline/statusline.sh`, referenced by each profile's `settings.json` `statusLine.command`). The script gains a profile badge whose name comes from an explicit command argument passed by each profile's settings template (deterministic), falling back to `$CLAUDE_CONFIG_DIR` basename, then `unknown`. The name is sanitized before rendering.

**Tech Stack:** Bash, python3 (already used by the statusline for JSON parsing), the repo's fake-tool test harness (`skills/tools/`).

## Global Constraints

- Personal style (from CLAUDE.md): short and direct, no code comments unless asked, cite file:line. The statusline script already carries comments in its own style — match them; do not add new commentary beyond the one existing terse-comment convention there.
- Injection-safe rendering: any dynamic value goes through `printf` as a `%s` **data** argument, never as part of the format string. This is the existing discipline in `claude/statusline/statusline.sh:40-42`.
- Profile name sanitized to `[A-Za-z0-9_-]`, capped at 16 chars, empty -> `unknown`.
- Badge colors: `vanilla` cyan, `super` magenta, any other profile yellow; bold.
- Tests run via `bash skills/tools/run-all-tests.sh` and must all pass.

---

### Task 1: Profile detection + badge in the shared statusline

**Files:**
- Modify: `claude/statusline/statusline.sh` (add detection near top; prepend badge in the final `printf` at lines 40-42)
- Test: `skills/tools/test-statusline.sh` (append cases)

**Interfaces:**
- Consumes: statusline JSON on stdin (unchanged); optional first CLI arg `$1` = profile name; env `CLAUDE_CONFIG_DIR`.
- Produces: stdout line beginning with a colored `[<profile>]` token, then the existing `model dir branch ctx effort` render. Profile-name resolution: `$1` if non-empty, else basename of `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` mapped (`.claude`->`vanilla`, `.claude-<n>`->`<n>`, else basename), then sanitized to `[A-Za-z0-9_-]{1,16}` or `unknown`.

- [ ] **Step 1: Write the failing tests**

Append to `skills/tools/test-statusline.sh`, immediately before the final `echo "PASS test-statusline"` line:

```bash
# --- profile badge: explicit arg wins over env ---
j='{"model":{"display_name":"Opus"},"cwd":"/tmp/x"}'
out="$(printf '%s' "$j" | bash "$sl" super)"
echo "$out" | grep -q "\[super\]"   || { echo "FAIL no-super-badge-arg: $out"; exit 1; }
out="$(printf '%s' "$j" | bash "$sl" vanilla)"
echo "$out" | grep -q "\[vanilla\]" || { echo "FAIL no-vanilla-badge-arg: $out"; exit 1; }

# --- profile badge: CLAUDE_CONFIG_DIR fallback when no arg ---
out="$(printf '%s' "$j" | CLAUDE_CONFIG_DIR="$HOME/.claude-super" bash "$sl")"
echo "$out" | grep -q "\[super\]"   || { echo "FAIL env-super-badge: $out"; exit 1; }
out="$(printf '%s' "$j" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$sl")"
echo "$out" | grep -q "\[vanilla\]" || { echo "FAIL env-vanilla-badge: $out"; exit 1; }
out="$(printf '%s' "$j" | env -u CLAUDE_CONFIG_DIR bash "$sl")"
echo "$out" | grep -q "\[vanilla\]" || { echo "FAIL unset-vanilla-badge: $out"; exit 1; }
out="$(printf '%s' "$j" | CLAUDE_CONFIG_DIR="$HOME/.claude-work" bash "$sl")"
echo "$out" | grep -q "\[work\]"    || { echo "FAIL env-work-badge: $out"; exit 1; }

# --- sanitize: control/ANSI content in the config-dir name cannot leak ---
out="$(printf '%s' "$j" | CLAUDE_CONFIG_DIR="$HOME/.claude-$(printf 'a\033[31mb')" bash "$sl")"
stripped="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
first="${stripped%% *}"
echo "$first" | grep -Eq '^\[[A-Za-z0-9_-]+\]$' || { echo "FAIL badge-not-sanitized: $first"; exit 1; }

# --- placement: badge is the very first printable token ---
out="$(printf '%s' "$j" | bash "$sl" super)"
stripped="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
[ "${stripped%% *}" = "[super]" ] || { echo "FAIL badge-not-leftmost: $stripped"; exit 1; }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash skills/tools/test-statusline.sh`
Expected: FAIL on the first new assertion (e.g. `FAIL no-super-badge-arg: …`) — the current script prints no `[super]` token.

- [ ] **Step 3: Implement detection + badge**

In `claude/statusline/statusline.sh`, add this block right before the final comment/`printf` (currently `claude/statusline/statusline.sh:40-42`, the `# cyan model…` comment):

```bash
# profile badge: $1 wins, else derive from CLAUDE_CONFIG_DIR; sanitize hard
prof="${1:-}"
if [ -z "$prof" ]; then
  d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; b="${d##*/}"
  case "$b" in
    .claude)   prof="vanilla" ;;
    .claude-*) prof="${b#.claude-}" ;;
    *)         prof="$b" ;;
  esac
fi
prof="$(printf '%s' "$prof" | tr -cd 'A-Za-z0-9_-' | cut -c1-16)"; [ -z "$prof" ] && prof="unknown"
case "$prof" in
  vanilla) pcol=$'\033[1;36m' ;;
  super)   pcol=$'\033[1;35m' ;;
  *)       pcol=$'\033[1;33m' ;;
esac
badge="${pcol}[${prof}]"$'\033[0m'" "
```

Then change the final `printf` (lines 41-42) to prepend the badge as a leading `%s` data arg:

```bash
# badge (data) then cyan model, blue dir, magenta branch; ctx passed as DATA (%s), never as format
printf '%s\033[36m%s\033[0m \033[34m%s\033[0m\033[35m%s\033[0m%s\033[2m%s\033[0m\n' \
  "$badge" "$MODEL" "$base" "$branch" "$ctx" "$eff"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash skills/tools/test-statusline.sh`
Expected: `PASS test-statusline` (new badge cases plus all pre-existing model/dir/ctx/sparse/type-confusion/format-injection cases).

- [ ] **Step 5: Commit**

```bash
git add claude/statusline/statusline.sh skills/tools/test-statusline.sh
git commit -m "feat(statusline): show active profile badge"
```

---

### Task 2: Profile templates pass the badge argument

**Files:**
- Modify: `claude/settings/settings.vanilla.template.json` (`statusLine.command`)
- Modify: `claude/settings/settings.super.template.json` (`statusLine.command`)
- Test: `skills/tools/test-settings.sh` (two `statusLine.command` assertions)
- Modify: `README.md` (one-line note that the statusline shows the profile badge)

**Interfaces:**
- Consumes: `lib/settings.sh:10` renders `<STATUSLINE_PATH>` -> `$repo/claude/statusline/statusline.sh`, leaving any trailing text in the JSON string intact.
- Produces: `settings.json` `statusLine.command` == `<abs statusline path> vanilla` (vanilla) / `… super` (super). The trailing word is `$1` for Task 1's script.

- [ ] **Step 1: Update the failing tests**

In `skills/tools/test-settings.sh`, update the two `statusLine.command` assertions to expect the profile arg.

Super block (`# --- super profile: …`):

```python
assert d["statusLine"]["command"]==f"{cf}/claude/statusline/statusline.sh super", "super statusline arg not rendered"
```

Migration block (`# --- MIGRATION: …`, uses the VANILLA template):

```python
assert d["statusLine"]["command"]==f"{cf}/claude/statusline/statusline.sh vanilla", "vanilla statusline arg not rendered"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/tools/test-settings.sh`
Expected: FAIL — `AssertionError: super statusline arg not rendered` (templates still emit the bare path with no arg).

- [ ] **Step 3: Add the argument to both templates**

`claude/settings/settings.vanilla.template.json` — change the `statusLine.command` line to:

```json
    "command": "<STATUSLINE_PATH> vanilla",
```

`claude/settings/settings.super.template.json` — change the `statusLine.command` line to:

```json
    "command": "<STATUSLINE_PATH> super",
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/tools/test-settings.sh`
Expected: `PASS test-settings`.

- [ ] **Step 5: Note the badge in the README**

In `README.md`, in the profiles table rows, the statusline is described as `статуслайн (claude/statusline/statusline.sh)`. Append to that description (both vanilla and super rows) the clause: `с бейджем профиля (`[vanilla]`/`[super]`) слева`. Keep it to that clause; do not restructure the table.

- [ ] **Step 6: Run the full suite**

Run: `bash skills/tools/run-all-tests.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 7: Commit**

```bash
git add claude/settings/settings.vanilla.template.json claude/settings/settings.super.template.json skills/tools/test-settings.sh README.md
git commit -m "feat(settings): pass profile name to the statusline badge"
```

---

## Manual verification (after both tasks)

The unit tests cover the script and the rendered command in isolation. To confirm the real path end-to-end:

1. Re-run `./setup.sh` so both profiles' `settings.json` are regenerated with the arg.
2. Start `claude` -> statusline begins with `[vanilla]` (cyan).
3. Start `claude-super` -> statusline begins with `[super]` (magenta).

The `$CLAUDE_CONFIG_DIR` fallback already yields the right badge before the re-run, since the env is inherited by the statusline subprocess; the re-run just makes it deterministic via the explicit arg.
