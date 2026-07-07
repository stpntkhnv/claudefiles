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
echo "PASS test-mcp"
