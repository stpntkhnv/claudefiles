# faketools.bash — test scaffolding: fixture HOME + a STATEFUL fake `claude` CLI.
# It logs every invocation (so tests can assert the commands setup.sh issues) AND
# remembers installed plugins / added marketplaces / added MCP servers, reflecting
# them back in `list` output — so a second setup run is a genuine no-op (finding 7).
#
# USAGE: call it DIRECTLY so its exports reach your shell, then read $HOME:
#     setup_fixture_home >/dev/null; h="$HOME"
# Do NOT write  h="$(setup_fixture_home)"  — command substitution runs it in a
# subshell, so the HOME/PATH/CLAUDE_FAKE_* exports never reach the caller and the
# functions under test would touch your REAL ~/.claude.
setup_fixture_home() {
  local h; h="$(mktemp -d)"
  mkdir -p "$h/.claude" "$h/.config"
  export HOME="$h"
  # The claudefiles wrapper exports CLAUDE_CONFIG_DIR, so the suite may be run from inside a
  # non-default profile. A fixture must never inherit it: modules under test would write to
  # the developer's real profile dir instead of the fixture.
  unset CLAUDE_CONFIG_DIR
  export CLAUDE_FAKE_LOG="$h/.claude-calls.log"; : > "$CLAUDE_FAKE_LOG"
  export CLAUDE_FAKE_STATE="$h/.claude-state"; mkdir -p "$CLAUDE_FAKE_STATE"
  : > "$CLAUDE_FAKE_STATE/plugins"; : > "$CLAUDE_FAKE_STATE/marketplaces"; : > "$CLAUDE_FAKE_STATE/mcp"
  local bin="$h/bin"; mkdir -p "$bin"
  cat > "$bin/claude" <<'EOF'
#!/usr/bin/env bash
# mcp login is the only branch whose CLAUDE_CONFIG_DIR matters: the fake's state is one per
# fixture HOME, so without the dir a test cannot tell "logged in per selected profile" from
# "logged in three times into the default dir". Appending keeps every existing substring assert.
if [ "$1 $2" = "mcp login" ]; then
  echo "$* CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-}" >> "$CLAUDE_FAKE_LOG"
else
  echo "$*" >> "$CLAUDE_FAKE_LOG"
fi
S="$CLAUDE_FAKE_STATE"
case "$1 $2" in
  "plugin list")        cat "$S/plugins" 2>/dev/null ;;
  "plugin marketplace")                                   # add <name> | list
    if [ "$3" = "add" ];  then grep -qxF "$4" "$S/marketplaces" 2>/dev/null || printf '%s\n' "$4" >> "$S/marketplaces"
    elif [ "$3" = "list" ]; then cat "$S/marketplaces" 2>/dev/null; fi ;;
  "plugin install")     grep -qxF "$3" "$S/plugins" 2>/dev/null || printf '%s\n' "$3" >> "$S/plugins" ;;
  "mcp list")           cat "$S/mcp" 2>/dev/null ;;
  "mcp add-json")       grep -qxF "$5" "$S/mcp" 2>/dev/null || printf '%s\n' "$5" >> "$S/mcp" ;;   # add-json --scope user NAME JSON; dedup so re-add is a no-op
  "mcp remove")                                            # mcp remove --scope user NAME
    grep -vxF "$5" "$S/mcp" > "$S/mcp.tmp" 2>/dev/null || true; mv "$S/mcp.tmp" "$S/mcp" 2>/dev/null || true ;;
  "mcp get")            # outcomes: needs auth, connected, unrecognised status, no such server (non-zero)
    if grep -qxF "$3" "$S/mcp" 2>/dev/null; then
      printf '%s:\n  Scope: User config (available in all your projects)\n' "$3"
      case "${CLAUDE_FAKE_MCP_AUTH:-needs}" in
        ok)      printf '  Status: \xe2\x9c\x94 Connected\n' ;;
        unknown) printf '  Status: \xe2\x9c\x97 Failed to connect\n' ;;
        *)       printf '  Status: ! Needs authentication\n' ;;
      esac
    else
      printf 'No MCP server found with name: %s\n' "$3"; exit 1
    fi ;;
  "mcp login")          # logged above, including CLAUDE_CONFIG_DIR; nothing else to do
    : ;;
  *) : ;;
esac
exit 0
EOF
  chmod +x "$bin/claude"
  export PATH="$bin:$PATH"
  hash -r 2>/dev/null || true   # drop any cached real-claude path so the fake wins
  echo "$h"
}
fake_claude_calls() { echo "$CLAUDE_FAKE_LOG"; }
