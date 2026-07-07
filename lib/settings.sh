# settings.sh — own the managed keys of a profile's settings.json, preserve the rest.
_SET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
settings_apply() { # settings_apply <template_path> <dotnet> <codex_plugin>
  local tmpl="$1" dotnet="${2:-false}" codex_plugin="${3:-false}"
  local target="${CLAUDEFILES_TARGET:-$HOME/.claude}/settings.json"
  local repo; repo="$(cd "$_SET_DIR/.." && pwd)"
  local hook="$repo/claude/hooks/detect-dotnet.sh"
  local statusline="$repo/claude/statusline/statusline.sh"
  local rendered; rendered="$(mktemp)"
  sed -e "s#<HOOK_PATH>#$hook#g" -e "s#<STATUSLINE_PATH>#$statusline#g" "$tmpl" > "$rendered"
  python3 "$_SET_DIR/py/jsonmerge.py" "$rendered" "$target" "$dotnet" "$codex_plugin"
  rm -f "$rendered"
  log "settings.json applied → $target (dotnet: $dotnet, codex_plugin: $codex_plugin)"
}
