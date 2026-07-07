#!/usr/bin/env bash
# test-claudemd.sh — unit tests for lib/claudemd.sh marker-block merge.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
fails=0
chk() { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }
SB=""; trap '[ -n "$SB" ] && rm -rf "$SB"' EXIT
mk() { SB="$(mktemp -d)"; export CLAUDEFILES_CLAUDE_MD="$SB/CLAUDE.md"; }
has_block() { grep -q "claudefiles:codex-review" "$CLAUDEFILES_CLAUDE_MD"; }
source "$cf/skills/tools/lib/faketools.bash"
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

# personal-style block: add, idempotent, and removable; coexists with codex block
setup_fixture_home >/dev/null; hp="$HOME"
export CLAUDEFILES_CLAUDE_MD="$hp/.claude/CLAUDE.md"
claudemd_personal_apply true
grep -q "claudefiles:personal" "$hp/.claude/CLAUDE.md" || { echo FAIL personal-missing; exit 1; }
cp "$hp/.claude/CLAUDE.md" "$hp/first.md"
claudemd_personal_apply true
diff "$hp/first.md" "$hp/.claude/CLAUDE.md" || { echo FAIL personal-not-idempotent; exit 1; }
claudemd_apply true                                  # codex block coexists
grep -q "claudefiles:personal" "$hp/.claude/CLAUDE.md" || { echo FAIL personal-lost; exit 1; }
grep -q "claudefiles:codex-review" "$hp/.claude/CLAUDE.md" || { echo FAIL codex-lost; exit 1; }
claudemd_personal_apply false
grep -q "claudefiles:personal" "$hp/.claude/CLAUDE.md" && { echo FAIL personal-not-removed; exit 1; }
grep -q "claudefiles:codex-review" "$hp/.claude/CLAUDE.md" || { echo FAIL codex-collateral; exit 1; }
unset CLAUDEFILES_CLAUDE_MD

[ "$fails" -eq 0 ] && echo "PASS test-claudemd" || { echo "SOME test-claudemd CASES FAILED"; exit 1; }
