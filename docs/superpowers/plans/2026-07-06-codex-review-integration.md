# Codex Cross-Review Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Layer an advisory, single-shot Codex (GPT-5.5 / high reasoning) cross-review onto the superpowers workflow at three checkpoints (spec, plan, code diff) without touching any superpowers file.

**Architecture:** A personal `codex-review` skill (the brain) is installed to `~/.claude/skills`; a standing rule in a managed `~/.claude/CLAUDE.md` block nudges Claude to invoke it at each checkpoint and triage findings via receiving-code-review. The skill shells out to `codex exec` (spec/plan markdown, in-repo read-only) and `codex review` (code diff). Everything is flag-gated in `setup.sh`, idempotent, and unit-tested against a fake `codex` binary. Model/effort are passed inline per call — the global `~/.codex/config.toml` is never written.

**Tech Stack:** Bash (`set -euo pipefail` modules), Python 3 stdlib (JSON/text merges), Codex CLI ≥ 0.142.5, Claude Code plugins/skills/hooks.

## Global Constraints

- **Never modify superpowers files.** Integration is a layer only (skill + CLAUDE.md nudge + config).
- **Idempotent:** `setup.sh` run twice produces zero diff and exits 0.
- **Flag-gated, with a hard gate:** `flags.codex_review` gates the whole feature. The optional plugin's effective state is `codex_plugin_enabled = codex_review AND codex_plugin` — the plugin can never be on while the feature is off. A disabled feature **actively removes** its traces (skill dir, CLAUDE.md block, settings keys), not just "doesn't add" them.
- **Public repo, no secrets in git.** Codex auth lives in `~/.codex/auth.json` (managed by `codex login`), never by claudefiles.
- **Codex min version:** `0.142.5` (contract floor for `codex review` + batch flags).
- **Model pinned inline, every call:** `-c model="gpt-5.5" -c model_reasoning_effort="high"`. Never write `~/.codex/config.toml` (inline `-c` avoids the [config-effort-ignored bug](https://github.com/openai/codex/issues/28113) and side-effects on the user's normal sessions).
- **Batch-safe `codex exec`:** `--sandbox read-only --skip-git-repo-check --ephemeral -o <file>`, wrapped in `timeout`. Auth failure / non-zero exit / timeout ⇒ report and skip (never hang, never gate).
- **Every bash path is non-fatal** under `set -euo pipefail` — modules `return 0`.
- **Tests run against a fake `codex`**, exactly as existing tests use a fake `claude`.

---

### Task 1: CLI contract smoke (front-loaded verification)

Verify the real `codex` CLI exposes the surface everything else depends on **before** building on it.
Self-skips when codex is absent, so it is safe in the suite and on CI.

**Files:**
- Create: `skills/tools/smoke-codex-review.sh`
- Modify: `skills/tools/run-all-tests.sh` (also run `smoke-*.sh`, self-skipping)

**Interfaces:**
- Consumes: a real `codex` on PATH (self-skips otherwise). Asserts CLI contract only — no network model-run.

- [ ] **Step 1: Write the smoke test**

Create `skills/tools/smoke-codex-review.sh`:

```bash
#!/usr/bin/env bash
# smoke-codex-review.sh — assert the REAL codex CLI still exposes the surface codex-review
# depends on. Contract only: help/version/login/doctor-parse. No network model-run. Self-skips
# when codex is absent, so it is safe inside run-all-tests.sh.
set -uo pipefail
if ! command -v codex >/dev/null 2>&1 || ! codex --version >/dev/null 2>&1; then
  echo "SKIP smoke-codex-review (no runnable codex)"; exit 0
fi
fails=0
chk() { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }
v="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
chk "codex >= 0.142.5 (got ${v:-none})" bash -c '[ "$(printf "0.142.5\n%s\n" "'"$v"'" | sort -V | head -1)" = "0.142.5" ]'
chk "codex exec exposes --ephemeral"              bash -c 'codex exec   --help 2>&1 | grep -q -- --ephemeral'
chk "codex exec exposes --skip-git-repo-check"    bash -c 'codex exec   --help 2>&1 | grep -q -- --skip-git-repo-check'
chk "codex exec exposes -o/--output-last-message" bash -c 'codex exec   --help 2>&1 | grep -q -- --output-last-message'
chk "codex exec exposes --cd"                     bash -c 'codex exec   --help 2>&1 | grep -q -- --cd || codex --help 2>&1 | grep -q -- --cd'
chk "codex review exposes --base"                 bash -c 'codex review --help 2>&1 | grep -q -- --base'
chk "codex login has a status subcommand"         bash -c 'codex login  --help 2>&1 | grep -qw status'
chk "codex doctor --json parses"                  bash -c 'timeout 20 codex doctor --json 2>/dev/null | python3 -c "import json,sys; json.load(sys.stdin)"'
[ "$fails" -eq 0 ] && echo "PASS smoke-codex-review" || { echo "SMOKE FAILED — codex CLI surface drifted"; exit 1; }
```

- [ ] **Step 2: Make `run-all-tests.sh` also run smoke scripts**

In `skills/tools/run-all-tests.sh`, after the `test-*.sh` loop (line 17), add a second loop:

```bash
for t in "$here"/smoke-*.sh; do
  [ -e "$t" ] || continue
  name="$(basename "$t")"
  echo "=== $name ==="
  bash "$t" || { echo "FAIL: $name (exit $?)"; fail=1; }
  echo
done
```

- [ ] **Step 3: Run it**

```bash
bash skills/tools/smoke-codex-review.sh
```
Expected on this dev box (codex present, unauthenticated): all contract checks PASS (they need no auth) → `PASS smoke-codex-review`. On a box without codex: `SKIP`. **If any contract check FAILS, stop — the plan's command shapes are built on a drifted CLI and must be revisited before continuing.**

- [ ] **Step 4: Commit**

```bash
git add skills/tools/smoke-codex-review.sh skills/tools/run-all-tests.sh
git commit -m "test(codex-review): front-loaded codex CLI contract smoke"
```

---

### Task 2: `codex-review` skill + `skills_apply` delivery

**Files:**
- Create: `claude/skills/codex-review/SKILL.md`
- Modify: `lib/skills.sh` (trailing `codex_review` arg: copy when true, remove when false)
- Test: `skills/tools/test-skills.sh` (extend)

**Interfaces:**
- Produces: `skills_apply <repo_root> <dotnet:true|false> <codex_review:true|false>` — trailing arg optional (`${3:-false}`); `true` copies the skill, `false` removes any previously-copied skill dir. Existing 2-arg callers keep working (removal on default-false is a no-op on a fresh home).

- [ ] **Step 1: Write the skill body**

Create `claude/skills/codex-review/SKILL.md` with exactly this content:

````markdown
---
name: codex-review
description: Use at superpowers checkpoints — after writing a spec (docs/superpowers/specs/) or plan (docs/superpowers/plans/), and at requesting-code-review — to get an independent single-shot Codex (GPT-5.5, high reasoning) review of the artifact, then triage its findings before presenting to the user.
---

# Codex Cross-Review

An independent second reviewer (Codex, GPT-5.5, high reasoning) that complements
superpowers' own self-review. **Advisory and single-shot:** Codex informs, it does
not gate. You triage its findings — you may reject wrong ones with technical reasoning.

## Constants

- Model: `gpt-5.5` — reasoning effort: `high` (passed inline every call; `xhigh` is an
  available upgrade if you want Codex to think longer).
- Timeout: `900` seconds (high reasoning is slow; do not set this low).

## When to Use

Run at these three superpowers checkpoints:

1. **After writing a spec** to `docs/superpowers/specs/…` — before the "user reviews spec" gate.
2. **After writing a plan** to `docs/superpowers/plans/…`.
3. **At requesting-code-review** — on the task's diff (you already have `BASE_SHA`/`HEAD_SHA`).

## Precondition: is Codex runnable?

```bash
command -v codex >/dev/null 2>&1 && codex --version >/dev/null 2>&1 && echo CODEX_RUNNABLE || echo CODEX_UNAVAILABLE
```

If `CODEX_UNAVAILABLE`: tell the user "Codex cross-review skipped — codex CLI not installed",
then continue the superpowers flow normally. Authentication is **not** pre-checked here — if a
review call below exits non-zero (a 401 when `codex login` hasn't been done, or a timeout), report
"Codex cross-review skipped — run `codex login`" and continue. Never block on any of this.

## Reviewing a spec or plan (markdown)

Run Codex in the repo, read-only, so it can pull surrounding context (sibling specs,
`setup.sh`, existing patterns) and produce fewer false positives. Pass the artifact
**path** in the prompt; do not pipe it via stdin.

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
ART="docs/superpowers/specs/2026-01-01-example-design.md"   # the artifact you just wrote
OUT="$(mktemp)"
timeout 900 codex exec \
  --cd "$REPO_ROOT" \
  --sandbox read-only \
  --skip-git-repo-check \
  --ephemeral \
  -c model="gpt-5.5" \
  -c model_reasoning_effort="high" \
  -o "$OUT" \
  "You are a rigorous independent design/plan reviewer. Read the artifact at $ART and the
surrounding repository for context. Critique it for: unstated assumptions, missing edge
cases, scope creep, internal contradictions, testability, and simpler alternatives. This is
a DESIGN review, not a code diff — do not comment on line-level style. Output a prioritized
list of findings (P1/P2 with file:line where possible), then end with exactly one line:
'VERDICT: SOLID' or 'VERDICT: REVISE' plus a one-clause rationale."
echo "--- Codex review ---"; cat "$OUT"; rm -f "$OUT"
```

## Reviewing a code diff

`codex review` reviews the diff against a base ref. It has no `--sandbox`/`-o`/`--ephemeral`
flags (those are `codex exec`-only); capture stdout and wrap in `timeout`. It accepts `-c`
but not `-m`, so pin the model via `-c model=`.

```bash
BASE_SHA="$(git rev-parse HEAD~1)"   # or origin/main — same base the superpowers reviewer uses
timeout 900 codex review \
  --base "$BASE_SHA" \
  -c model="gpt-5.5" \
  -c model_reasoning_effort="high" \
  "Focus on correctness, security, and whether the change matches its stated intent."
```

If `codex review` is unavailable on the machine, fall back to a diff piped through `codex exec`.
Pass the instruction as the prompt **argument** and let the piped diff land in the `<stdin>`
block — do NOT also pass `-` (that would make stdin the whole prompt and drop the instruction):

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
BASE_SHA="$(git rev-parse HEAD~1)"
git diff "$BASE_SHA"...HEAD | timeout 900 codex exec \
  --cd "$REPO_ROOT" --sandbox read-only --skip-git-repo-check --ephemeral \
  -c model="gpt-5.5" -c model_reasoning_effort="high" \
  "Review the diff in the <stdin> block for correctness, security, and intent. End with VERDICT: SOLID | REVISE."
```

## Triage the findings (single pass)

Apply superpowers:receiving-code-review discipline to Codex's output:

- For each finding: **verify against the real artifact/code** before acting.
- Valid → fold into what you present to the user at the checkpoint gate.
- Wrong, or based on stale/missing context → **reject with a one-line technical reason.**
- Do **not** loop: this is one advisory pass. The user is the gate; Codex is a second opinion.

Present a short consolidated summary: which findings you accepted (and the change), which
you rejected (and why), and Codex's VERDICT — then let the user decide.
````

- [ ] **Step 2: Wire `skills_apply` — copy on true, remove on false**

In `lib/skills.sh`, change the signature (line 3) and add the copy/remove after the context7-mcp copy (line 7). Current lines 3-7:

```bash
skills_apply() { # skills_apply <repo_root> <dotnet_enabled:true|false>
  local root="$1" dotnet="${2:-false}" dst="$HOME/.claude/skills"
  mkdir -p "$dst"
  # context7-mcp: real dir (copy) — always
  mkdir -p "$dst/context7-mcp"
  cp "$root/claude/skills/context7-mcp/SKILL.md" "$dst/context7-mcp/SKILL.md"
```

Replace with:

```bash
skills_apply() { # skills_apply <repo_root> <dotnet_enabled:true|false> <codex_review:true|false>
  local root="$1" dotnet="${2:-false}" codex_review="${3:-false}" dst="$HOME/.claude/skills"
  mkdir -p "$dst"
  # context7-mcp: real dir (copy) — always
  mkdir -p "$dst/context7-mcp"
  cp "$root/claude/skills/context7-mcp/SKILL.md" "$dst/context7-mcp/SKILL.md"
  # codex-review: copy by flag; remove when disabled (leave no trace)
  if [ "$codex_review" = true ]; then
    mkdir -p "$dst/codex-review"
    cp "$root/claude/skills/codex-review/SKILL.md" "$dst/codex-review/SKILL.md"
  else
    rm -rf "$dst/codex-review"
  fi
```

- [ ] **Step 3: Write the failing test**

`skills/tools/test-skills.sh` is `set -euo pipefail` hard-exit style using `faketools.bash`'s
`setup_fixture_home`. Its dotnet cases are guarded by a clone-present SKIP at line 9. The
codex-review copy needs no clone, so insert these cases **right after `source …/skills.sh`
(line 5), before that skip guard**, mirroring the file's `[ … ] || { echo FAIL; exit 1; }` and
`[ … ] && { echo FAIL; exit 1; }` idioms:

```bash
# codex-review skill: copied only when the 3rd arg (codex_review) is true
setup_fixture_home >/dev/null; hc="$HOME"
skills_apply "$cf" false true
[ -f "$hc/.claude/skills/codex-review/SKILL.md" ] || { echo FAIL codex-review-copy; exit 1; }
setup_fixture_home >/dev/null; hc2="$HOME"
skills_apply "$cf" false false
[ -e "$hc2/.claude/skills/codex-review/SKILL.md" ] && { echo FAIL codex-review-should-be-absent; exit 1; }
# toggle on -> off removes the skill dir (leave no trace) — the P1a gap
setup_fixture_home >/dev/null; ht="$HOME"
skills_apply "$cf" false true
[ -f "$ht/.claude/skills/codex-review/SKILL.md" ] || { echo FAIL toggle-on; exit 1; }
skills_apply "$cf" false false
[ -e "$ht/.claude/skills/codex-review" ] && { echo FAIL toggle-off-not-removed; exit 1; }
# backward compat: 2-arg legacy call still copies context7
setup_fixture_home >/dev/null; hc3="$HOME"
skills_apply "$cf" false
[ -f "$hc3/.claude/skills/context7-mcp/SKILL.md" ] || { echo FAIL legacy-2arg; exit 1; }
```

- [ ] **Step 4: Run tests — verify fail then pass**

```bash
bash skills/tools/test-skills.sh
```
Expected: FAIL before Step 2's edit (skill not copied / not removed on toggle), PASS after.

- [ ] **Step 5: Commit**

```bash
git add claude/skills/codex-review/SKILL.md lib/skills.sh skills/tools/test-skills.sh
git commit -m "feat(codex-review): skill brain + flag-gated skills_apply (copy/remove)"
```

---

### Task 3: `lib/claudemd.sh` — managed CLAUDE.md nudge block

**Files:**
- Create: `lib/claudemd.sh`
- Test: `skills/tools/test-claudemd.sh`

**Interfaces:**
- Produces: `claudemd_apply <enabled:true|false>` — writes/removes a marker-delimited block in `${CLAUDEFILES_CLAUDE_MD:-$HOME/.claude/CLAUDE.md}`. Idempotent; preserves all non-managed content. `CLAUDEFILES_CLAUDE_MD` override exists for tests.

- [ ] **Step 1: Write the failing test**

Create `skills/tools/test-claudemd.sh`:

```bash
#!/usr/bin/env bash
# test-claudemd.sh — unit tests for lib/claudemd.sh marker-block merge.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
fails=0
chk() { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }
SB=""; trap '[ -n "$SB" ] && rm -rf "$SB"' EXIT
mk() { SB="$(mktemp -d)"; export CLAUDEFILES_CLAUDE_MD="$SB/CLAUDE.md"; }
has_block() { grep -q "claudefiles:codex-review" "$CLAUDEFILES_CLAUDE_MD"; }
source "$cf/lib/claudemd.sh"

# A: enable on a missing file -> file created with exactly one block
mk; claudemd_apply true
chk "enable creates file"          [ -f "$CLAUDEFILES_CLAUDE_MD" ]
chk "enable writes block"          has_block
chk "exactly one begin marker"     [ "$(grep -c '>>> claudefiles:codex-review >>>' "$CLAUDEFILES_CLAUDE_MD")" -eq 1 ]

# B: idempotent — second enable yields byte-identical file
cp "$CLAUDEFILES_CLAUDE_MD" "$SB/first"
claudemd_apply true
chk "enable is idempotent (zero diff)" cmp -s "$SB/first" "$CLAUDEFILES_CLAUDE_MD"

# C: user content preserved; still one block after re-enable
mk; printf 'my rules\n\nkeep me\n' > "$CLAUDEFILES_CLAUDE_MD"
claudemd_apply true; claudemd_apply true
chk "user content preserved"       grep -q "keep me" "$CLAUDEFILES_CLAUDE_MD"
chk "still exactly one block"      [ "$(grep -c '>>> claudefiles:codex-review >>>' "$CLAUDEFILES_CLAUDE_MD")" -eq 1 ]
cp "$CLAUDEFILES_CLAUDE_MD" "$SB/withuser"; claudemd_apply true
chk "idempotent with user content" cmp -s "$SB/withuser" "$CLAUDEFILES_CLAUDE_MD"

# D: disable removes the block but keeps user content
claudemd_apply false
chk "disable removes block"        bash -c '! grep -q "claudefiles:codex-review" "$CLAUDEFILES_CLAUDE_MD"'
chk "disable keeps user content"   grep -q "keep me" "$CLAUDEFILES_CLAUDE_MD"

# E: disable on a missing file is a no-op (does not create it)
mk; claudemd_apply false
chk "disable on missing file -> no file" [ ! -e "$CLAUDEFILES_CLAUDE_MD" ]

[ "$fails" -eq 0 ] && echo "PASS test-claudemd" || { echo "SOME test-claudemd CASES FAILED"; exit 1; }
```

- [ ] **Step 2: Create a stub and run — verify a meaningful red**

Create `lib/claudemd.sh` as a no-op stub first, so the red test fails on an **assertion**
(block not written) rather than a `source`-not-found error (cleaner TDD signal — the P3 note):

```bash
# claudemd.sh — own a marker-delimited block in ~/.claude/CLAUDE.md (stub; implemented next step).
claudemd_apply() { :; }
```

Run:

```bash
bash skills/tools/test-claudemd.sh
```
Expected: FAIL on case A ("enable creates file"/"enable writes block") — the stub does nothing.

- [ ] **Step 3: Implement `lib/claudemd.sh`**

Replace the stub with the full implementation:

```bash
# claudemd.sh — own a marker-delimited block in ~/.claude/CLAUDE.md, preserve the rest.
# Deterministic: strip our block + trailing blank lines, then re-append if enabled.
# Re-running with the same <enabled> yields a byte-identical file. Source, don't execute.
_CLAUDEMD_BEGIN="# >>> claudefiles:codex-review >>>"
_CLAUDEMD_END="# <<< claudefiles:codex-review <<<"
_CLAUDEMD_RULE='At superpowers checkpoints, run the `codex-review` skill for an independent Codex
cross-review, then triage its findings (superpowers:receiving-code-review) before showing the user:
- after writing a spec to docs/superpowers/specs/ (before the user-review gate),
- after writing a plan to docs/superpowers/plans/,
- at requesting-code-review, on the task diff.
Advisory and single-shot: Codex informs, it does not gate. If codex is unauthenticated, report and skip.'

claudemd_apply() { # <enabled:true|false>
  local enabled="${1:-false}"
  local f="${CLAUDEFILES_CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"
  # disable + no file -> nothing to do (don't create a spurious file)
  [ "$enabled" != true ] && [ ! -f "$f" ] && return 0
  mkdir -p "$(dirname "$f")"
  # base = existing content minus our block, with trailing blank lines trimmed
  local base=""
  [ -f "$f" ] && base="$(awk -v b="$_CLAUDEMD_BEGIN" -v e="$_CLAUDEMD_END" '
      $0==b{skip=1;next} $0==e{skip=0;next}
      !skip{a[++n]=$0; if(NF)last=n}
      END{for(i=1;i<=last;i++)print a[i]}' "$f")"
  {
    if [ "$enabled" = true ]; then
      [ -n "$base" ] && printf '%s\n\n' "$base"
      printf '%s\n%s\n%s\n' "$_CLAUDEMD_BEGIN" "$_CLAUDEMD_RULE" "$_CLAUDEMD_END"
    else
      [ -n "$base" ] && printf '%s\n' "$base"
    fi
  } > "$f"
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash skills/tools/test-claudemd.sh
```
Expected: `PASS test-claudemd`.

- [ ] **Step 5: Commit**

```bash
git add lib/claudemd.sh skills/tools/test-claudemd.sh
git commit -m "feat(codex-review): idempotent ~/.claude/CLAUDE.md nudge block"
```

---

### Task 4: deps + readiness Codex checks

**Files:**
- Modify: `lib/deps.sh` (`deps_apply` + `readiness_report` trailing `codex` arg; add `_codex_ok`, `_codex_authed`)
- Test: `skills/tools/test-deps.sh` (extend REAL coreutils list, add `fake_codex`, add cases)

**Interfaces:**
- Consumes: `_offer_install`, `dep_require`, `_rdy`, `_have_node_npx` (existing).
- Produces: `deps_apply <ctx7> <pw> <azure> <ado> <dotnet> <codex>`; `readiness_report <ctx7> <pw> <azure> <ado> <dotnet> <codex>` (trailing arg optional, `${6:-false}`). `_codex_ok` (present + runnable + ≥0.142.5); `_codex_authed` (`codex login status` exits 0).

- [ ] **Step 1: Write the failing test**

In `skills/tools/test-deps.sh`: (a) extend the REAL coreutils resolved at top (line 11) to include `sort timeout head`:

```bash
for c in bash env python3 id mktemp mkdir grep chmod cat rm ln dirname sort timeout head; do REAL[$c]="$(command -v "$c")"; done
```

(b) add a `fake_codex` helper next to `fake_claude` (after line 54). Build-time `$1`/`$2` bake the
version and auth state; runtime `\$1`/`\$2` dispatch:

```bash
fake_codex(){   # $1 = version (e.g. 0.142.5); $2 = auth: ok|fail
cat > "$BIN/codex" <<SCRIPT
#!/usr/bin/env bash
case "\$1" in
  --version) echo "codex-cli $1" ;;
  login)     [ "\$2" = status ] && { [ "$2" = ok ] && exit 0 || { echo "Not logged in"; exit 1; }; } ;;
  *)         exit 0 ;;
esac
SCRIPT
chmod +x "$BIN/codex"; }
```

(c) add cases at the end (before the final summary line):

```bash
# J: codex flag + codex absent -> readiness reports MISSING (non-fatal)
mk_sandbox; fake_claude "superpowers@claude-plugins-official"
load
out="$SB/codex-missing.out"
readiness_report false false false false false true >"$out" 2>&1
chk "codex absent -> readiness MISSING" grep -q "ready: codex CLI .* MISSING" "$out"

# K: codex present + new enough + logged in -> both readiness lines OK
mk_sandbox; fake_claude "superpowers@claude-plugins-official"; fake_codex "0.142.5" "ok"
load
out="$SB/codex-ok.out"
readiness_report false false false false false true >"$out" 2>&1
chk "codex runnable+new -> CLI OK" grep -q "ready: codex CLI .* OK" "$out"
chk "codex logged in -> auth OK"   grep -q "ready: codex auth OK" "$out"

# K2: codex present but NOT logged in -> auth MISSING (login status exits 1)
mk_sandbox; fake_claude "superpowers@claude-plugins-official"; fake_codex "0.142.5" "fail"
load
out="$SB/codex-noauth.out"
readiness_report false false false false false true >"$out" 2>&1
chk "codex not logged in -> auth MISSING" grep -q "ready: codex auth MISSING" "$out"

# L: codex too old -> CLI MISSING (version floor enforced)
mk_sandbox; fake_claude "superpowers@claude-plugins-official"; fake_codex "0.100.0" "ok"
load
out="$SB/codex-old.out"
readiness_report false false false false false true >"$out" 2>&1
chk "codex < floor -> CLI MISSING" grep -q "ready: codex CLI .* MISSING" "$out"

# M: codex flag off -> no codex readiness lines
mk_sandbox; fake_claude "superpowers@claude-plugins-official"
load
out="$SB/codex-off.out"
readiness_report false false false false false false >"$out" 2>&1
chk "codex flag off -> no codex line" bash -c '! grep -q "codex" "'"$out"'"'
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash skills/tools/test-deps.sh
```
Expected: FAIL on the new J/K/K2/L cases (`readiness_report` ignores a 6th arg; no codex line emitted).

- [ ] **Step 3: Implement the deps/readiness changes**

In `lib/deps.sh`, add the two helpers (after `_have_node_npx`, ~line 81):

```bash
_codex_ok() {   # codex present, runnable, and version >= 0.142.5 (min contract floor)
  command -v codex >/dev/null 2>&1 || return 1
  local v; v="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$v" ] || return 1
  [ "$(printf '%s\n%s\n' "0.142.5" "$v" | sort -V | head -1)" = "0.142.5" ]
}

_codex_authed() {   # exit 0 iff codex reports a logged-in session (local, fast; more robust than doctor --json)
  command -v codex >/dev/null 2>&1 || return 1
  timeout 10 codex login status >/dev/null 2>&1
}
```

Extend `deps_apply` (line 68) + add a codex branch before `return 0` (line 78):

```bash
deps_apply() {   # <ctx7> <playwright> <azure> <ado> <dotnet> <codex> — offer-install each needed dep; always 0
  local ctx7="${1:-false}" pw="${2:-false}" azure="${3:-false}" ado="${4:-false}" dotnet="${5:-false}" codex="${6:-false}"
```

```bash
  if [ "$codex" = true ]; then
    dep_require "Codex CLI runtime (node/npx)" node npx -- nodejs npm
    _codex_ok || warn "codex CLI missing or < 0.142.5 — install/upgrade: npm install -g @openai/codex"
  fi
  return 0     # explicit — a disabled feature must not make this non-zero under set -e (finding 1)
```

Extend `readiness_report` (lines 94-95) + add codex lines before `return 0` (line 118):

```bash
readiness_report() {   # <ctx7> <playwright> <azure> <ado> <dotnet> <codex> — non-fatal env summary; always 0
  local ctx7="${1:-false}" pw="${2:-false}" azure="${3:-false}" ado="${4:-false}" dotnet="${5:-false}" codex="${6:-false}"
```

```bash
  if [ "$codex" = true ]; then
    _rdy "codex CLI (>=0.142.5)" "npm install -g @openai/codex" _codex_ok
    _rdy "codex auth"            "run: codex login"             _codex_authed
  fi
  return 0
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash skills/tools/test-deps.sh
```
Expected: `PASS test-deps`.

- [ ] **Step 5: Commit**

```bash
git add lib/deps.sh skills/tools/test-deps.sh
git commit -m "feat(codex-review): deps + readiness codex version/login checks"
```

---

### Task 5: Optional Codex plugin (`codex_plugin`) in settings + plugins

**Files:**
- Modify: `lib/py/jsonmerge.py` (accept `codex_plugin` arg, pop keys when false)
- Modify: `claude/settings/settings.template.json` (add codex plugin + marketplace)
- Modify: `lib/settings.sh` (`settings_apply` trailing `codex_plugin` arg)
- Modify: `lib/plugins.sh` (`plugins_apply` trailing `codex_plugin` arg)
- Test: `skills/tools/test-settings.sh`, `skills/tools/test-plugins.sh` (extend)

**Interfaces:**
- Produces: `settings_apply <hook> <dotnet> <codex_plugin>`; `plugins_apply <dotnet> <codex_plugin>`; `jsonmerge.py <template> <target> <hook> <dotnet> <codex_plugin>` (trailing args optional/default false). Marketplace `openai-codex`, source `openai/codex-plugin-cc`, plugin `codex@openai-codex`.
- **Note:** callers pass the *effective* value `codex_review && codex_plugin` (wired in Task 6), so these functions never see `codex_plugin=true` while the feature is off.

- [ ] **Step 1: Write the failing tests**

`skills/tools/test-settings.sh` is `set -euo pipefail`, calls `settings_apply "<hook>" <dotnet>`
against `$h/.claude/settings.json`, then asserts with a `python3 - "$h/.claude/settings.json" <<'PY'`
heredoc. Append, using the **new 3rd arg** `codex_plugin`:

```bash
# codex plugin gated by the 3rd settings_apply arg (dotnet off here to prove independence)
settings_apply "/new/hook/detect-dotnet.sh" false true
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert d["enabledPlugins"].get("codex@openai-codex") is True, "codex plugin missing when enabled"
assert "openai-codex" in d["extraKnownMarketplaces"], "codex marketplace missing when enabled"
print("ok codex_plugin=on")
PY
settings_apply "/new/hook/detect-dotnet.sh" false false
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert "codex@openai-codex" not in d["enabledPlugins"], "codex plugin present while disabled"
assert "openai-codex" not in d["extraKnownMarketplaces"], "codex marketplace present while disabled"
print("ok codex_plugin=off")
PY
```

`skills/tools/test-plugins.sh` uses `chk`/`hasln`/`noln` and reads the fake-claude call log via
`L="$(fake_claude_calls)"`. Append:

```bash
# codex_plugin on -> marketplace add + install attempted
setup_fixture_home >/dev/null; L="$(fake_claude_calls)"
plugins_apply false true
chk "codex on: marketplace added" hasln "plugin marketplace add openai/codex-plugin-cc" "$L"
chk "codex on: plugin installed"  hasln "plugin install codex@openai-codex" "$L"
# codex_plugin off -> not attempted
setup_fixture_home >/dev/null; L="$(fake_claude_calls)"
plugins_apply false false
chk "codex off: no codex install" noln "plugin install codex@openai-codex" "$L"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bash skills/tools/test-settings.sh; bash skills/tools/test-plugins.sh
```
Expected: FAIL (jsonmerge ignores a 5th arg; plugins_apply ignores a 2nd arg).

- [ ] **Step 3: Implement the changes**

`claude/settings/settings.template.json` — add the codex entries:

```json
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true,
    "dotnet@dotnet-agent-skills": true,
    "codex@openai-codex": true
  },
  "extraKnownMarketplaces": {
    "dotnet-agent-skills": { "source": { "source": "github", "repo": "dotnet/skills" } },
    "openai-codex": { "source": { "source": "github", "repo": "openai/codex-plugin-cc" } }
  },
```

`lib/py/jsonmerge.py` — parse arg (after line 8) + pop when false (after the dotnet pop, lines 11-13):

```python
codex_plugin = (len(sys.argv) > 5 and sys.argv[5] == "true")
```

```python
if not codex_plugin:              # keep settings.json consistent with plugins_apply
    managed["enabledPlugins"].pop("codex@openai-codex", None)
    managed["extraKnownMarketplaces"].pop("openai-codex", None)
```

`lib/settings.sh` — thread the arg (lines 3-6):

```bash
settings_apply() { # settings_apply <hook_abs_path> <dotnet_enabled> <codex_plugin>
  local hook="$1" dotnet="${2:-false}" codex_plugin="${3:-false}" tmpl="$_SET_DIR/../claude/settings/settings.template.json"
  python3 "$_SET_DIR/py/jsonmerge.py" "$tmpl" "$HOME/.claude/settings.json" "$hook" "$dotnet" "$codex_plugin"
  log "settings.json applied (hook: $hook, dotnet: $dotnet, codex_plugin: $codex_plugin)"
}
```

`lib/plugins.sh` — trailing arg + branch (lines 22-31):

```bash
plugins_apply() {         # <dotnet_enabled:true|false> <codex_plugin:true|false>
  local dotnet="${1:-false}" codex_plugin="${2:-false}"
  _ensure_marketplace "claude-plugins-official" "anthropics/claude-plugins-official"
  _ensure_plugin      "superpowers@claude-plugins-official"
  if [ "$dotnet" = true ]; then
    command -v dotnet >/dev/null 2>&1 || warn "dotnet SDK not found; C# LSP will not start until installed"
    _ensure_marketplace "dotnet-agent-skills" "dotnet/skills"
    _ensure_plugin      "dotnet@dotnet-agent-skills"
  fi
  if [ "$codex_plugin" = true ]; then
    command -v codex >/dev/null 2>&1 || warn "codex CLI not found; codex plugin will not function until installed"
    _ensure_marketplace "openai-codex" "openai/codex-plugin-cc"
    _ensure_plugin      "codex@openai-codex"
  fi
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
bash skills/tools/test-settings.sh; bash skills/tools/test-plugins.sh
```
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/py/jsonmerge.py claude/settings/settings.template.json lib/settings.sh lib/plugins.sh skills/tools/test-settings.sh skills/tools/test-plugins.sh
git commit -m "feat(codex-review): optional codex@openai-codex plugin, flag-gated"
```

---

### Task 6: `setup.sh` integration + README

**Files:**
- Modify: `setup.sh` (source `claudemd`; add 2 flags; effective-gate the plugin; add claude.md phase; renumber 8→9; thread flags)
- Modify: `README.md` (Codex cross-review section + dependency row)
- Test: `skills/tools/test-config.sh`, `skills/tools/test-setup-idempotent.sh` (extend)

**Interfaces:**
- Consumes: `claudemd_apply` (Task 3), and the new trailing args on `deps_apply`/`settings_apply`/`skills_apply`/`plugins_apply`/`readiness_report` (Tasks 2,4,5).

- [ ] **Step 1: Source the new module**

`setup.sh` line 5 — add `claudemd` to the source loop:

```bash
for m in common config deps settings skills plugins mcp hooks claudemd; do source "$ROOT/lib/$m.sh"; done
```

- [ ] **Step 2: Add the two flags to `config_ensure_all`**

In `setup.sh`'s `config_ensure_all` (after the `dotnet_skills` flag, ~line 12), add:

```bash
  config_ensure_flag codex_review "Enable Codex cross-review of specs/plans/diffs? (y/N)"
  if [ "$(config_flag codex_review)" = true ]; then
    config_ensure_flag codex_plugin "Also install the Codex plugin for adversarial review? (y/N)"
  fi
```

- [ ] **Step 3: Compute the effective plugin flag, renumber phases 8→9, thread flags**

Rewrite the phase body of `setup.sh` (lines 34-47). Compute `codex_plugin_eff = codex_review AND codex_plugin` (P1a hard gate — the plugin can never be on while the feature is off, even from stale config), insert `claude.md` as phase 6, and pass the real flag values:

```bash
cr="$(config_flag codex_review)"
cpe=false; [ "$cr" = true ] && [ "$(config_flag codex_plugin)" = true ] && cpe=true
log "3/9 deps";          deps_apply "$(config_flag context7)" "$(config_flag playwright)" "$(config_flag azure_mcp)" "$(config_flag ado)" "$(config_flag dotnet_skills)" "$cr"
log "4/9 settings.json"; settings_apply "$(hooks_hook_path "$ROOT")" "$(config_flag dotnet_skills)" "$cpe"
log "5/9 skills";        skills_apply "$ROOT" "$(config_flag dotnet_skills)" "$cr"
log "6/9 claude.md";     claudemd_apply "$cr"
log "7/9 plugins";       plugins_apply "$(config_flag dotnet_skills)" "$cpe" || warn "plugin install failed (rest of config still applied)"
log "8/9 mcp";           mcp_apply
log "9/9 verify"
```

Update the two earlier labels for consistency: `log "1/8 preflight"` → `log "1/9 preflight"`,
`log "2/8 config"` → `log "2/9 config"`. Update the final `readiness_report` call (line ~46):

```bash
readiness_report "$(config_flag context7)" "$(config_flag playwright)" "$(config_flag azure_mcp)" "$(config_flag ado)" "$(config_flag dotnet_skills)" "$cr"
```

- [ ] **Step 4: Extend the config + idempotency tests**

In `skills/tools/test-config.sh` (`set -euo pipefail`, hard-exit), after the flag round-trip block
(line ~17), add:

```bash
config_set_bool flags.codex_review true
[ "$(config_flag codex_review)" = true ]  || { echo "FAIL codex_review flag"; exit 1; }
config_set_bool flags.codex_plugin false
[ "$(config_flag codex_plugin)" = false ] || { echo "FAIL codex_plugin flag"; exit 1; }
```

In `skills/tools/test-setup-idempotent.sh`, the non-interactive run **dies** if a gating flag is
absent (`config_ensure_flag` under `ASSUME_TTY=0` calls `die`). Add both flags to the secrets
fixture heredoc (lines 27-30) — this also makes the double-run cover the skill copy + CLAUDE.md block:

```json
{ "flags": {"context7":true,"playwright":true,"azure_mcp":false,"ado":false,"dotnet_skills":true,"codex_review":true,"codex_plugin":false},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
```

Add a CLAUDE.md idempotency assertion. After line 32 (`cp "$h/.claude/settings.json" "$h/first.json"`):

```bash
cp "$h/.claude/CLAUDE.md" "$h/first-claudemd.md"
```

After the settings diff (line 37):

```bash
diff "$h/first-claudemd.md" "$h/.claude/CLAUDE.md" || { echo "FAIL CLAUDE.md not idempotent"; exit 1; }
```

- [ ] **Step 5: Document in README**

Add a "Codex-ревью (кросс-провайдерная проверка)" section to `README.md` describing: the
`codex_review` flag, that it installs the `codex-review` skill + a `~/.claude/CLAUDE.md` nudge,
that it needs `codex login` (auth not managed by claudefiles), the effective-gated optional
`codex_plugin` flag, and add a dependency-table row:

```
| `codex` CLI (≥0.142.5) | `npm i -g @openai/codex` | Codex cross-review спек/планов/диффов | `codex_review` |
```

- [ ] **Step 6: Run the full suite + idempotency invariant**

```bash
bash skills/tools/test-config.sh
bash skills/tools/test-setup-idempotent.sh
bash skills/tools/run-all-tests.sh
```
Expected: `ALL TESTS PASSED`. The idempotent test proves `setup.sh --non-interactive` run twice
yields zero diff (settings + manifest + CLAUDE.md) and exits 0.

- [ ] **Step 7: Commit**

```bash
git add setup.sh README.md skills/tools/test-config.sh skills/tools/test-setup-idempotent.sh
git commit -m "feat(codex-review): wire flags + effective plugin gate + claude.md phase into setup.sh"
```

---

## Self-Review

**1. Spec coverage:**
- Skill brain (routing, batch-safe, inline model, fixed fallback, triage) → Task 2 (SKILL.md). ✓
- CLAUDE.md nudge → Task 3. ✓
- Feature flag `codex_review` gates + **removes traces** on disable → Tasks 2 (skill rm), 3 (block rm), 6 (effective plugin gate). ✓
- deps version check + readiness auth via `codex login status` → Task 4. ✓
- Optional plugin `codex_plugin`, effective `codex_review && codex_plugin` → Tasks 5, 6. ✓
- setup.sh threading + phases + no `lib/codexcfg.sh` (inline `-c` only) → Task 6 + Task 2 SKILL.md. ✓
- Tests against fake codex + front-loaded contract smoke → Tasks 2,4,5 (fake), Task 1 (smoke). ✓
- Idempotency invariant (incl. CLAUDE.md) → Task 3, Task 6. ✓
- Public repo / no secrets: no new tracked secret; codex auth external. ✓

**2. Placeholder scan:** Model (`gpt-5.5`), effort (`high`), floor (`0.142.5`), timeout (`900`), marketplace/plugin names, all flags concrete. No TBD/TODO. ✓

**3. Type/name consistency:** `codex_review`/`codex_plugin` flags, `cpe` effective flag, `claudemd_apply`, `_codex_ok`, `_codex_authed`, marketplace `openai-codex`, plugin `codex@openai-codex`, and the trailing-arg signatures of `skills_apply`/`deps_apply`/`readiness_report`/`settings_apply`/`plugins_apply` — used identically across Tasks 1–6. ✓

## Notes for the executor

- **Execution order matters only at the ends:** Task 1 (contract smoke) verifies the CLI surface before anything builds on it; Task 6 (setup.sh) threads everything and must be last. Tasks 2–5 each add a *trailing* optional arg with a `false` default, so `setup.sh` keeps working between tasks.
- **`codex review` vs `codex exec` flag sets differ:** `--sandbox/--ephemeral/-o/--skip-git-repo-check` are `codex exec`-only; `codex review` takes `--base/--commit/--uncommitted/-c` and prints to stdout. The SKILL.md keeps the two command shapes distinct — do not cross-apply flags. The `codex exec` fallback for diffs passes the instruction as the prompt argument and the diff via piped stdin (`<stdin>` block) — never with `-`.
- **Effective plugin gate (P1a):** setup.sh passes `cpe = codex_review && codex_plugin` to both `settings_apply` and `plugins_apply`, so flipping `codex_review` off also removes the plugin from `settings.json` (jsonmerge pops the key) — no stale plugin.

## Appendix: round-2 external review (Codex) — incorporated

Plan run through Codex (GPT-5.5) before execution. Verdict: **REVISE**, 5 findings. Triage (receiving-code-review):

- **P1a** (feature flag didn't fully gate/clean up) — **accepted**: effective `codex_plugin = codex_review && codex_plugin` in setup.sh; `skills_apply false` removes the skill dir; added toggle on→off test.
- **P1b** (fallback `codex exec … - "prompt"` broke the CLI contract) — **accepted**: instruction as prompt arg + diff via piped stdin (`<stdin>` block) + `--cd`, no `-`.
- **P1/P2** (`codex review` verified too late) — **partially accepted**: contract smoke moved to Task 1 (front-loaded). Rejected downgrading `codex review` to a mere fast-path — it exists and works on v0.142.5 (verified) and is purpose-built.
- **P2** (`_codex_authed` via `doctor --json` brittle) — **accepted** (verified `codex login status` exits 1 when logged out): switched to `codex login status`.
- **P3** (claudemd red test failed via `source`, noisy) — **accepted**: stub-first so the red test fails on an assertion.
