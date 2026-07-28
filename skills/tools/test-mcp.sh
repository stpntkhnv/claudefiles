#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
source "$cf/lib/common.sh"; source "$cf/lib/config.sh"; source "$cf/lib/mcp.sh"
mkdir -p "$h/.config/claudefiles"

# build_servers vanilla mode = context7 only, even with super flags on
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"context7":false,"playwright":true,"azure_mcp":true,"ado":false},"context7_api_key":"" }
EOF
van="$(python3 "$cf/claude/mcp/build_servers.py" "$(config_path)" vanilla)"
echo "$van" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert list(d)==["context7"],d;print("ok vanilla-servers")'

# MIGRATION: legacy manifest lists super servers -> vanilla apply removes them, keeps context7
printf '%s' '{"playwright":{"x":1},"azure":{"x":1},"context7":{"y":1}}' > "$h/.config/claudefiles/managed-mcp.json"
: > "$CLAUDE_FAKE_LOG"
mcp_apply "$van" "$(_mcp_manifest vanilla)" "$(_mcp_legacy)"
grep -q "mcp remove --scope user playwright" "$CLAUDE_FAKE_LOG" || { echo FAIL no-remove-playwright; exit 1; }
grep -q "mcp remove --scope user azure"      "$CLAUDE_FAKE_LOG" || { echo FAIL no-remove-azure; exit 1; }
grep -q "mcp add-json --scope user context7" "$CLAUDE_FAKE_LOG" || { echo FAIL no-add-context7; exit 1; }
[ -f "$(_mcp_manifest vanilla)" ] || { echo FAIL no-vanilla-manifest; exit 1; }
[ -f "$h/.config/claudefiles/managed-mcp.json" ] && { echo FAIL legacy-not-consumed; exit 1; }
[ "$(stat -c '%a' "$(_mcp_manifest vanilla)")" = "600" ] || { echo FAIL manifest-perms; exit 1; }

# idempotent: same servers, same manifest -> no claude calls
: > "$CLAUDE_FAKE_LOG"
mcp_apply "$van" "$(_mcp_manifest vanilla)"
grep -q "mcp " "$CLAUDE_FAKE_LOG" && { echo FAIL not-idempotent; exit 1; }

# P1c: manifest already == desired BUT a legacy manifest still lingers (interrupted migration)
# -> must NOT early-return; must still remove legacy super servers and consume legacy.
printf '%s' '{"playwright":{"x":1},"context7":{"y":1}}' > "$h/.config/claudefiles/managed-mcp.json"
: > "$CLAUDE_FAKE_LOG"
mcp_apply "$van" "$(_mcp_manifest vanilla)" "$(_mcp_legacy)"
grep -q "mcp remove --scope user playwright" "$CLAUDE_FAKE_LOG" || { echo FAIL legacy-not-swept-when-manifest-current; exit 1; }
[ -f "$h/.config/claudefiles/managed-mcp.json" ] && { echo FAIL legacy-not-consumed-2; exit 1; }

# --- linear: a remote HTTP server behind a flag, no secrets ---------------------
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"context7":false,"playwright":false,"azure_mcp":false,"ado":false,"linear":true},"context7_api_key":"" }
EOF
python3 "$cf/claude/mcp/build_servers.py" "$(config_path)" vanilla | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert sorted(d)==["context7","linear"], d
assert d["linear"]=={"type":"http","url":"https://mcp.linear.app/mcp"}, d["linear"]
print("ok vanilla-linear")'
python3 "$cf/claude/mcp/build_servers.py" "$(config_path)" g | python3 -c '
import json,sys
d=json.load(sys.stdin); assert sorted(d)==["context7","linear"], d; print("ok g-linear")'
# super: every flag but linear is off -> exactly one server
python3 "$cf/claude/mcp/build_servers.py" "$(config_path)" | python3 -c '
import json,sys
d=json.load(sys.stdin); assert list(d)==["linear"], d; print("ok super-linear")'
# the context7 api key still reaches args after the refactor
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"context7":true,"playwright":false,"azure_mcp":false,"ado":false,"linear":false},"context7_api_key":"KEY1" }
EOF
python3 "$cf/claude/mcp/build_servers.py" "$(config_path)" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert list(d)==["context7"], d
assert d["context7"]["args"][-2:]==["--api-key","KEY1"], d["context7"]
print("ok super-c7-key")'
python3 "$cf/claude/mcp/build_servers.py" "$(config_path)" vanilla | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert list(d)==["context7"], d
assert d["context7"]["args"][-2:]==["--api-key","KEY1"], d["context7"]
print("ok vanilla-c7-key")'

# --- mcp_linear_login: login exactly when the CLI said auth is needed -----------
cb="$(claude_bin)"
"$cb" mcp add-json --scope user linear '{"type":"http","url":"https://mcp.linear.app/mcp"}' >/dev/null

printf '%s' '{"flags":{"linear":false}}' > "$h/.config/claudefiles/secrets.json"
: > "$CLAUDE_FAKE_LOG"
CLAUDEFILES_ASSUME_TTY=1 mcp_linear_login vanilla
grep -q "mcp " "$CLAUDE_FAKE_LOG" && { echo FAIL login-touched-cli-with-flag-off; exit 1; }

printf '%s' '{"flags":{"linear":true}}' > "$h/.config/claudefiles/secrets.json"
: > "$CLAUDE_FAKE_LOG"
CLAUDEFILES_ASSUME_TTY=1 mcp_linear_login vanilla
grep -q "mcp login linear" "$CLAUDE_FAKE_LOG" || { echo FAIL no-login-when-needed; exit 1; }

: > "$CLAUDE_FAKE_LOG"
CLAUDE_FAKE_MCP_AUTH=ok CLAUDEFILES_ASSUME_TTY=1 mcp_linear_login vanilla
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL login-when-already-authed; exit 1; }

# unrecognised status (wording changed, server wedged): warn instead of silently treating it as
# fine or logging in. Must run before the drift case below removes the server from the fake state.
: > "$CLAUDE_FAKE_LOG"
CLAUDE_FAKE_MCP_AUTH=unknown CLAUDEFILES_ASSUME_TTY=1 mcp_linear_login vanilla 2> "$h/linear-unknown.log"
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL login-on-unknown-status; exit 1; }
grep -q "unexpected status" "$h/linear-unknown.log" || { echo FAIL no-warn-on-unknown-status; exit 1; }

: > "$CLAUDE_FAKE_LOG"
CLAUDEFILES_ASSUME_TTY=0 mcp_linear_login vanilla 2> "$h/linear-notty.log"
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL login-without-tty; exit 1; }
grep -q "claude mcp login linear" "$h/linear-notty.log" || { echo FAIL no-manual-hint-without-tty; exit 1; }

# CLI unavailable: override the resolver in a subshell so PATH (and the real claude it might
# expose) is never touched. flags.linear is already true from above, so the flag gate doesn't
# short-circuit before this branch is reached.
: > "$CLAUDE_FAKE_LOG"
( claude_bin() { echo "$h/no-such-claude"; }; mcp_linear_login vanilla ) 2> "$h/linear-nocli.log" \
  || { echo FAIL login-nonzero-without-cli; exit 1; }
grep -q "claude not available" "$h/linear-nocli.log" || { echo FAIL no-warn-without-cli; exit 1; }
[ -s "$CLAUDE_FAKE_LOG" ] && { echo FAIL cli-called-when-unavailable; exit 1; }

# rc=124 (the status check itself timed out) must get its own message, not the generic drift
# text: a slow/unreachable network is a different fault than a missing server, and diagnosing it
# as "not in config" sends the user chasing a manifest that is fine. Stub `timeout` itself (not
# `claude`) so this is deterministic and instant — no real waiting, no real network.
tdir="$(mktemp -d)"
cat > "$tdir/timeout" <<'EOF'
#!/usr/bin/env bash
# Always reports "timed out", regardless of args, to pin mcp_linear_login's rc=124 branch.
exit 124
EOF
chmod +x "$tdir/timeout"
: > "$CLAUDE_FAKE_LOG"
( export PATH="$tdir:$PATH"; CLAUDEFILES_ASSUME_TTY=1 mcp_linear_login vanilla ) 2> "$h/linear-timeout.log" \
  || { echo FAIL login-nonzero-on-check-timeout; exit 1; }
grep -q "status check timed out" "$h/linear-timeout.log" || { echo FAIL no-timeout-message; exit 1; }
grep -q "not in this profile's config" "$h/linear-timeout.log" && { echo FAIL timeout-used-drift-message; exit 1; }
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL login-attempted-after-timeout; exit 1; }
rm -rf "$tdir"
echo "ok linear-login-timeout-branch"

# drift: manifest present, server gone from the config -> `mcp get` exits non-zero. Don't log in,
# don't die, but don't stay quiet either: silence here would report success on a broken Linear.
# Assert on the "not in this profile's config" text, which ONLY the rc-nonzero branch emits —
# the catch-all unknown-status warn below also mentions $fix, so asserting on the shared
# "claude mcp login linear" tail would pass even with the rc-nonzero branch deleted.
"$cb" mcp remove --scope user linear >/dev/null 2>&1 || true
: > "$CLAUDE_FAKE_LOG"
CLAUDEFILES_ASSUME_TTY=1 mcp_linear_login vanilla 2> "$h/linear-missing.log" \
  || { echo FAIL login-nonzero-on-missing-server; exit 1; }
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL login-on-missing-server; exit 1; }
grep -q "not in this profile's config" "$h/linear-missing.log" || { echo FAIL no-warn-on-missing-server; exit 1; }
echo "ok linear-login-gate"

# --- Finding-1 regression: the CLI calls in mcp_linear_login must run in the terminal's foreground
# process group (see the --foreground comment in lib/mcp.sh). faketools.bash's fake `claude` is a
# plain bash script that never touches a terminal, so it cannot see GNU timeout backgrounding the
# wrapped command (setpgid(0,0) without --foreground) — that blind spot is exactly how the bug
# shipped. This needs a real pty (via `script`) and a stub that reports what it actually got,
# deterministically — no reliance on the real CLI's tcsetattr actually hanging the process.
if ! command -v script >/dev/null 2>&1; then
  echo "SKIP foreground-regression: 'script' (util-linux) not available on this machine"
else
  fgdir="$(mktemp -d)"
  cat > "$fgdir/claude" <<'EOF'
#!/usr/bin/env bash
# Purpose-built stub for the finding-1 regression test only (not faketools.bash's fake): `mcp get`
# just needs to trigger the needs-auth branch; `mcp login` reports its own process group against
# the terminal's foreground process group, instead of actually blocking on tty access.
case "$1 $2" in
  "mcp get")
    printf 'linear:\n  Status: ! Needs authentication\n'; exit 0 ;;
  "mcp login")
    pgid="$(ps -o pgid= -p $$ | tr -d ' ')"; tpgid="$(ps -o tpgid= -p $$ | tr -d ' ')"
    [ "$pgid" = "$tpgid" ] && echo FOREGROUND || echo BACKGROUND
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fgdir/claude"
  runner="$fgdir/run.sh"
  cat > "$runner" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$cf/lib/common.sh"; source "$cf/lib/config.sh"; source "$cf/lib/mcp.sh"
export CLAUDEFILES_ASSUME_TTY=1
mcp_linear_login vanilla
EOF
  printf '%s' '{"flags":{"linear":true}}' > "$h/.config/claudefiles/secrets.json"
  # Bounded by an outer (test-harness-only, not code-under-test) timeout: a real regression here
  # is the CLI getting stopped, not just slow, so a future break should fail fast, not wedge the
  # whole suite. The stub above cannot itself hang -- it only reports pgid vs tpgid and exits.
  # tr strips the \r a pty adds (termios ONLCR turns the stub's LF into CRLF) so the exact-line
  # match below isn't fooled by a trailing \r.
  fgout="$(PATH="$fgdir:$PATH" timeout 15 script -qec "bash '$runner'" /dev/null | tr -d '\r')"
  echo "$fgout" | grep -q "^FOREGROUND$" || { echo "FAIL foreground-regression: expected FOREGROUND, got: $fgout"; exit 1; }
  echo "$fgout" | grep -q "^BACKGROUND$" && { echo "FAIL foreground-regression: got BACKGROUND"; exit 1; }
  rm -rf "$fgdir"
  echo "ok foreground-regression"
fi

echo "PASS test-mcp"
