# plugins.sh — install Claude Code plugins idempotently: superpowers ALWAYS, dotnet by flag.
# Presence is decided from a CAPTURED listing (`... || true`) rather than a pipeline, so a
# failing `claude ... list` degrades to "" -> "absent" -> the add/install runs (its own
# failure is caught by `|| warn`), with no `set -e`/pipefail edge. Never aborts setup.sh.

_ensure_marketplace() {   # <name> <source> — add if absent. Match name OR source as fixed strings:
  local cb; cb="$(claude_bin)"     # the real CLI and our stateful test fake differ on which they print.
  local listing; listing="$("$cb" plugin marketplace list 2>/dev/null || true)"
  if ! grep -qF -e "$1" -e "$2" <<<"$listing"; then
    log "adding marketplace $1"; "$cb" plugin marketplace add "$2" || warn "marketplace add '$1' failed"
  fi
}

_ensure_plugin() {        # <plugin@marketplace> — install if absent. Whole-token match (via _has_token)
  local cb; cb="$(claude_bin)"     # so a substring (e.g. '...-official-x') is never mistaken for installed.
  local listing; listing="$("$cb" plugin list 2>/dev/null || true)"
  if ! _has_token "$1" <<<"$listing"; then
    log "installing $1"; "$cb" plugin install "$1" || warn "install '$1' failed"
  fi
}

plugins_apply() {         # <dotnet_enabled:true|false> <codex_plugin:true|false>
  local dotnet="${1:-false}" codex_plugin="${2:-false}"
  _ensure_marketplace "claude-plugins-official" "anthropics/claude-plugins-official"
  _ensure_plugin      "superpowers@claude-plugins-official"
  if [ "$dotnet" = true ]; then
    command -v dotnet >/dev/null 2>&1 || warn "dotnet SDK not found; C# LSP will not start until installed"
    _ensure_marketplace "dotnet-agent-skills" "dotnet/skills"
    _ensure_plugin      "dotnet@dotnet-agent-skills"
  fi
  if [ "$codex_plugin" = true ]; then
    command -v codex >/dev/null 2>&1 || warn "codex CLI not found; codex plugin will not function until installed"
    _ensure_marketplace "openai-codex" "openai/codex-plugin-cc"
    _ensure_plugin      "codex@openai-codex"
  fi
  return 0
}
