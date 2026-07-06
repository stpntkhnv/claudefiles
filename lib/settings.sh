# settings.sh — own ~/.claude/settings.json (managed keys), preserve the rest.
_SET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
settings_apply() { # settings_apply <hook_abs_path> <dotnet_enabled> <codex_plugin>
  local hook="$1" dotnet="${2:-false}" codex_plugin="${3:-false}" tmpl="$_SET_DIR/../claude/settings/settings.template.json"
  python3 "$_SET_DIR/py/jsonmerge.py" "$tmpl" "$HOME/.claude/settings.json" "$hook" "$dotnet" "$codex_plugin"
  log "settings.json applied (hook: $hook, dotnet: $dotnet, codex_plugin: $codex_plugin)"
}
