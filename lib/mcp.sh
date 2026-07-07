# mcp.sh — reconcile user-scope MCP servers (in $CLAUDE_CONFIG_DIR) against a per-profile manifest.
_MCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_mcp_manifest() { echo "${CLAUDEFILES_CONFIG_DIR:-$HOME/.config/claudefiles}/managed-mcp.$1.json"; }
_mcp_legacy()   { echo "${CLAUDEFILES_CONFIG_DIR:-$HOME/.config/claudefiles}/managed-mcp.json"; }

mcp_apply() { # mcp_apply <servers_json> <manifest_path> [<prev_manifest_path>]
  local servers="$1" manifest="$2" prev="${3:-$2}"
  local cb; cb="$(claude_bin)"
  # unchanged AND no pending legacy cleanup -> nothing to do (P1c: don't skip legacy consumption)
  if [ -f "$manifest" ] && { [ "$prev" = "$manifest" ] || [ ! -f "$prev" ]; } && \
     python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))==json.loads(sys.argv[2]) else 1)' \
        "$manifest" "$servers"; then
    log "MCP servers unchanged"; return 0
  fi
  if [ -f "$prev" ]; then                # remove exactly what the previous manifest managed
    python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1])).keys()))' "$prev" \
      | while read -r name; do [ -n "$name" ] && "$cb" mcp remove --scope user "$name" >/dev/null 2>&1 || true; done
  fi
  echo "$servers" | python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin).keys()))' \
    | while read -r name; do
        [ -z "$name" ] && continue
        one="$(echo "$servers" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)[sys.argv[1]]))' "$name")"
        "$cb" mcp remove --scope user "$name" >/dev/null 2>&1 || true
        "$cb" mcp add-json --scope user "$name" "$one"
      done
  mkdir -p "$(dirname "$manifest")"
  (umask 077; printf '%s' "$servers" > "$manifest"); chmod 600 "$manifest"
  [ "$prev" != "$manifest" ] && [ -f "$prev" ] && rm -f "$prev"   # consume legacy manifest
  log "MCP servers reconciled → $manifest"
}
