#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
source "$cf/lib/common.sh"; source "$cf/lib/settings.sh"

# pre-existing settings with a STALE hook and an UNKNOWN key that must survive
cat > "$h/.claude/settings.json" <<'EOF'
{ "hooks": {"SessionStart":[{"hooks":[{"type":"command","command":"/old/stale/path.sh"}]}]},
  "myCustomKey": {"keep":"me"} }
EOF
settings_apply "/new/hook/detect-dotnet.sh" true
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert d["myCustomKey"]=={"keep":"me"}, "unknown key not preserved"
cmd=d["hooks"]["SessionStart"][0]["hooks"][0]["command"]
assert cmd=="/new/hook/detect-dotnet.sh", f"stale hook survived: {cmd}"
assert d["model"]=="opus[1m]" and d["theme"]=="dark"
assert d["enabledPlugins"].get("dotnet@dotnet-agent-skills") is True, "dotnet plugin missing when enabled"
print("ok dotnet=on")
PY
# dotnet disabled -> plugin AND marketplace must be absent (finding 6)
settings_apply "/new/hook/detect-dotnet.sh" false
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert "dotnet@dotnet-agent-skills" not in d["enabledPlugins"], "dotnet plugin present while disabled"
assert "dotnet-agent-skills" not in d["extraKnownMarketplaces"], "dotnet marketplace present while disabled"
assert d["enabledPlugins"]["superpowers@claude-plugins-official"] is True
assert d["myCustomKey"]=={"keep":"me"}, "unknown key not preserved across re-apply"
print("ok dotnet=off")
PY
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
echo "PASS test-settings"
