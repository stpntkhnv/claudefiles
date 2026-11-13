#!/usr/bin/env bash
# Install the full ~/.claude config on this machine. Idempotent; the update path too.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for m in common config deps settings skills plugins mcp claudemd gstack kb profiles clean; do source "$ROOT/lib/$m.sh"; done

log "preflight"; require_cmd git; require_cmd python3
command -v claude >/dev/null 2>&1 || warn "claude not on PATH yet (install it, then re-run)"

log "config"
[ "${1:-}" = "--non-interactive" ] && export CLAUDEFILES_ASSUME_TTY=0
# Phase A: asked BEFORE config_ensure_all, because clean wipes the stored answers — asking after
# would erase what the user has just typed. Never persisted: a per-run choice, not a flag.
CLEAN=false
if clean_wanted; then
  CLEAN=true
  clean_preflight
  clean_backup_open
  clean_global
fi
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
  config_ensure_flag profile_gstack "Install the 'g' profile (gstack, vision stage)? (y/N)"
  config_ensure_flag context7      "Enable Context7 MCP? (y/N)"
  if [ "$(config_flag context7)" = true ]; then
    config_ensure_optional context7_api_key "Context7 API key (empty = free tier)" --secret
  fi
  config_ensure_flag linear        "Enable Linear MCP (issue tracker, one-time OAuth login)? (y/N)"
  config_ensure_flag kb            "Enable the shared knowledge base (auto memory in an Obsidian vault)? (y/N)"
  if [ "$(config_flag kb)" = true ]; then
    config_ensure_optional kb.vault_path "Knowledge base vault path (empty = ~/Documents/Notes/kb; in a container name the HOST vault explicitly)"
    kb_vault_path >/dev/null    # fail fast: a bad stored path must not surface inside a recipe
    config_ensure kb.context "Default work context for Claude launches ('none' = no context layer):"
    kb_context_name >/dev/null  # fail fast, same reason
    if ! _kb_in_container; then
      config_ensure kb.machine "Machine name for the machine memory layer ('none' = no machine layer):"
      kb_machine_name >/dev/null
      config_ensure_bool kb.reviewer "Run the weekly knowledge-base review on this machine (one machine per vault)? (y/N)"
    fi
  fi
}
config_ensure_all

log "deps"
super_sel=false; [ "$(config_flag profile_super)" = true ] && super_sel=true
g_sel=false;     [ "$(config_flag profile_gstack)" = true ] && g_sel=true
# P1b: deps derived from the SELECTED profiles. Vanilla always ships context7 (needs node/npx);
# super-only deps stay off unless super is selected, so stale super flags can't drive installs.
c7_dep=true
pw_dep=false; az_dep=false; ado_dep=false; dn_dep=false; cr_dep=false
if [ "$super_sel" = true ]; then
  pw_dep="$(config_flag playwright)"; az_dep="$(config_flag azure_mcp)"; ado_dep="$(config_flag ado)"
  dn_dep="$(config_flag dotnet_skills)"; cr_dep="$(config_flag codex_review)"
fi
deps_apply "$c7_dep" "$pw_dep" "$az_dep" "$ado_dep" "$dn_dep" "$cr_dep" "$g_sel"

# P2a: existing ~/.claude carries the super stack but super was NOT selected -> it will be
# converted to vanilla. Warn loudly (state is regenerable; secrets are preserved).
if [ "$super_sel" != true ] && \
   python3 -c 'import json,sys,os; f=sys.argv[1]; d=json.load(open(f)) if os.path.exists(f) else {}; sys.exit(0 if d.get("enabledPlugins",{}).get("superpowers@claude-plugins-official") else 1)' \
     "$HOME/.claude/settings.json"; then
  warn "existing ~/.claude has the super stack but 'super' was not selected — converting it to vanilla. Re-run and choose super to keep the full stack."
fi

selected=(vanilla)
[ "$super_sel" = true ] && selected+=(super)
[ "$g_sel" = true ] && selected+=(g)

if [ "$CLEAN" = true ]; then clean_warn_unselected "${selected[@]}"; fi
export CLAUDEFILES_CLEAN_ACTIVE="$CLEAN"

provision_selected "$ROOT" "${selected[@]}"        # subshell loop; recipe_super self-verifies superpowers (P1a)
failed=("${PROVISION_FAILED[@]}")

log "kb workspace"
kb_workspace_unwire

log "kb review"
kb_reviewer_apply "$( [ "$(config_flag kb)" = true ] && [ "$(config_get kb.reviewer)" = true ] && echo true || echo false )"

log "verify"
for p in "${selected[@]}"; do
  dir="$(profile_dir "$p")"
  python3 -m json.tool "$dir/settings.json" >/dev/null 2>&1 && log "  $p: settings.json valid" \
    || warn "  $p: settings.json invalid"
  if [ "$CLEAN" = true ]; then clean_verify "$p" "$ROOT"; fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  warn "profiles failed: ${failed[*]}"; exit 1
fi
if [ "$CLEAN" = true ]; then log "clean: backup kept at $CLAUDEFILES_CLEAN_BACKUP"; fi

# The chezmoi side no longer runs this script automatically: its final checklist compares the
# clone's HEAD against this marker and nags until they match, so a successful run must record
# what it applied. Behind the failed-profiles gate on purpose — a half-applied revision must
# keep nagging.
if _applied_head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"; then
  _state="${CLAUDEFILES_STATE_DIR:-$HOME/.config/claudefiles}"
  mkdir -p "$_state"; printf '%s' "$_applied_head" > "$_state/last-applied-head"
fi

# After the failed-profile gate on purpose: if a profile is broken, an OAuth browser flow is the
# last thing the user needs. Each profile in its own subshell, exactly like provision_selected —
# `claude mcp login` targets whatever CLAUDE_CONFIG_DIR points at.
if [ "$(config_flag linear)" = true ]; then
  log "linear auth"
  for p in "${selected[@]}"; do
    ( export CLAUDE_CONFIG_DIR="$(profile_dir "$p")"; mcp_linear_login "$p" )
  done
fi

log "Done. \`claude\` = vanilla$( [ "$super_sel" = true ] && printf '%s' '; `claude-super` = full stack' )$( [ "$g_sel" = true ] && printf '%s' '; `claude-g` = gstack (vision)' )."
