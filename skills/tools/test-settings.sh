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
print("PASS test-settings")
PY
