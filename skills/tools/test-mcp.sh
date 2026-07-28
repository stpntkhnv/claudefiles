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

# --- linear: удалённый HTTP-сервер по флагу, без секретов -----------------------
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
# super: все флаги кроме linear выключены -> ровно один сервер
python3 "$cf/claude/mcp/build_servers.py" "$(config_path)" | python3 -c '
import json,sys
d=json.load(sys.stdin); assert list(d)==["linear"], d; print("ok super-linear")'
# api-ключ context7 продолжает доезжать до аргументов после рефакторинга
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

echo "PASS test-mcp"
