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
source "$cf/lib/common.sh"
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

# D2: disable on a file that contains ONLY our block — the super->vanilla migration shape, and
# the one case where the write has nothing at all to print
mk; claudemd_apply true
chk "block-only file has the block"  has_block
claudemd_apply false
chk "block-only disable removes the block" bash -c '! grep -q "claudefiles:codex-review" "$CLAUDEFILES_CLAUDE_MD"'
chk "block-only disable empties the file"  [ ! -s "$CLAUDEFILES_CLAUDE_MD" ]
chk "block-only disable leaves no temp file" [ ! -e "$CLAUDEFILES_CLAUDE_MD.tmp" ]

# E: disable on a missing file is a no-op (does not create it)
mk; claudemd_apply false
chk "disable on missing file -> no file" [ ! -e "$CLAUDEFILES_CLAUDE_MD" ]

# E2: a BEGIN marker with no END must not swallow the rest of the file. Such a file is reachable
# two ways: an interrupted earlier write, or a user documenting the marker format by hand.
mk
printf 'intro\n\n%s\nstale rule\nMY IMPORTANT NOTES\nMORE NOTES\n' "$_CLAUDEMD_BEGIN" > "$CLAUDEFILES_CLAUDE_MD"
claudemd_apply true
chk "unterminated BEGIN keeps the tail"        grep -q "MY IMPORTANT NOTES" "$CLAUDEFILES_CLAUDE_MD"
chk "unterminated BEGIN keeps the whole tail"  grep -q "MORE NOTES" "$CLAUDEFILES_CLAUDE_MD"
chk "unterminated BEGIN keeps the head"        grep -qx "intro" "$CLAUDEFILES_CLAUDE_MD"
chk "recovered file has one begin marker" \
  [ "$(grep -c '>>> claudefiles:codex-review >>>' "$CLAUDEFILES_CLAUDE_MD")" -eq 1 ]
chk "recovered file has one end marker" \
  [ "$(grep -c '<<< claudefiles:codex-review <<<' "$CLAUDEFILES_CLAUDE_MD")" -eq 1 ]
cp "$CLAUDEFILES_CLAUDE_MD" "$SB/recovered"; claudemd_apply true
chk "recovered file is idempotent"             cmp -s "$SB/recovered" "$CLAUDEFILES_CLAUDE_MD"

# E3: the write is atomic — a failed write leaves the previous file untouched instead of
# truncating it (which is what could create the unterminated-BEGIN file above).
mk; printf 'precious\n' > "$CLAUDEFILES_CLAUDE_MD"
mkdir "$CLAUDEFILES_CLAUDE_MD.tmp"                     # make the temp write fail
claudemd_apply true 2>/dev/null
chk "failed write keeps the previous content"  grep -qx "precious" "$CLAUDEFILES_CLAUDE_MD"
chk "failed write leaves no half-written block" bash -c '! grep -q "claudefiles:codex-review" "$CLAUDEFILES_CLAUDE_MD"'
rmdir "$CLAUDEFILES_CLAUDE_MD.tmp"
claudemd_apply true
chk "write succeeds again once the path is free" has_block
chk "no temp file left behind"                 [ ! -e "$CLAUDEFILES_CLAUDE_MD.tmp" ]

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

# vision block: producer/consumer/off, coexisting with the other two blocks
setup_fixture_home >/dev/null; hv="$HOME"
export CLAUDEFILES_CLAUDE_MD="$hv/.claude/CLAUDE.md"
printf 'user notes\n' > "$CLAUDEFILES_CLAUDE_MD"

claudemd_vision_apply producer
chk "vision producer writes block"   grep -q "claudefiles:vision" "$CLAUDEFILES_CLAUDE_MD"
chk "vision producer names docs/vision" grep -q "docs/vision/" "$CLAUDEFILES_CLAUDE_MD"
chk "exactly one vision begin"       [ "$(grep -c '>>> claudefiles:vision >>>' "$CLAUDEFILES_CLAUDE_MD")" -eq 1 ]
# both role texts carry the marker and "docs/vision/", so pin each role to its own wording
chk "producer text tells the profile to WRITE" grep -q "owns the VISION stage" "$CLAUDEFILES_CLAUDE_MD"
chk "producer text is not the consumer text" \
  bash -c '! grep -q "turn the vision into a specification" "$CLAUDEFILES_CLAUDE_MD"'

cp "$CLAUDEFILES_CLAUDE_MD" "$hv/vision-first.md"
claudemd_vision_apply producer
chk "vision producer idempotent"     cmp -s "$hv/vision-first.md" "$CLAUDEFILES_CLAUDE_MD"

claudemd_vision_apply consumer
chk "consumer replaces in place"     [ "$(grep -c '>>> claudefiles:vision >>>' "$CLAUDEFILES_CLAUDE_MD")" -eq 1 ]
chk "consumer text differs"          bash -c '! cmp -s "$1" "$CLAUDEFILES_CLAUDE_MD"' _ "$hv/vision-first.md"
chk "consumer text tells the profile to READ" \
  grep -q "turn the vision into a specification" "$CLAUDEFILES_CLAUDE_MD"
chk "consumer text is not the producer text" \
  bash -c '! grep -q "owns the VISION stage" "$CLAUDEFILES_CLAUDE_MD"'

# all three blocks coexist
claudemd_apply true; claudemd_personal_apply true
chk "three blocks coexist: vision"   grep -q "claudefiles:vision" "$CLAUDEFILES_CLAUDE_MD"
chk "three blocks coexist: codex"    grep -q "claudefiles:codex-review" "$CLAUDEFILES_CLAUDE_MD"
chk "three blocks coexist: personal" grep -q "claudefiles:personal" "$CLAUDEFILES_CLAUDE_MD"
chk "user content still there"       grep -q "user notes" "$CLAUDEFILES_CLAUDE_MD"

claudemd_vision_apply off
chk "off removes vision"             bash -c '! grep -q "claudefiles:vision" "$CLAUDEFILES_CLAUDE_MD"'
chk "off keeps codex block"          grep -q "claudefiles:codex-review" "$CLAUDEFILES_CLAUDE_MD"
chk "off keeps personal block"       grep -q "claudefiles:personal" "$CLAUDEFILES_CLAUDE_MD"
chk "off keeps user content"         grep -q "user notes" "$CLAUDEFILES_CLAUDE_MD"

# off on a missing file must not create it
setup_fixture_home >/dev/null; hv2="$HOME"
export CLAUDEFILES_CLAUDE_MD="$hv2/.claude/CLAUDE.md"
claudemd_vision_apply off
chk "off on missing file -> no file" [ ! -e "$CLAUDEFILES_CLAUDE_MD" ]
unset CLAUDEFILES_CLAUDE_MD

# regression: recipe_g's exact sequence (codex off, personal on, vision producer) must be
# idempotent over repeated runs, even with real user content ahead of the blocks. Each block is
# preceded by a blank separator line that our own insert logic adds; stripping and re-appending a
# block used to leave that separator behind as part of `base`, so it collided with the next
# block's own separator into a growing run of blank lines instead of converging (lib/claudemd.sh's
# awk used to trim only overall leading/trailing blanks, not the block-adjacent one).
setup_fixture_home >/dev/null; hg="$HOME"
export CLAUDEFILES_CLAUDE_MD="$hg/.claude/CLAUDE.md"
printf 'my project notes\n\nsome more notes\n' > "$CLAUDEFILES_CLAUDE_MD"
claudemd_apply false; claudemd_personal_apply true; claudemd_vision_apply producer
cp "$CLAUDEFILES_CLAUDE_MD" "$hg/run1.md"
claudemd_apply false; claudemd_personal_apply true; claudemd_vision_apply producer
chk "recipe_g sequence idempotent (run1 == run2)" cmp -s "$hg/run1.md" "$CLAUDEFILES_CLAUDE_MD"
cp "$CLAUDEFILES_CLAUDE_MD" "$hg/run2.md"
claudemd_apply false; claudemd_personal_apply true; claudemd_vision_apply producer
chk "recipe_g sequence idempotent (run2 == run3)" cmp -s "$hg/run2.md" "$CLAUDEFILES_CLAUDE_MD"
unset CLAUDEFILES_CLAUDE_MD

[ "$fails" -eq 0 ] && echo "PASS test-claudemd" || { echo "SOME test-claudemd CASES FAILED"; exit 1; }
