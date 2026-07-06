#!/usr/bin/env bash
# Install the full ~/.claude config on this machine. Idempotent; the update path too.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for m in common config deps settings skills plugins mcp hooks claudemd; do source "$ROOT/lib/$m.sh"; done

log "1/9 preflight"; require_cmd git; require_cmd python3
command -v claude >/dev/null 2>&1 || warn "claude not on PATH yet (install it, then re-run)"

log "2/9 config"
[ "${1:-}" = "--non-interactive" ] && export CLAUDEFILES_ASSUME_TTY=0
config_ensure_all() {   # ask ONCE for every flag/secret that gates a feature
  config_ensure_flag dotnet_skills "Install .NET skills plugin? (y/N)"
  config_ensure_flag codex_review "Enable Codex cross-review of specs/plans/diffs? (y/N)"
  if [ "$(config_flag codex_review)" = true ]; then
    config_ensure_flag codex_plugin "Also install the Codex plugin for adversarial review? (y/N)"
  fi
  config_ensure_flag context7      "Enable Context7 MCP? (y/N)"
  if [ "$(config_flag context7)" = true ]; then
    config_ensure_optional context7_api_key "Context7 API key (empty = free tier)" --secret
  fi
  config_ensure_flag playwright "Enable Playwright MCP? (y/N)"
  config_ensure_flag azure_mcp  "Enable Azure MCP? (y/N)"
  config_ensure_flag ado        "Enable Azure DevOps MCP? (y/N)"
  if [ "$(config_flag ado)" = true ]; then
    config_ensure ado.email "Azure DevOps account email"
    _orgs_json="$(config_get ado.orgs)"
    if [ -z "$_orgs_json" ] || [ "$_orgs_json" = "[]" ]; then
      if _has_tty; then
        read -r -p "Azure DevOps organizations (comma-separated): " _orgs || true
        config_set_array ado.orgs "$_orgs"
      else
        die "flags.ado is true but ado.orgs is empty and no TTY to prompt (set it in $(config_path))"
      fi
    fi
    for org in $(config_get ado.orgs | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)))'); do
      config_ensure "ado.pat.$org" "PAT for organization '$org'" --secret
    done
  fi
}
config_ensure_all

cr="$(config_flag codex_review)"
cpe=false; [ "$cr" = true ] && [ "$(config_flag codex_plugin)" = true ] && cpe=true
log "3/9 deps";          deps_apply "$(config_flag context7)" "$(config_flag playwright)" "$(config_flag azure_mcp)" "$(config_flag ado)" "$(config_flag dotnet_skills)" "$cr"
log "4/9 settings.json"; settings_apply "$(hooks_hook_path "$ROOT")" "$(config_flag dotnet_skills)" "$cpe"
log "5/9 skills";        skills_apply "$ROOT" "$(config_flag dotnet_skills)" "$cr"
log "6/9 claude.md";     claudemd_apply "$cr"
log "7/9 plugins";       plugins_apply "$(config_flag dotnet_skills)" "$cpe" || warn "plugin install failed (rest of config still applied)"
log "8/9 mcp";           mcp_apply
log "9/9 verify"
if python3 -m json.tool "$HOME/.claude/settings.json" >/dev/null 2>&1; then log "settings.json valid"; else die "settings.json is invalid after apply"; fi
"$ROOT/skills/tools/test-gen-dotnet-catalog.sh" >/dev/null 2>&1 || warn "catalog self-test FAILED"
readiness_report "$(config_flag context7)" "$(config_flag playwright)" "$(config_flag azure_mcp)" "$(config_flag ado)" "$(config_flag dotnet_skills)" "$cr"
log "Done. Restart Claude Code sessions to pick up skills and hook."
