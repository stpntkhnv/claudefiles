---
name: codex-review
description: Use at superpowers checkpoints — after writing a spec (docs/superpowers/specs/) or plan (docs/superpowers/plans/), and at requesting-code-review — to get an independent single-shot Codex (gpt-6-astra by default, model and effort chosen per task) review of the artifact, then triage its findings before presenting to the user.
---

# Codex Cross-Review

An independent second reviewer (Codex, gpt-6-astra by default) that complements
superpowers' own self-review. **Advisory and single-shot:** Codex informs, it does
not gate. You triage its findings — you may reject wrong ones with technical reasoning.

## Constants

- Model: `gpt-6-astra`, reasoning effort `high` by default (passed inline every call). Pick another
  model or effort when it fits the task better: `max` for a deep review of a large or risky change,
  a cheaper model such as `gpt-6.1-terra` for a light pass. `gpt-5.5` no longer works on a ChatGPT
  account. `codex debug models` can hide working slugs: if a slug seems missing, probe it with a
  one-line prompt before falling back.
- Timeout: `3600` seconds (astra at high or max takes 15-30 minutes; raise the timeout rather than
  lowering the effort). Close stdin (`< /dev/null`) on `codex exec` calls that do not pipe input.

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
timeout 3600 codex exec \
  --cd "$REPO_ROOT" \
  --sandbox read-only \
  --skip-git-repo-check \
  --ephemeral \
  -c model="gpt-6-astra" \
  -c model_reasoning_effort="high" \
  -o "$OUT" \
  < /dev/null \
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
timeout 3600 codex review \
  --base "$BASE_SHA" \
  -c model="gpt-6-astra" \
  -c model_reasoning_effort="high" \
  "Focus on correctness, security, and whether the change matches its stated intent."
```

If `codex review` is unavailable on the machine, fall back to a diff piped through `codex exec`.
Pass the instruction as the prompt **argument** and let the piped diff land in the `<stdin>`
block — do NOT also pass `-` (that would make stdin the whole prompt and drop the instruction):

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
BASE_SHA="$(git rev-parse HEAD~1)"
git diff "$BASE_SHA"...HEAD | timeout 3600 codex exec \
  --cd "$REPO_ROOT" --sandbox read-only --skip-git-repo-check --ephemeral \
  -c model="gpt-6-astra" -c model_reasoning_effort="high" \
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
