#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"

# seed a "today's super" ~/.claude to exercise migration
mkdir -p "$h/.claude/skills/dotnet-router" "$h/.local/bin"
cat > "$h/.claude/settings.json" <<'EOF'
{ "model":"opus[1m]","effortLevel":"xhigh","theme":"dark",
  "enabledPlugins":{"superpowers@claude-plugins-official":true,"dotnet@dotnet-agent-skills":true},
  "hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/old/detect.sh"}]}]} }
EOF
printf 'CREDS' > "$h/.claude/.credentials.json"
mkdir -p "$h/.config/claudefiles"
printf '%s' '{"playwright":{"x":1},"context7":{"y":1}}' > "$h/.config/claudefiles/managed-mcp.json"
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"profile_super":true,"profile_gstack":false,"context7":true,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false,"linear":false},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
EOF

CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive

# vanilla (~/.claude) is clean
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert d["theme"]=="auto", d.get("theme")
assert "enabledPlugins" not in d, "superpowers not stripped from vanilla"
assert "SessionStart" not in d.get("hooks", {}), "stale hook survived in vanilla"
assert set(d.get("hooks", {}).keys()) == {"Stop", "Notification"}, "vanilla hooks not applied"
assert "model" not in d and "effortLevel" not in d, "heavy defaults not reset"
print("ok vanilla-clean")
PY
[ -e "$h/.claude/skills/dotnet-router" ] && { echo FAIL router-left; exit 1; }
[ -f "$h/.claude/skills/context7-mcp/SKILL.md" ] || { echo FAIL vanilla-c7; exit 1; }
grep -q "claudefiles:personal" "$h/.claude/CLAUDE.md" || { echo FAIL vanilla-personal; exit 1; }

# super (~/.claude-super) is full + wired
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["enabledPlugins"]["superpowers@claude-plugins-official"] is True;assert d["model"]=="opus[1m]";print("ok super-full")' "$h/.claude-super/settings.json"
[ -L "$h/.claude-super/.credentials.json" ] || { echo FAIL super-creds; exit 1; }
[ -x "$h/.local/bin/claude-super" ] || { echo FAIL wrapper; exit 1; }

# (env non-leak is proven in-process by test-profiles.sh via provision_selected; a child
#  `bash setup.sh` cannot leak exports back here regardless, so it is not re-asserted.)

# legacy MCP manifest consumed
[ -f "$h/.config/claudefiles/managed-mcp.json" ] && { echo FAIL legacy-left; exit 1; }

# second run: no diff in either settings.json, and user model in vanilla survives
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1])); d["model"]="sonnet"; json.dump(d, open(sys.argv[1],"w"), indent=2)
PY
cp "$h/.claude-super/settings.json" "$h/super-first.json"
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive
diff "$h/super-first.json" "$h/.claude-super/settings.json" || { echo FAIL super-not-idempotent; exit 1; }
python3 -c 'import json,sys;assert json.load(open(sys.argv[1]))["model"]=="sonnet","user model clobbered"' "$h/.claude/settings.json"

# --- P2a: super stack present but NOT selected -> warn + convert to vanilla, still exit 0 ---
setup_fixture_home >/dev/null; h2="$HOME"
cat > "$h2/.claude/settings.json" <<'EOF'
{ "model":"opus[1m]","enabledPlugins":{"superpowers@claude-plugins-official":true} }
EOF
printf 'CREDS' > "$h2/.claude/.credentials.json"
mkdir -p "$h2/.config/claudefiles"
cat > "$h2/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"profile_super":false,"profile_gstack":false,"context7":false,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false,"linear":false},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
EOF
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive 2> "$h2/err.log"
grep -q "not selected" "$h2/err.log" || { echo FAIL no-p2a-warning; exit 1; }
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert "enabledPlugins" not in d,"super not stripped when declined";print("ok p2a-converted")' "$h2/.claude/settings.json"
[ -e "$h2/.local/bin/claude-super" ] && { echo FAIL wrapper-when-declined; exit 1; }

# profile_gstack=false -> no g dir, no wrapper, and super carries no vision block
[ -e "$h/.claude-g" ] && { echo FAIL g-dir-created-when-off; exit 1; }
[ -e "$h/.local/bin/claude-g" ] && { echo FAIL g-wrapper-created-when-off; exit 1; }
grep -q "claudefiles:vision" "$h/.claude-super/CLAUDE.md" && { echo FAIL super-vision-when-g-off; exit 1; }

# --- Linear: the login phase visits every selected profile, in that profile's dir ---
setup_fixture_home >/dev/null; h3="$HOME"
printf 'CREDS' > "$h3/.claude/.credentials.json"
mkdir -p "$h3/.config/claudefiles"
cat > "$h3/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"profile_super":true,"profile_gstack":false,"context7":true,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false,"linear":true},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
EOF
CLAUDEFILES_ASSUME_TTY=1 bash "$cf/setup.sh" < /dev/null
[ "$(grep -cxF "mcp login linear CLAUDE_CONFIG_DIR=$h3/.claude" "$CLAUDE_FAKE_LOG")" = 1 ] \
  || { echo FAIL no-linear-login-in-vanilla; exit 1; }
[ "$(grep -cxF "mcp login linear CLAUDE_CONFIG_DIR=$h3/.claude-super" "$CLAUDE_FAKE_LOG")" = 1 ] \
  || { echo FAIL no-linear-login-in-super; exit 1; }
[ "$(grep -cF "mcp login linear" "$CLAUDE_FAKE_LOG")" = 2 ] \
  || { echo FAIL linear-login-count; exit 1; }
# without this the asserts above are vacuous: the fake claude's state is one per fixture HOME, so
# `mcp get linear` answers "present" for super even if the server only landed in vanilla. The
# per-profile manifests are real separate files, and they do tell the two apart.
for m in vanilla super; do
  python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert "linear" in d,(sys.argv[1],d)' \
    "$h3/.config/claudefiles/managed-mcp.$m.json" || { echo "FAIL linear-missing-in-$m-manifest"; exit 1; }
done

# already authenticated -> no login at all: the guard against "a browser on every run"
: > "$CLAUDE_FAKE_LOG"
CLAUDE_FAKE_MCP_AUTH=ok CLAUDEFILES_ASSUME_TTY=1 bash "$cf/setup.sh" < /dev/null
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL linear-login-when-authed; exit 1; }

# flag back to false -> the server is removed from every selected profile and no login happens.
# This task is what made the vanilla/g branch in build_servers.py non-terminal, so removal is
# proven end to end, not only by mcp_apply's unit tests.
python3 "$cf/lib/py/config_io.py" setbool "$h3/.config/claudefiles/secrets.json" flags.linear false
: > "$CLAUDE_FAKE_LOG"
CLAUDEFILES_ASSUME_TTY=1 bash "$cf/setup.sh" < /dev/null
grep -q "mcp remove --scope user linear" "$CLAUDE_FAKE_LOG" || { echo FAIL linear-not-removed; exit 1; }
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL linear-login-after-disable; exit 1; }
for m in vanilla super; do
  python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert "linear" not in d,(sys.argv[1],d)' \
    "$h3/.config/claudefiles/managed-mcp.$m.json" || { echo "FAIL linear-left-in-$m-manifest"; exit 1; }
done
python3 "$cf/lib/py/config_io.py" setbool "$h3/.config/claudefiles/secrets.json" flags.linear true

# a failed profile -> setup.sh exits 1 BEFORE the login phase
# KEEP THIS BLOCK LAST: it deliberately forces profile `super`'s self-verify to fail
# (CLAUDE_FAKE_NO_PLUGINS=1 suppresses `plugin list` for this one invocation only, per P1a in
# lib/profiles.sh), so this run of setup.sh exits non-zero. Nothing here is restored afterward —
# anything appended below would run against a fixture whose last setup.sh call just exited 1.
: > "$CLAUDE_FAKE_LOG"
CLAUDE_FAKE_NO_PLUGINS=1 CLAUDEFILES_ASSUME_TTY=1 bash "$cf/setup.sh" < /dev/null \
  && { echo FAIL expected-exit-1-on-failed-profile; exit 1; }
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL linear-login-after-failed-profile; exit 1; }
echo "ok linear-login-phase"
echo "PASS test-multiprofile"
