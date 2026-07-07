#!/usr/bin/env bash
# Install the full ~/.claude config on this machine. Idempotent; the update path too.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for m in common config deps settings skills plugins mcp claudemd profiles; do source "$ROOT/lib/$m.sh"; done

log "preflight"; require_cmd git; require_cmd python3
command -v claude >/dev/null 2>&1 || warn "claude not on PATH yet (install it, then re-run)"

log "config"
[ "${1:-}" = "--non-interactive" ] && export CLAUDEFILES_ASSUME_TTY=0
config_ensure_all() {   # ask ONCE for every flag/secret that gates a feature
  config_ensure_flag profile_super "Install the 'super' profile (full superpowers stack)? (y/N)"
  if [ "$(config_flag profile_super)" = true ]; then
    config_ensure_flag dotnet_skills "Install .NET skills plugin? (y/N)"
    config_ensure_flag codex_review "Enable Codex cross-review of specs/plans/diffs? (y/N)"
    if [ "$(config_flag codex_review)" = true ]; then
      config_ensure_flag codex_plugin "Also install the Codex plugin for adversarial review? (y/N)"
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
  fi
  config_ensure_flag context7      "Enable Context7 MCP? (y/N)"
  if [ "$(config_flag context7)" = true ]; then
    config_ensure_optional context7_api_key "Context7 API key (empty = free tier)" --secret
  fi
}
config_ensure_all

log "deps"
super_sel=false; [ "$(config_flag profile_super)" = true ] && super_sel=true
# P1b: deps derived from the SELECTED profiles. Vanilla always ships context7 (needs node/npx);
# super-only deps stay off unless super is selected, so stale super flags can't drive installs.
c7_dep=true
pw_dep=false; az_dep=false; ado_dep=false; dn_dep=false; cr_dep=false
if [ "$super_sel" = true ]; then
  pw_dep="$(config_flag playwright)"; az_dep="$(config_flag azure_mcp)"; ado_dep="$(config_flag ado)"
  dn_dep="$(config_flag dotnet_skills)"; cr_dep="$(config_flag codex_review)"
fi
deps_apply "$c7_dep" "$pw_dep" "$az_dep" "$ado_dep" "$dn_dep" "$cr_dep"

# P2a: existing ~/.claude carries the super stack but super was NOT selected -> it will be
# converted to vanilla. Warn loudly (state is regenerable; secrets are preserved).
if [ "$super_sel" != true ] && \
   python3 -c 'import json,sys,os; f=sys.argv[1]; d=json.load(open(f)) if os.path.exists(f) else {}; sys.exit(0 if d.get("enabledPlugins",{}).get("superpowers@claude-plugins-official") else 1)' \
     "$HOME/.claude/settings.json"; then
  warn "existing ~/.claude has the super stack but 'super' was not selected — converting it to vanilla. Re-run and choose super to keep the full stack."
fi

selected=(vanilla)
[ "$super_sel" = true ] && selected+=(super)

provision_selected "$ROOT" "${selected[@]}"        # subshell loop; recipe_super self-verifies superpowers (P1a)
failed=("${PROVISION_FAILED[@]}")

log "verify"
for p in "${selected[@]}"; do
  dir="$(profile_dir "$p")"
  python3 -m json.tool "$dir/settings.json" >/dev/null 2>&1 && log "  $p: settings.json valid" \
    || warn "  $p: settings.json invalid"
done

if [ "${#failed[@]}" -gt 0 ]; then
  warn "profiles failed: ${failed[*]}"; exit 1
fi
log "Done. \`claude\` = vanilla$( [ "$super_sel" = true ] && printf '%s' '; `claude-super` = full stack' )."
