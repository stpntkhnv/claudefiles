#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null
source "$cf/lib/common.sh"; source "$cf/lib/plugins.sh"
plugins_apply
grep -q "plugin marketplace add dotnet/skills" "$(fake_claude_calls)" || { echo FAIL mkt; exit 1; }
grep -q "plugin install dotnet@dotnet-agent-skills" "$(fake_claude_calls)" || { echo FAIL inst; exit 1; }
echo "PASS test-plugins"
