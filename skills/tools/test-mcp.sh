#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
source "$cf/lib/common.sh"; source "$cf/lib/config.sh"; source "$cf/lib/mcp.sh"

# round 1: context7 (free tier) + ado org "old"
config_set_bool flags.context7 true; config_set context7_api_key ""
config_set_bool flags.ado true; config_set ado.email me@x.com
config_set_array ado.orgs "old"
python3 - <<PY
import json;p="$(config_path)";d=json.load(open(p))
d["ado"]["pat"]={"old":"tok1"}; json.dump(d,open(p,"w"))
PY
mcp_apply
grep -q "mcp add-json --scope user context7" "$(fake_claude_calls)" || { echo FAIL add-c7; exit 1; }
grep -q "azureDevOps-old" "$(fake_claude_calls)" || { echo FAIL add-old; exit 1; }
manifest="$h/.config/claudefiles/managed-mcp.json"
grep -q "azureDevOps-old" "$manifest" || { echo FAIL manifest; exit 1; }

# round 2: drop org "old" -> removed via manifest; an unmanaged user server is never swept
: > "$(fake_claude_calls)"
config_set_array ado.orgs ""            # empty -> []
python3 - <<PY
import json;p="$(config_path)";d=json.load(open(p))
d["ado"]["pat"]={}; json.dump(d,open(p,"w"))
PY
mcp_apply
grep -q "mcp remove --scope user azureDevOps-old" "$(fake_claude_calls)" || { echo FAIL remove-old; exit 1; }
grep -q "someUserServer" "$(fake_claude_calls)" && { echo FAIL nuked-user; exit 1; }

# round 3: nothing changed -> zero claude calls (finding 7, call-idempotent)
: > "$(fake_claude_calls)"
mcp_apply
[ -s "$(fake_claude_calls)" ] && { echo "FAIL churn on unchanged"; exit 1; }
echo "PASS test-mcp"
