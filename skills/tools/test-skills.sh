#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
source "$cf/lib/common.sh"; source "$cf/lib/skills.sh"
# Keep the unit test hermetic: the clone-if-missing path needs the network, so it is
# exercised by the Task 13 container smoke, not here. On the dev machine the clone
# exists, so this asserts the regenerate+symlink behavior without cloning.
[ -d "$cf/skills/dotnet-skills/.git" ] || { echo "SKIP test-skills (clone absent; covered by smoke)"; exit 0; }
skills_apply "$cf" true
[ -f "$h/.claude/skills/context7-mcp/SKILL.md" ] || { echo FAIL c7; exit 1; }
[ -L "$h/.claude/skills/dotnet-router" ] || { echo FAIL symlink; exit 1; }
[ "$(readlink "$h/.claude/skills/dotnet-router")" = "$cf/claude/skills/dotnet-router" ] || { echo FAIL target; exit 1; }
[ -f "$h/.claude/skills/dotnet-router/INDEX.md" ] || { echo FAIL index; exit 1; }
# dotnet disabled -> context7 only, no dotnet-router symlink
setup_fixture_home >/dev/null; h2="$HOME"; skills_apply "$cf" false
[ -f "$h2/.claude/skills/context7-mcp/SKILL.md" ] || { echo FAIL c7-off; exit 1; }
[ -L "$h2/.claude/skills/dotnet-router" ] && { echo FAIL router-should-be-absent; exit 1; }
echo "PASS test-skills"
