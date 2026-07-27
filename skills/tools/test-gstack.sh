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
{ echo "args: $*"; echo "fonts: ${GSTACK_SKIP_FONTS:-unset}"; } >> "${GSTACK_FAKE_LOG:?}"
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
setup_calls() { grep -c '^args:' "$GSTACK_FAKE_LOG" 2>/dev/null || echo 0; }

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

# B: installer arguments are pinned
chk "installer got --host claude"          grep -q -- '--host claude'          "$GSTACK_FAKE_LOG"
chk "installer got --no-team"              grep -q -- '--no-team'              "$GSTACK_FAKE_LOG"
chk "installer got --no-plan-tune-hooks"   grep -q -- '--no-plan-tune-hooks'   "$GSTACK_FAKE_LOG"
chk "installer got -q"                     grep -q -- '-q'                     "$GSTACK_FAKE_LOG"
chk "fonts install suppressed"             grep -q '^fonts: 1$'                "$GSTACK_FAKE_LOG"

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

unset CLAUDEFILES_TARGET CLAUDEFILES_GSTACK_REPO GSTACK_FAKE_LOG
[ "$fails" -eq 0 ] && echo "PASS test-gstack" || { echo "SOME test-gstack CASES FAILED"; exit 1; }
