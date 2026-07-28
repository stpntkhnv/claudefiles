#!/usr/bin/env bash
# test-gstack.sh — unit tests for lib/gstack.sh against a fixture upstream repo.
# No network: the "upstream" is a local bare repo whose ./setup only records its invocation.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
fails=0
chk() { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }
source "$cf/skills/tools/lib/faketools.bash"
source "$cf/lib/common.sh"; source "$cf/lib/gstack.sh"

WORK=""; BARE=""
trap '[ -n "$WORK" ] && rm -rf "$WORK"; [ -n "$BARE" ] && rm -rf "$BARE"' EXIT

# fixture upstream: ./setup records how it was called, and can be told to fail
mk_upstream() {
  WORK="$(mktemp -d)"; BARE="$(mktemp -d)/gstack.git"
  git init -q -b main "$WORK"
  cat > "$WORK/setup" <<'EOS'
#!/usr/bin/env bash
# The stdin probe stands in for an upstream prompt: whatever the installer is given as stdin,
# it reads one line of it. Fed /dev/null it sees EOF; fed a terminal it would block forever.
if IFS= read -r _line; then _in="stdin: $_line"; else _in="stdin: eof"; fi
{ echo "args: $*"; echo "fonts: ${GSTACK_SKIP_FONTS:-unset}"; echo "$_in"; } >> "${GSTACK_FAKE_LOG:?}"
[ "${GSTACK_FAKE_FAIL:-0}" = "1" ] && exit 1
# stands in for the real installer's browser download, which was observed stalling indefinitely
[ -n "${GSTACK_FAKE_SLEEP:-}" ] && sleep "$GSTACK_FAKE_SLEEP"
exit 0
EOS
  chmod +x "$WORK/setup"; echo v1 > "$WORK/VERSION"
  git -C "$WORK" add -A
  git -C "$WORK" -c user.email=t@t -c user.name=t commit -qm init
  git clone -q --bare "$WORK" "$BARE"
}
bump_upstream() {   # add a commit and publish it to the bare repo
  echo "$1" > "$WORK/VERSION"
  git -C "$WORK" add -A
  git -C "$WORK" -c user.email=t@t -c user.name=t commit -qm "$1"
  git -C "$WORK" push -q origin HEAD 2>/dev/null || git -C "$WORK" push -q "$BARE" HEAD:main
}
# grep -c already prints 0 on no match (and exits 1), so swallow the status instead of echoing a
# second 0 — an empty log has to yield one line, not "0\n0".
setup_calls() { grep -c '^args:' "$GSTACK_FAKE_LOG" 2>/dev/null || true; }

mk_upstream
setup_fixture_home >/dev/null; h="$HOME"
export CLAUDEFILES_GSTACK_REPO="file://$BARE"
export CLAUDEFILES_TARGET="$h/.claude-g"
export GSTACK_FAKE_LOG="$h/gstack-setup.log"; : > "$GSTACK_FAKE_LOG"
printf '#!/usr/bin/env bash\nexit 0\n' > "$h/bin/bun"; chmod +x "$h/bin/bun"; hash -r 2>/dev/null || true

# A: fresh install
gstack_apply; rc=$?
chk "fresh install returns 0"        [ "$rc" -eq 0 ]
chk "clone landed in the profile"    [ -d "$h/.claude-g/skills/gstack/.git" ]
chk "installer ran once"             [ "$(setup_calls)" -eq 1 ]
chk "marker written"                 [ -s "$h/.claude-g/.gstack-setup-head" ]
chk "marker equals clone HEAD" \
  bash -c '[ "$(cat "$1/.gstack-setup-head")" = "$(git -C "$1/skills/gstack" rev-parse HEAD)" ]' _ "$h/.claude-g"

# B: installer arguments are pinned. Whole-line match on purpose: a substring grep for '-q'
# matches two characters anywhere, so flag drift on an auto-updating upstream would pass silently.
chk "installer args are exactly the pinned set" \
  grep -qxF -- 'args: --host claude --no-team --no-plan-tune-hooks -q' "$GSTACK_FAKE_LOG"
chk "fonts install suppressed"             grep -qx 'fonts: 1'                 "$GSTACK_FAKE_LOG"

# C: the default profile dir is never touched
chk "default profile untouched"      [ ! -e "$h/.claude/skills/gstack" ]

# D: re-run with an unchanged upstream is a no-op
gstack_apply; rc=$?
chk "unchanged re-run returns 0"     [ "$rc" -eq 0 ]
chk "installer NOT run again"        [ "$(setup_calls)" -eq 1 ]

# E: a dirty worktree (the real installer patches SKILL.md name: fields) still updates
echo "patched by the installer" >> "$h/.claude-g/skills/gstack/VERSION"
bump_upstream v2
gstack_apply; rc=$?
chk "dirty tree + moved upstream ok" [ "$rc" -eq 0 ]
chk "installer ran again"            [ "$(setup_calls)" -eq 2 ]
chk "clone is at the new upstream"   bash -c 'grep -qx v2 "$1/skills/gstack/VERSION"' _ "$h/.claude-g"

# F: installer failure -> rc 1 and NO marker update (next run retries)
prev_marker="$(cat "$h/.claude-g/.gstack-setup-head")"
bump_upstream v3
GSTACK_FAKE_FAIL=1 gstack_apply; rc=$?
chk "installer failure returns 1"    [ "$rc" -eq 1 ]
chk "marker not advanced on failure" [ "$(cat "$h/.claude-g/.gstack-setup-head")" = "$prev_marker" ]
gstack_apply; rc=$?
chk "retry after failure succeeds"   [ "$rc" -eq 0 ]

# G: no bun -> rc 1 before any git work (minimal PATH keeps this deterministic)
rm -f "$h/bin/bun"; hash -r 2>/dev/null || true
( PATH="$h/bin"; gstack_apply ); rc=$?
chk "missing bun returns 1"          [ "$rc" -eq 1 ]

# H: marker write fails (path replaced by a directory) -> rc 1, success NOT logged
printf '#!/usr/bin/env bash\nexit 0\n' > "$h/bin/bun"; chmod +x "$h/bin/bun"; hash -r 2>/dev/null || true
rm -f "$h/.claude-g/.gstack-setup-head"; mkdir -p "$h/.claude-g/.gstack-setup-head"
out="$(gstack_apply 2>&1)"; rc=$?
chk "marker write failure returns 1" [ "$rc" -eq 1 ]
chk "success line not logged on marker write failure" \
  bash -c '! grep -q "gstack installed" <<<"$1"' _ "$out"

# I: the installer never inherits our stdin. --no-plan-tune-hooks suppresses the one prompt that
# exists today, but the clone auto-updates: an upstream that renames the flag or adds a prompt must
# turn setup.sh into a failure, not an indefinite block. A wrong default beats a hang.
rm -rf "$h/.claude-g/.gstack-setup-head"        # case H left a directory in the marker's place
bump_upstream v4
gstack_apply < <(printf 'INHERITED-STDIN\n'); rc=$?
chk "moved upstream installs again"        [ "$rc" -eq 0 ]
chk "installer did not read our stdin"     bash -c '! grep -q "INHERITED-STDIN" "$1"' _ "$GSTACK_FAKE_LOG"
chk "installer saw EOF on stdin" \
  bash -c '[ "$(grep "^stdin: " "$1" | tail -1)" = "stdin: eof" ]' _ "$GSTACK_FAKE_LOG"

# J: an unreachable upstream must NOT fail a profile that is already at the recorded revision.
# Offline, `setup.sh` still has to exit 0 (plan Global Constraints).
clone="$h/.claude-g/skills/gstack"
git -C "$clone" remote set-url origin "file:///nonexistent/gstack.git"
calls="$(setup_calls)"
out="$(gstack_apply 2>&1)"; rc=$?
chk "offline + matching marker returns 0"  [ "$rc" -eq 0 ]
chk "offline does not re-run the installer" [ "$(setup_calls)" -eq "$calls" ]
chk "offline reports the skipped update" \
  bash -c 'grep -q "keeping the installed revision" <<<"$1"' _ "$out"

# K: an unreachable upstream with a marker that does NOT match is still a failure, and the warn
# names the remedy for a clone that is broken rather than merely unreachable.
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' > "$h/.claude-g/.gstack-setup-head"
out="$(gstack_apply 2>&1)"; rc=$?
chk "offline + stale marker returns 1"     [ "$rc" -eq 1 ]
chk "fetch failure names the rm -rf remedy" \
  bash -c 'grep -qF "rm -rf $2" <<<"$1"' _ "$out" "$clone"
git -C "$clone" remote set-url origin "file://$BARE"
gstack_apply >/dev/null 2>&1               # back to a converged clone

# O: pinning an EXISTING clone works too. The realistic order is "install first, pin later", and
# an unpinned clone is shallow, so the wanted revision is usually not in it yet.
first="$(git -C "$WORK" rev-list --max-parents=0 HEAD)"
chk "existing clone is shallow (case is meaningful)" \
  bash -c '[ "$(git -C "$1" rev-parse --is-shallow-repository)" = true ]' _ "$clone"
export CLAUDEFILES_GSTACK_REF="$first"; gstack_apply; rc=$?; unset CLAUDEFILES_GSTACK_REF
chk "pinning an existing clone returns 0"  [ "$rc" -eq 0 ]
chk "pinned existing clone moves to the pin" \
  bash -c '[ "$(git -C "$1" rev-parse HEAD)" = "$2" ]' _ "$clone" "$first"
chk "pinned existing clone re-ran the installer" \
  [ "$(cat "$h/.claude-g/.gstack-setup-head")" = "$first" ]

# L: CLAUDEFILES_GSTACK_REF pins a FRESH clone to a reviewed revision, not to upstream HEAD
pin="$first"                                               # the very first commit (VERSION=v1)
tip="$(git -C "$WORK" rev-parse HEAD)"
setup_fixture_home >/dev/null; hp="$HOME"
export CLAUDEFILES_TARGET="$hp/.claude-g"
export GSTACK_FAKE_LOG="$hp/gstack-setup.log"; : > "$GSTACK_FAKE_LOG"
printf '#!/usr/bin/env bash\nexit 0\n' > "$hp/bin/bun"; chmod +x "$hp/bin/bun"; hash -r 2>/dev/null || true
export CLAUDEFILES_GSTACK_REF="$pin"
gstack_apply; rc=$?
chk "pinned install returns 0"             [ "$rc" -eq 0 ]
chk "pin is not upstream HEAD (case is meaningful)" [ "$pin" != "$tip" ]
chk "pinned clone sits on the pin, not on upstream HEAD" \
  bash -c '[ "$(git -C "$1/skills/gstack" rev-parse HEAD)" = "$2" ]' _ "$hp/.claude-g" "$pin"
chk "pinned worktree carries the pinned content" \
  bash -c 'grep -qx v1 "$1/skills/gstack/VERSION"' _ "$hp/.claude-g"
chk "marker records the pin"               [ "$(cat "$hp/.claude-g/.gstack-setup-head")" = "$pin" ]

# M: a pinned re-run stays pinned and does not drift to a moved upstream
bump_upstream v5
calls="$(setup_calls)"
gstack_apply; rc=$?
chk "pinned re-run returns 0"              [ "$rc" -eq 0 ]
chk "pinned re-run does not re-install"    [ "$(setup_calls)" -eq "$calls" ]
chk "pinned re-run stays on the pin" \
  bash -c '[ "$(git -C "$1/skills/gstack" rev-parse HEAD)" = "$2" ]' _ "$hp/.claude-g" "$pin"

# P: a pin may be a tag or a branch, not only a SHA. A tag holds its revision; a branch follows
# its tip, which is what "pin to a maintained release branch" has to mean.
git -C "$WORK" tag -f reviewed "$first" >/dev/null 2>&1
git -C "$WORK" push -q --tags "$BARE" 2>/dev/null || git -C "$WORK" push -q "$BARE" --tags
setup_fixture_home >/dev/null; ht="$HOME"
export CLAUDEFILES_TARGET="$ht/.claude-g"
export GSTACK_FAKE_LOG="$ht/gstack-setup.log"; : > "$GSTACK_FAKE_LOG"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ht/bin/bun"; chmod +x "$ht/bin/bun"; hash -r 2>/dev/null || true
export CLAUDEFILES_GSTACK_REF="reviewed"
gstack_apply; rc=$?
chk "tag pin returns 0"                    [ "$rc" -eq 0 ]
chk "tag pin lands on the tagged revision" \
  bash -c '[ "$(git -C "$1/skills/gstack" rev-parse HEAD)" = "$2" ]' _ "$ht/.claude-g" "$first"

setup_fixture_home >/dev/null; hbr="$HOME"
export CLAUDEFILES_TARGET="$hbr/.claude-g"
export GSTACK_FAKE_LOG="$hbr/gstack-setup.log"; : > "$GSTACK_FAKE_LOG"
printf '#!/usr/bin/env bash\nexit 0\n' > "$hbr/bin/bun"; chmod +x "$hbr/bin/bun"; hash -r 2>/dev/null || true
export CLAUDEFILES_GSTACK_REF="main"
gstack_apply >/dev/null 2>&1; rc=$?
chk "branch pin returns 0"                 [ "$rc" -eq 0 ]
bump_upstream v6
gstack_apply >/dev/null 2>&1; rc=$?
chk "branch pin re-run returns 0"          [ "$rc" -eq 0 ]
chk "branch pin follows the branch tip (origin/main, not a stale local ref)" \
  bash -c '[ "$(git -C "$1/skills/gstack" rev-parse HEAD)" = "$(git -C "$2" rev-parse HEAD)" ]' _ "$hbr/.claude-g" "$WORK"
unset CLAUDEFILES_GSTACK_REF

# N: an unresolvable pin fails loudly instead of silently installing upstream HEAD
setup_fixture_home >/dev/null; hb="$HOME"
export CLAUDEFILES_TARGET="$hb/.claude-g"
export GSTACK_FAKE_LOG="$hb/gstack-setup.log"; : > "$GSTACK_FAKE_LOG"
printf '#!/usr/bin/env bash\nexit 0\n' > "$hb/bin/bun"; chmod +x "$hb/bin/bun"; hash -r 2>/dev/null || true
export CLAUDEFILES_GSTACK_REF="no-such-revision"
out="$(gstack_apply 2>&1)"; rc=$?
chk "unknown pin returns 1"                [ "$rc" -eq 1 ]
chk "unknown pin never runs the installer" [ "$(setup_calls)" -eq 0 ]
chk "unknown pin leaves no marker"         [ ! -e "$hb/.claude-g/.gstack-setup-head" ]
chk "unknown pin is named in the warning" \
  bash -c 'grep -q "no-such-revision" <<<"$1"' _ "$out"
unset CLAUDEFILES_GSTACK_REF

# R: a stalled installer is killed instead of blocking setup.sh forever. Not hypothetical: a live
# run of the real upstream stalled inside `bunx playwright install chromium` and sat for 12h with
# zero bytes of progress. < /dev/null cannot help there — the process is not waiting on stdin.
bump_upstream v-timeout-base
gstack_apply >/dev/null 2>&1        # case N left no marker; establish a good one to compare against
_prev_marker="$(cat "$CLAUDEFILES_TARGET/.gstack-setup-head")"
[ -n "$_prev_marker" ] || { echo "FAIL timeout-case precondition: no marker to compare"; fails=1; }
bump_upstream v-timeout
_calls_before="$(setup_calls)"
out="$(CLAUDEFILES_GSTACK_TIMEOUT=1 GSTACK_FAKE_SLEEP=30 gstack_apply 2>&1)"; rc=$?
chk "stalled installer returns 1"           [ "$rc" -eq 1 ]
chk "stalled installer was actually reached" [ "$(setup_calls)" -gt "$_calls_before" ]
chk "timeout is named in the warning" \
  bash -c 'grep -q "exceeded 1s" <<<"$1"' _ "$out"
chk "timeout warning names the knob" \
  bash -c 'grep -q "CLAUDEFILES_GSTACK_TIMEOUT" <<<"$1"' _ "$out"
chk "stalled installer does not advance the marker" \
  [ "$(cat "$CLAUDEFILES_TARGET/.gstack-setup-head")" = "$_prev_marker" ]

unset CLAUDEFILES_TARGET CLAUDEFILES_GSTACK_REPO GSTACK_FAKE_LOG
[ "$fails" -eq 0 ] && echo "PASS test-gstack" || { echo "SOME test-gstack CASES FAILED"; exit 1; }
