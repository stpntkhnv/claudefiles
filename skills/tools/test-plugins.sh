#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
fails=0
chk()   { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }
hasln() { grep -qF -- "$1" "$2"; }
noln()  { ! grep -qF -- "$1" "$2"; }

source "$cf/skills/tools/lib/faketools.bash"
source "$cf/lib/common.sh"; source "$cf/lib/plugins.sh"

# --- superpowers ALWAYS, dotnet OFF: only superpowers is installed ---
setup_fixture_home >/dev/null; L="$(fake_claude_calls)"
plugins_apply false
chk "sp: marketplace added"      hasln "plugin marketplace add anthropics/claude-plugins-official" "$L"
chk "sp: plugin installed"       hasln "plugin install superpowers@claude-plugins-official" "$L"
chk "dotnet off: no dotnet mkt"  noln  "plugin marketplace add dotnet/skills" "$L"
chk "dotnet off: no dotnet inst" noln  "plugin install dotnet@dotnet-agent-skills" "$L"

# --- dotnet ON: both plugins installed ---
setup_fixture_home >/dev/null; L="$(fake_claude_calls)"
plugins_apply true
chk "dotnet on: sp installed"     hasln "plugin install superpowers@claude-plugins-official" "$L"
chk "dotnet on: dotnet mkt added" hasln "plugin marketplace add dotnet/skills" "$L"
chk "dotnet on: dotnet installed" hasln "plugin install dotnet@dotnet-agent-skills" "$L"

# --- idempotent: a second run with both already present installs nothing ---
: > "$CLAUDE_FAKE_LOG"
plugins_apply true
chk "rerun: no plugin install"    noln "plugin install" "$L"
chk "rerun: no marketplace add"   noln "plugin marketplace add" "$L"

# --- substring collision must NOT count as installed (finding 9) ---
setup_fixture_home >/dev/null; L="$(fake_claude_calls)"
printf '%s\n' "superpowers@claude-plugins-official-x" > "$CLAUDE_FAKE_STATE/plugins"
plugins_apply false
chk "collision: superpowers still installed" hasln "plugin install superpowers@claude-plugins-official" "$L"

# --- a failing `claude ... list` (non-zero) still installs; no abort ---
h2="$(mktemp -d)"; mkdir -p "$h2/bin"; export HOME="$h2"
INSTLOG="$h2/inst.log"; : > "$INSTLOG"; export INSTLOG
cat > "$h2/bin/claude" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "plugin list"|"plugin marketplace") exit 1 ;;                       # list ops FAIL
  "plugin install") printf 'install %s\n' "$3" >> "$INSTLOG"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$h2/bin/claude"; export PATH="$h2/bin:$PATH"; hash -r 2>/dev/null || true
( set -e; plugins_apply false ); rc=$?
chk "failing-list: plugins_apply returns 0 under set -e"  [ "$rc" -eq 0 ]
chk "failing-list: superpowers install still attempted"   hasln "install superpowers@claude-plugins-official" "$INSTLOG"

# codex_plugin on -> marketplace add + install attempted
setup_fixture_home >/dev/null; L="$(fake_claude_calls)"
plugins_apply false true
chk "codex on: marketplace added" hasln "plugin marketplace add openai/codex-plugin-cc" "$L"
chk "codex on: plugin installed"  hasln "plugin install codex@openai-codex" "$L"
# codex_plugin off -> not attempted
setup_fixture_home >/dev/null; L="$(fake_claude_calls)"
plugins_apply false false
chk "codex off: no codex install" noln "plugin install codex@openai-codex" "$L"

[ "$fails" -eq 0 ] && echo "PASS test-plugins" || { echo "SOME test-plugins CASES FAILED"; exit 1; }
