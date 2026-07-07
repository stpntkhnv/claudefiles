#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
source "$cf/lib/common.sh"; source "$cf/lib/skills.sh"
# codex-review skill: copied only when the 3rd arg (codex_review) is true
setup_fixture_home >/dev/null; hc="$HOME"
skills_apply "$cf" false true
[ -f "$hc/.claude/skills/codex-review/SKILL.md" ] || { echo FAIL codex-review-copy; exit 1; }
setup_fixture_home >/dev/null; hc2="$HOME"
skills_apply "$cf" false false
[ -e "$hc2/.claude/skills/codex-review/SKILL.md" ] && { echo FAIL codex-review-should-be-absent; exit 1; }
# toggle on -> off removes the skill dir (leave no trace) — the P1a gap
setup_fixture_home >/dev/null; ht="$HOME"
skills_apply "$cf" false true
[ -f "$ht/.claude/skills/codex-review/SKILL.md" ] || { echo FAIL toggle-on; exit 1; }
skills_apply "$cf" false false
[ -e "$ht/.claude/skills/codex-review" ] && { echo FAIL toggle-off-not-removed; exit 1; }
# backward compat: 2-arg legacy call still copies context7
setup_fixture_home >/dev/null; hc3="$HOME"
skills_apply "$cf" false
[ -f "$hc3/.claude/skills/context7-mcp/SKILL.md" ] || { echo FAIL legacy-2arg; exit 1; }
# re-establish the fresh-fixture precondition the original cases below rely on (HOME==h)
setup_fixture_home >/dev/null; h="$HOME"
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
# P1a: a PRE-EXISTING dotnet-router symlink is removed when dotnet=false (migration)
setup_fixture_home >/dev/null; hp="$HOME"
mkdir -p "$hp/.claude/skills/dotnet-router"
ln -sfnT "$cf/claude/skills/dotnet-router" "$hp/.claude/skills/dotnet-router" 2>/dev/null || true
skills_apply "$cf" false false
[ -e "$hp/.claude/skills/dotnet-router" ] && { echo FAIL dotnet-router-not-removed; exit 1; }
# target-awareness: skills land in CLAUDEFILES_TARGET
setup_fixture_home >/dev/null; ht2="$HOME"; alt="$ht2/.claude-super"; mkdir -p "$alt"
CLAUDEFILES_TARGET="$alt" skills_apply "$cf" false false
[ -f "$alt/skills/context7-mcp/SKILL.md" ] || { echo FAIL target-skills; exit 1; }
echo "PASS test-skills"
