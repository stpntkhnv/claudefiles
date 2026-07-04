# faketools.bash — test scaffolding: fixture HOME + a STATEFUL fake `claude` CLI.
# It logs every invocation (so tests can assert the commands setup.sh issues) AND
# remembers installed plugins / added marketplaces / added MCP servers, reflecting
# them back in `list` output — so a second setup run is a genuine no-op (finding 7).
setup_fixture_home() {
  local h; h="$(mktemp -d)"
  mkdir -p "$h/.claude" "$h/.config"
  export HOME="$h"
  export CLAUDE_FAKE_LOG="$h/.claude-calls.log"; : > "$CLAUDE_FAKE_LOG"
  export CLAUDE_FAKE_STATE="$h/.claude-state"; mkdir -p "$CLAUDE_FAKE_STATE"
  : > "$CLAUDE_FAKE_STATE/plugins"; : > "$CLAUDE_FAKE_STATE/marketplaces"; : > "$CLAUDE_FAKE_STATE/mcp"
  local bin="$h/bin"; mkdir -p "$bin"
  cat > "$bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CLAUDE_FAKE_LOG"
S="$CLAUDE_FAKE_STATE"
case "$1 $2" in
  "plugin list")        cat "$S/plugins" 2>/dev/null ;;
  "plugin marketplace")                                   # add <name> | list
    if [ "$3" = "add" ];  then printf '%s\n' "$4" >> "$S/marketplaces"
    elif [ "$3" = "list" ]; then cat "$S/marketplaces" 2>/dev/null; fi ;;
  "plugin install")     printf '%s\n' "$3" >> "$S/plugins" ;;
  "mcp list")           cat "$S/mcp" 2>/dev/null ;;
  "mcp add-json")       printf '%s\n' "$5" >> "$S/mcp" ;;   # mcp add-json --scope user NAME JSON
  "mcp remove")                                            # mcp remove --scope user NAME
    grep -vxF "$5" "$S/mcp" > "$S/mcp.tmp" 2>/dev/null || true; mv "$S/mcp.tmp" "$S/mcp" 2>/dev/null || true ;;
  *) : ;;
esac
exit 0
EOF
  chmod +x "$bin/claude"
  export PATH="$bin:$PATH"
  echo "$h"
}
fake_claude_calls() { echo "$CLAUDE_FAKE_LOG"; }
