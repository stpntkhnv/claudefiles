#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
# fake pacman/sudo so the deps phase can never mutate the real system: if any phase shelled out
# to pacman/sudo it would append to $PACLOG, and the assertion near the end would fail. What
# this proves: a full non-interactive (ASSUME_TTY=0) run of setup.sh is a clean no-op — no phase
# invokes pacman/sudo. NOTE: on a fully-provisioned box every dep is already present, so
# deps_apply never even reaches _offer_install here; the branch-level guarantee that a *missing*
# dep under no-TTY prints a manual command and never shells out is proven directly by
# test-deps.sh case D (missing node/npx on an isolated PATH + ASSUME_TTY=0 -> empty PACLOG).
# Only the SECOND run's PACLOG is asserted (it is truncated at "only the SECOND run" below).
export PACLOG="$h/pac.log"; : > "$PACLOG"
cat > "$h/bin/pacman" <<'EOF'
#!/usr/bin/env bash
printf 'pacman %s\n' "$*" >> "$PACLOG"
exit 0
EOF
cat > "$h/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$PACLOG"
exec "$@"
EOF
chmod +x "$h/bin/pacman" "$h/bin/sudo"; hash -r 2>/dev/null || true
# seed non-interactive config so no prompt is needed
mkdir -p "$h/.config/claudefiles"
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags": {"context7":true,"playwright":true,"azure_mcp":false,"ado":false,"dotnet_skills":true,"codex_review":true,"codex_plugin":false},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
EOF
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive
cp "$h/.claude/settings.json" "$h/first.json"
cp "$h/.claude/CLAUDE.md" "$h/first-claudemd.md"
manifest="$h/.config/claudefiles/managed-mcp.json"; cp "$manifest" "$h/first-manifest.json"
: > "$CLAUDE_FAKE_LOG"                       # capture only the SECOND run's claude calls
: > "$PACLOG"                                # and only the SECOND run's pacman/sudo calls
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive
diff "$h/first.json" "$h/.claude/settings.json" || { echo "FAIL settings not idempotent"; exit 1; }
diff "$h/first-claudemd.md" "$h/.claude/CLAUDE.md" || { echo "FAIL CLAUDE.md not idempotent"; exit 1; }
diff "$h/first-manifest.json" "$manifest"       || { echo "FAIL manifest not idempotent"; exit 1; }
# 2nd run must not re-install the plugin or re-add MCP (stateful fake reflects prior state, finding 7)
grep -q "plugin install" "$CLAUDE_FAKE_LOG" && { echo "FAIL reinstalled plugin on 2nd run"; exit 1; }
grep -q "mcp add-json"    "$CLAUDE_FAKE_LOG" && { echo "FAIL re-added MCP on 2nd run"; exit 1; }
# no phase shelled out to pacman/sudo on the 2nd run (clean no-op; the missing-dep/no-TTY branch
# itself — print manual, never install — is proven in test-deps.sh case D, not re-proven here)
[ -s "$PACLOG" ] && { echo "FAIL deps phase invoked pacman/sudo in no-TTY"; cat "$PACLOG"; exit 1; }
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$h/.claude/settings.json"
echo "PASS test-setup-idempotent"
