#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
for m in common config settings skills mcp claudemd plugins profiles; do source "$cf/lib/$m.sh"; done
mkdir -p "$h/.config/claudefiles"
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"context7":false,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false},"context7_api_key":"" }
EOF

# profile_dir mapping
[ "$(profile_dir vanilla)" = "$h/.claude" ] || { echo FAIL dir-vanilla; exit 1; }
[ "$(profile_dir super)" = "$h/.claude-super" ] || { echo FAIL dir-super; exit 1; }

# credentials symlink: default dir untouched; non-default gets a symlink to default creds
printf 'CREDS' > "$h/.claude/.credentials.json"
ensure_credentials_symlink "$h/.claude"                       # default: no-op
[ -L "$h/.claude/.credentials.json" ] && { echo FAIL default-symlinked; exit 1; }
mkdir -p "$h/.claude-super"
ensure_credentials_symlink "$h/.claude-super"
[ -L "$h/.claude-super/.credentials.json" ] || { echo FAIL no-symlink; exit 1; }
[ "$(cat "$h/.claude-super/.credentials.json")" = "CREDS" ] || { echo FAIL symlink-target; exit 1; }

# wrapper: executable, exports CLAUDE_CONFIG_DIR
generate_wrapper super "$h/.claude-super"
w="$h/.local/bin/claude-super"
[ -x "$w" ] || { echo FAIL wrapper-not-exec; exit 1; }
grep -q 'CLAUDE_CONFIG_DIR=' "$w" || { echo FAIL wrapper-no-env; exit 1; }
grep -qF "$h/.claude-super" "$w" || { echo FAIL wrapper-no-dir; exit 1; }
grep -qF "claudefiles-managed-wrapper" "$w" || { echo FAIL wrapper-no-marker; exit 1; }

# P2b: an UNMANAGED existing claude-super is not clobbered
printf '#!/bin/sh\necho MINE\n' > "$h/.local/bin/claude-super"; chmod +x "$h/.local/bin/claude-super"
generate_wrapper super "$h/.claude-super"
grep -q "MINE" "$h/.local/bin/claude-super" || { echo FAIL clobbered-unmanaged-wrapper; exit 1; }
rm -f "$h/.local/bin/claude-super"

# P3: provision_selected runs recipes in subshells; env must NOT leak into THIS shell
provision_selected "$cf" vanilla
[ -z "${CLAUDEFILES_TARGET:-}" ] || { echo FAIL target-leaked-into-caller; exit 1; }
[ -z "${CLAUDE_CONFIG_DIR:-}" ] || { echo FAIL config-dir-leaked-into-caller; exit 1; }
[ "${#PROVISION_FAILED[@]}" -eq 0 ] || { echo FAIL vanilla-recipe-failed; exit 1; }
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["theme"]=="light";assert "enabledPlugins" not in d;print("ok vanilla-recipe")' "$h/.claude/settings.json"
[ -f "$h/.claude/skills/context7-mcp/SKILL.md" ] || { echo FAIL vanilla-skill; exit 1; }
grep -q "claudefiles:personal" "$h/.claude/CLAUDE.md" || { echo FAIL vanilla-claudemd; exit 1; }
echo "PASS test-profiles"
