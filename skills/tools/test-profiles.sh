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

# PATH visibility: wrapper dir NOT on PATH -> warn with the exact export fix (non-fatal)
err="$(generate_wrapper super "$h/.claude-super" 2>&1 1>/dev/null)"
printf '%s' "$err" | grep -qF 'is not on $PATH' || { echo FAIL no-path-warning; exit 1; }
printf '%s' "$err" | grep -qF 'export PATH="$HOME/.local/bin:$PATH"' || { echo FAIL path-warning-no-fix; exit 1; }
# ...and SILENT when the dir IS on PATH
err="$( PATH="$h/.local/bin:$PATH"; generate_wrapper super "$h/.claude-super" 2>&1 1>/dev/null )"
[ -z "$err" ] || { echo FAIL unexpected-path-warning; exit 1; }

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

# P1a-FAILURE: recipe_super must return 1 (and provision_selected must record 'super' as
# failed) when superpowers is NOT actually installed after plugins_apply — e.g. plugins_apply
# swallowed an install error internally. Force a `claude` that stays on PATH (so recipe_super
# takes the verify branch, not the "claude absent" warn-only branch) but whose `plugin list`
# never reports superpowers@, regardless of `plugin install` calls (a logged no-op here).
# If recipe_super's P1a check were missing/inverted (i.e. it just `return 0`d), this fake would
# still make `claude plugin list | grep -q 'superpowers@'` fail, so a broken/removed check would
# make this assertion RED (super would then be absent from PROVISION_FAILED) — the test is not
# vacuous.
cat > "$h/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CLAUDE_FAKE_LOG"
case "$1 $2" in
  "plugin list") : ;;    # always empty output: superpowers@ can never match
  *) : ;;                # marketplace add / plugin install: logged no-ops, no state kept
esac
exit 0
EOF
chmod +x "$h/bin/claude"
hash -r 2>/dev/null || true

provision_selected "$cf" super
printf '%s\n' "${PROVISION_FAILED[@]:-}" | grep -qx super || { echo FAIL p1a-failure-not-recorded; exit 1; }
echo "PASS test-profiles"
