# plugins.sh — install the dotnet plugin idempotently.
plugins_apply() {
  local cb; cb="$(claude_bin)"
  command -v dotnet >/dev/null 2>&1 || warn "dotnet SDK not found; C# LSP will not start until installed"
  if ! "$cb" plugin marketplace list 2>/dev/null | grep -q "dotnet-agent-skills\|dotnet/skills"; then
    log "adding dotnet/skills marketplace"; "$cb" plugin marketplace add dotnet/skills
  fi
  if ! "$cb" plugin list 2>/dev/null | grep -qE '(^|[[:space:]])dotnet@dotnet-agent-skills'; then
    log "installing dotnet plugin"; "$cb" plugin install dotnet@dotnet-agent-skills
  fi
}
