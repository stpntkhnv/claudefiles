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
# Profile g is provisioned for real here: a local bare repo stands in for the gstack upstream and
# a fake `bun` satisfies the installer's hard requirement, so no network and nothing is installed.
# Without this, NO test ran recipe_g through setup.sh — dropping `gstack` from setup.sh's module
# list would have broken nothing in the suite (gstack_apply would be command-not-found, recipe_g
# would fail the profile, setup.sh would exit 1 and this test would die on its first run).
GW="$(mktemp -d)"; GBP="$(mktemp -d)"; GB="$GBP/gstack.git"
trap 'rm -rf "$GW" "$GBP"' EXIT
git init -q -b main "$GW"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GW/setup"; chmod +x "$GW/setup"; echo v1 > "$GW/VERSION"
git -C "$GW" add -A
git -C "$GW" -c user.email=t@t -c user.name=t commit -qm init
git clone -q --bare "$GW" "$GB"
export CLAUDEFILES_GSTACK_REPO="file://$GB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$h/bin/bun"; chmod +x "$h/bin/bun"; hash -r 2>/dev/null || true
# seed non-interactive config so no prompt is needed
mkdir -p "$h/.config/claudefiles"
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags": {"profile_super":true,"profile_gstack":true,"context7":true,"playwright":true,"azure_mcp":false,"ado":false,"dotnet_skills":true,"codex_review":true,"codex_plugin":false,"linear":false},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
EOF
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive
cp "$h/.claude/settings.json" "$h/first.json"
cp "$h/.claude-super/settings.json" "$h/first-super.json"
cp "$h/.claude/CLAUDE.md" "$h/first-claudemd.md"
cp "$h/.claude-super/CLAUDE.md" "$h/first-super-claudemd.md"
manifest="$h/.config/claudefiles/managed-mcp.vanilla.json"; cp "$manifest" "$h/first-manifest.json"
cp -a "$h/.claude-g" "$h/first-g"
g_head="$(git -C "$h/.claude-g/skills/gstack" rev-parse HEAD)"
: > "$CLAUDE_FAKE_LOG"                       # capture only the SECOND run's claude calls
: > "$PACLOG"                                # and only the SECOND run's pacman/sudo calls
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive
diff "$h/first.json" "$h/.claude/settings.json" || { echo "FAIL settings not idempotent"; exit 1; }
diff "$h/first-super.json" "$h/.claude-super/settings.json" || { echo "FAIL super settings not idempotent"; exit 1; }
diff "$h/first-claudemd.md" "$h/.claude/CLAUDE.md" || { echo "FAIL CLAUDE.md not idempotent"; exit 1; }
diff "$h/first-super-claudemd.md" "$h/.claude-super/CLAUDE.md" || { echo "FAIL super CLAUDE.md not idempotent"; exit 1; }
diff "$h/first-manifest.json" "$manifest"       || { echo "FAIL manifest not idempotent"; exit 1; }
# 2nd run must not re-install the plugin or re-add MCP (stateful fake reflects prior state, finding 7)
grep -q "plugin install" "$CLAUDE_FAKE_LOG" && { echo "FAIL reinstalled plugin on 2nd run"; exit 1; }
grep -q "mcp add-json"    "$CLAUDE_FAKE_LOG" && { echo "FAIL re-added MCP on 2nd run"; exit 1; }
# no phase shelled out to pacman/sudo on the 2nd run (clean no-op; the missing-dep/no-TTY branch
# itself — print manual, never install — is proven in test-deps.sh case D, not re-proven here)
[ -s "$PACLOG" ] && { echo "FAIL deps phase invoked pacman/sudo in no-TTY"; cat "$PACLOG"; exit 1; }
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$h/.claude/settings.json"

# --- profile g: the headline invariant, whole-directory. The clone itself is excluded because
# `git reset --hard` appends a reflog entry on every run; its revision and the marker are asserted
# directly instead, which is what idempotency of the clone actually means.
diff -r --no-dereference --exclude=gstack "$h/first-g" "$h/.claude-g" \
  || { echo "FAIL g profile not idempotent"; exit 1; }
[ "$(git -C "$h/.claude-g/skills/gstack" rev-parse HEAD)" = "$g_head" ] || { echo "FAIL g clone moved"; exit 1; }
[ "$(cat "$h/.claude-g/.gstack-setup-head")" = "$g_head" ] || { echo "FAIL g marker != clone HEAD"; exit 1; }
[ -x "$h/.local/bin/claude-g" ] || { echo "FAIL g wrapper missing"; exit 1; }
[ -e "$h/.claude/skills/gstack" ] && { echo "FAIL gstack leaked into vanilla"; exit 1; }
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert list(d)==["context7"],d' \
  "$h/.config/claudefiles/managed-mcp.g.json"
# the vision roles are pinned to their TEXTS: both role strings contain "claudefiles:vision" and
# "docs/vision/", so grepping those would let a producer/consumer swap through unnoticed
grep -q "owns the VISION stage" "$h/.claude-g/CLAUDE.md" || { echo "FAIL g is not the vision producer"; exit 1; }
grep -q "turn the vision into a specification" "$h/.claude-super/CLAUDE.md" || { echo "FAIL super is not the vision consumer"; exit 1; }
grep -q "turn the vision into a specification" "$h/.claude-g/CLAUDE.md" && { echo "FAIL g carries the consumer text"; exit 1; }
grep -q "owns the VISION stage" "$h/.claude-super/CLAUDE.md" && { echo "FAIL super carries the producer text"; exit 1; }

# --- clean install, end to end through the real setup.sh.
# Plant exactly the junk a clean install exists to remove, then answer every question the way the
# seeded secrets.json was configured: same answers -> byte-identical result, which is what makes
# the diffs below meaningful.
# Every SELECTED profile gets drift planted: asserting only vanilla would pass even if the wiring
# cleaned vanilla and silently skipped super and g.
mkdir -p "$h/.claude/skills/ges-esp" "$h/.claude/rules" \
         "$h/.claude-super/skills/ges-esp" "$h/.claude-g/skills/ges-esp"
printf 'STRAY' > "$h/.claude/skills/ges-esp/SKILL.md"
printf 'STRAY' > "$h/.claude-super/skills/ges-esp/SKILL.md"
printf 'STRAY' > "$h/.claude-g/skills/ges-esp/SKILL.md"
printf 'RULE'  > "$h/.claude/rules/context7.md"
printf 'BAK'   > "$h/.claude/settings.json.bak.20260101-000000"
python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d["junkKey"]=1;json.dump(d,open(p,"w"))' "$h/.claude/settings.json"
printf '\nhand-written line\n' >> "$h/.claude/CLAUDE.md"
printf 'CREDS' > "$h/.claude/.credentials.json"; printf 'HIST' > "$h/.claude/history.jsonl"
mkdir -p "$h/.claude/projects/keepme"
: > "$CLAUDE_FAKE_LOG"; : > "$PACLOG"
# answers: confirm word, super y, dotnet y, codex_review y, codex_plugin n, playwright y,
# azure n, ado n, gstack y, context7 y, context7 key (empty), linear n. Trailing blanks absorb
# any dep prompt that a non-provisioned box might raise AFTER the config phase.
printf 'clean\ny\ny\ny\nn\ny\nn\nn\ny\ny\n\nn\n\n\n\n' | \
  CLAUDEFILES_ASSUME_TTY=1 CLAUDEFILES_CLEAN=1 CLAUDEFILES_CLEAN_SKIP_NET=1 bash "$cf/setup.sh"

[ -e "$h/.claude/skills/ges-esp" ] && { echo "FAIL clean kept a stray skill"; exit 1; }
[ -e "$h/.claude-super/skills/ges-esp" ] && { echo "FAIL clean skipped the super profile"; exit 1; }
[ -e "$h/.claude-g/skills/ges-esp" ] && { echo "FAIL clean skipped the g profile"; exit 1; }
[ -e "$h/.claude/rules" ] && { echo "FAIL clean kept rules/"; exit 1; }
[ -e "$h/.claude/settings.json.bak.20260101-000000" ] && { echo "FAIL clean kept a settings backup"; exit 1; }
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert "junkKey" not in d,d' "$h/.claude/settings.json" \
  || { echo "FAIL clean kept an unknown settings key"; exit 1; }
grep -q 'hand-written line' "$h/.claude/CLAUDE.md" && { echo "FAIL clean kept hand-written CLAUDE.md text"; exit 1; }
[ "$(cat "$h/.claude/.credentials.json")" = CREDS ] || { echo "FAIL clean touched credentials"; exit 1; }
[ "$(cat "$h/.claude/history.jsonl")" = HIST ] || { echo "FAIL clean touched history"; exit 1; }
[ -d "$h/.claude/projects/keepme" ] || { echo "FAIL clean touched projects/"; exit 1; }
[ -s "$PACLOG" ] && { echo "FAIL clean run invoked pacman/sudo"; cat "$PACLOG"; exit 1; }
# the backup is the whole safety net: the stray must be recoverable from it
bdir="$(ls -d "$h/.config/claudefiles/clean-backups"/*/ | head -1)"
[ -f "$bdir/vanilla/skills/ges-esp/SKILL.md" ] || { echo "FAIL stray not in the clean backup"; exit 1; }
[ -f "$bdir/global/secrets.json" ] || { echo "FAIL answers not in the clean backup"; exit 1; }
# same answers as the seeded run -> the rebuilt config is byte-identical to the pre-clean one
diff "$h/first.json" "$h/.claude/settings.json" || { echo "FAIL clean rebuild differs from a normal run"; exit 1; }
diff "$h/first-claudemd.md" "$h/.claude/CLAUDE.md" || { echo "FAIL clean CLAUDE.md differs"; exit 1; }
# ...and a normal run right after a clean one is still a no-op
cp "$h/.claude/settings.json" "$h/post-clean.json"
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive
diff "$h/post-clean.json" "$h/.claude/settings.json" || { echo "FAIL not idempotent after clean"; exit 1; }
echo "PASS test-setup-idempotent"
