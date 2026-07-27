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

unset CLAUDEFILES_TARGET CLAUDEFILES_GSTACK_REPO GSTACK_FAKE_LOG
[ "$fails" -eq 0 ] && echo "PASS test-gstack" || { echo "SOME test-gstack CASES FAILED"; exit 1; }
