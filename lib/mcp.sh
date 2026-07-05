# mcp.sh — reconcile user-scope MCP servers against a managed manifest.
# The manifest stores the FULL desired {name: config} dict (not just names), so a
# changed PAT/api-key is detected too, and an unchanged set is a genuine no-op.
_MCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MCP_MANIFEST() { echo "${CLAUDEFILES_CONFIG_DIR:-$HOME/.config/claudefiles}/managed-mcp.json"; }
mcp_apply() {
  local cb; cb="$(claude_bin)"
  local servers; servers="$(python3 "$_MCP_DIR/../claude/mcp/build_servers.py" "$(config_path)")"
  local manifest; manifest="$(_MCP_MANIFEST)"
  # call-idempotent: desired == last-applied -> touch nothing (finding 7)
  if [ -f "$manifest" ] && \
     python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))==json.loads(sys.argv[2]) else 1)' \
        "$manifest" "$servers"; then
    log "MCP servers unchanged"; return 0
  fi
  # remove exactly what we managed last time (manifest keys; never a prefix sweep)
  if [ -f "$manifest" ]; then
    python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1])).keys()))' "$manifest" \
      | while read -r name; do [ -n "$name" ] && "$cb" mcp remove --scope user "$name" >/dev/null 2>&1 || true; done
  fi
  # add current set
  echo "$servers" | python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin).keys()))' \
    | while read -r name; do
        [ -z "$name" ] && continue
        one="$(echo "$servers" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)[sys.argv[1]]))' "$name")"
        "$cb" mcp remove --scope user "$name" >/dev/null 2>&1 || true
        "$cb" mcp add-json --scope user "$name" "$one"
      done
  # rewrite manifest with the full desired dict
  mkdir -p "$(dirname "$manifest")"
  (umask 077; printf '%s' "$servers" > "$manifest")
  chmod 600 "$manifest"
  log "MCP servers reconciled"
}
