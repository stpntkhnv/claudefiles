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
{ "flags":{"profile_super":true,"context7":true,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
EOF

CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive

# vanilla (~/.claude) is clean
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert d["theme"]=="light", d.get("theme")
assert "enabledPlugins" not in d, "superpowers not stripped from vanilla"
assert "hooks" not in d, "stale hook survived in vanilla"
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
{ "flags":{"profile_super":false,"context7":false,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
EOF
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive 2> "$h2/err.log"
grep -q "not selected" "$h2/err.log" || { echo FAIL no-p2a-warning; exit 1; }
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert "enabledPlugins" not in d,"super not stripped when declined";print("ok p2a-converted")' "$h2/.claude/settings.json"
[ -e "$h2/.local/bin/claude-super" ] && { echo FAIL wrapper-when-declined; exit 1; }
echo "PASS test-multiprofile"
