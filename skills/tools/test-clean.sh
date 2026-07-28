#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
# root ignores file modes, which would silently defeat the fail-closed and chmod assertions below
[ "$(id -u)" -eq 0 ] && { echo "SKIP test-clean (running as root)"; exit 0; }
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
for m in common config deps settings skills mcp claudemd plugins gstack profiles clean; do source "$cf/lib/$m.sh"; done
export CLAUDEFILES_CONFIG_DIR="$h/.config/claudefiles"; mkdir -p "$CLAUDEFILES_CONFIG_DIR"
export CLAUDEFILES_CLEAN_SKIP_NET=1

# --- clean_wanted: the gate. Nothing here may delete anything.
# no TTY, no force -> plain update (silent, no die)
if CLAUDEFILES_ASSUME_TTY=0 clean_wanted >/dev/null 2>&1; then echo "FAIL no-tty-wanted"; exit 1; fi
# no TTY + force -> die: wiping every answer with no way to re-enter them bricks the machine
if (CLAUDEFILES_ASSUME_TTY=0 CLAUDEFILES_CLEAN=1 clean_wanted) >/dev/null 2>&1; then
  echo "FAIL force-no-tty-should-die"; exit 1; fi
# TTY, declined
if printf 'n\n' | CLAUDEFILES_ASSUME_TTY=1 clean_wanted >/dev/null 2>&1; then echo "FAIL declined-still-wanted"; exit 1; fi
# TTY, y but the confirmation word is wrong -> declined
if printf 'y\nyes\n' | CLAUDEFILES_ASSUME_TTY=1 clean_wanted >/dev/null 2>&1; then echo "FAIL wrong-word-accepted"; exit 1; fi
# TTY, y + the word
printf 'y\nclean\n' | CLAUDEFILES_ASSUME_TTY=1 clean_wanted >/dev/null 2>&1 || { echo "FAIL confirmed-not-wanted"; exit 1; }
# force answers the y/N question only; the word is still required
printf 'clean\n' | CLAUDEFILES_ASSUME_TTY=1 CLAUDEFILES_CLEAN=1 clean_wanted >/dev/null 2>&1 || { echo "FAIL force-not-wanted"; exit 1; }
# the announcement names what survives, so the user can judge the blast radius
out="$(printf 'y\nclean\n' | CLAUDEFILES_ASSUME_TTY=1 clean_wanted 2>&1)"
printf '%s' "$out" | grep -qF '.credentials.json' || { echo "FAIL announce-missing-kept"; exit 1; }
printf '%s' "$out" | grep -qF 'settings.json'     || { echo "FAIL announce-missing-removed"; exit 1; }

# --- clean_preflight: hard gates, because a clean profile is rebuilt from the network
if (PATH="$h/empty-bin" clean_preflight) >/dev/null 2>&1; then echo "FAIL preflight-without-claude"; exit 1; fi
mkdir -p "$h/netbin"; printf '#!/usr/bin/env bash\nexit 1\n' > "$h/netbin/git"; chmod +x "$h/netbin/git"
if (PATH="$h/netbin:$PATH" CLAUDEFILES_CLEAN_SKIP_NET=0 clean_preflight) >/dev/null 2>&1; then
  echo "FAIL preflight-ignores-unreachable-github"; exit 1; fi
clean_preflight >/dev/null 2>&1 || { echo "FAIL preflight-rejects-good-env"; exit 1; }

# --- backup + global wipe
printf '{"flags":{"context7":true}}' > "$CLAUDEFILES_CONFIG_DIR/secrets.json"; chmod 600 "$CLAUDEFILES_CONFIG_DIR/secrets.json"
printf '{"context7":{}}' > "$CLAUDEFILES_CONFIG_DIR/managed-mcp.vanilla.json"
printf '{"context7":{}}' > "$CLAUDEFILES_CONFIG_DIR/managed-mcp.json"
clean_backup_open 20260728-000000 >/dev/null
b="$CLAUDEFILES_CLEAN_BACKUP"
[ -d "$b" ] || { echo "FAIL backup-dir-missing"; exit 1; }
[ "$(stat -c %a "$b")" = 700 ] || { echo "FAIL backup-dir-mode"; exit 1; }
clean_global >/dev/null
[ -e "$CLAUDEFILES_CONFIG_DIR/secrets.json" ] && { echo "FAIL secrets-survived"; exit 1; }
[ -e "$CLAUDEFILES_CONFIG_DIR/managed-mcp.vanilla.json" ] && { echo "FAIL manifest-survived"; exit 1; }
[ -e "$CLAUDEFILES_CONFIG_DIR/managed-mcp.json" ] && { echo "FAIL legacy-manifest-survived"; exit 1; }
[ -f "$b/global/secrets.json" ] || { echo "FAIL secrets-not-backed-up"; exit 1; }
[ "$(stat -c %a "$b/global/secrets.json")" = 600 ] || { echo "FAIL backup-secrets-mode"; exit 1; }
[ -f "$b/global/managed-mcp.vanilla.json" ] || { echo "FAIL manifest-not-backed-up"; exit 1; }

# fail-closed: a backup that cannot be written must abort BEFORE anything is deleted.
# The DESTINATION dir is what must be unwritable — chmod-ing the backup root would not do it,
# since global/ already exists and mkdir -p plus a write inside it would both still succeed.
printf '{"flags":{}}' > "$CLAUDEFILES_CONFIG_DIR/secrets.json"
chmod 500 "$b/global"
if (clean_global) >/dev/null 2>&1; then chmod 700 "$b/global"; echo "FAIL backup-not-fail-closed"; exit 1; fi
chmod 700 "$b/global"
[ -f "$CLAUDEFILES_CONFIG_DIR/secrets.json" ] || { echo "FAIL deleted-despite-backup-failure"; exit 1; }

# taking a missing source is a no-op, not a failure: absent files are the normal case
clean_backup_take "$CLAUDEFILES_CONFIG_DIR/nope.json" "global/nope.json" || { echo "FAIL take-missing-src"; exit 1; }
[ -e "$b/global/nope.json" ] && { echo "FAIL invented-backup"; exit 1; }

# --- clean_profile: the demolition itself
d="$h/.claude"
mkdir -p "$d/skills/ges-esp" "$d/skills/context7-mcp" "$d/skills/gstack/foo" \
         "$d/rules" "$d/agents" "$d/plugins/repos" "$d/projects/x" "$d/sessions"
printf 'STRAY' > "$d/skills/ges-esp/SKILL.md"
printf 'GSTACK' > "$d/skills/gstack/foo/SKILL.md"
printf '{"a":1}' > "$d/settings.json"
printf 'LOCAL' > "$d/settings.local.json"
printf 'BAK' > "$d/settings.json.bak.20260101-000000"
printf 'hand-written' > "$d/CLAUDE.md"
printf 'RULE' > "$d/rules/context7.md"
printf 'PLUG' > "$d/plugins/config.json"
printf 'CREDS' > "$d/.credentials.json"
printf 'HIST' > "$d/history.jsonl"
printf 'HEAD' > "$d/.gstack-setup-head"
python3 -c 'import json,sys;json.dump({"mcpServers":{"context7":{},"stray":{}},"oauthAccount":{"e":"x"}},open(sys.argv[1],"w"))' "$d/.claude.json"
# legacy ~/.claude.json: pre-CLAUDE_CONFIG_DIR layout, still carries mcpServers for the default profile
python3 -c 'import json,sys;json.dump({"mcpServers":{"old":{}},"oauthAccount":{"e":"x"},"projects":{"p":1}},open(sys.argv[1],"w"))' "$h/.claude.json"
chmod 600 "$h/.claude.json"

: > "$CLAUDE_FAKE_LOG"
( export CLAUDEFILES_TARGET="$d" CLAUDE_CONFIG_DIR="$d"; clean_profile vanilla ) >/dev/null \
  || { echo "FAIL clean_profile-vanilla-failed"; exit 1; }

for gone in settings.json settings.local.json settings.json.bak.20260101-000000 CLAUDE.md \
            skills plugins rules agents .gstack-setup-head; do
  [ -e "$d/$gone" ] && { echo "FAIL survived: $gone"; exit 1; }
done
for kept in .credentials.json history.jsonl projects/x sessions .claude.json; do
  [ -e "$d/$kept" ] || { echo "FAIL destroyed: $kept"; exit 1; }
done
# every user-scope server is dropped, not only the ones our manifest owns
grep -qF 'mcp remove --scope user context7' "$CLAUDE_FAKE_LOG" || { echo "FAIL mcp-ours-not-removed"; exit 1; }
grep -qF 'mcp remove --scope user stray'    "$CLAUDE_FAKE_LOG" || { echo "FAIL mcp-stray-not-removed"; exit 1; }
# legacy file: only mcpServers goes, everything else and the mode survive
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert "mcpServers" not in d,d;assert d["oauthAccount"]=={"e":"x"};assert d["projects"]=={"p":1}' "$h/.claude.json" \
  || { echo "FAIL legacy-surgery"; exit 1; }
[ "$(stat -c %a "$h/.claude.json")" = 600 ] || { echo "FAIL legacy-mode-changed"; exit 1; }
# backup: strays are recoverable, the multi-GB gstack clone is not copied
[ -f "$b/vanilla/skills/ges-esp/SKILL.md" ] || { echo "FAIL stray-not-backed-up"; exit 1; }
[ -f "$b/vanilla/CLAUDE.md" ] || { echo "FAIL claudemd-not-backed-up"; exit 1; }
[ -f "$b/vanilla/plugins/config.json" ] || { echo "FAIL plugins-not-backed-up"; exit 1; }
# a gstack dir OUTSIDE profile g is drift nobody reclones, so it must be recoverable
[ -f "$b/vanilla/skills/gstack/foo/SKILL.md" ] || { echo "FAIL gstack-outside-g-not-backed-up"; exit 1; }

# an already-clean directory is not an error: absent files are the normal steady state
( export CLAUDEFILES_TARGET="$d" CLAUDE_CONFIG_DIR="$d"; clean_profile vanilla ) >/dev/null \
  || { echo "FAIL clean_profile-not-idempotent"; exit 1; }

# profile g without bun: refuse and touch NOTHING — gstack_apply exits early without bun
# (gstack.sh:53), so wiping the clone we cannot reinstall is the one unrecoverable move.
gd="$h/.claude-g"; mkdir -p "$gd/skills/gstack"; printf 'HEAD' > "$gd/.gstack-setup-head"
printf '{"b":2}' > "$gd/settings.json"
_clean_have_bun() { return 1; }                 # shadows the real check, like test-profiles.sh does
if ( export CLAUDEFILES_TARGET="$gd" CLAUDE_CONFIG_DIR="$gd"; clean_profile g ) >/dev/null 2>&1; then
  echo "FAIL g-cleaned-without-bun"; exit 1; fi
[ -d "$gd/skills/gstack" ] || { echo "FAIL g-clone-removed-without-bun"; exit 1; }
[ -f "$gd/.gstack-setup-head" ] || { echo "FAIL g-marker-removed-without-bun"; exit 1; }
[ -f "$gd/settings.json" ] || { echo "FAIL g-settings-removed-without-bun"; exit 1; }
unset -f _clean_have_bun

# profile g whose configured gstack repo does not resolve: same refusal. clean_preflight probes
# github in general, which proves nothing about a pinned or self-hosted gstack, and the clone is
# the one artifact deliberately left out of the backup.
if ( export CLAUDEFILES_TARGET="$gd" CLAUDE_CONFIG_DIR="$gd" \
            CLAUDEFILES_CLEAN_SKIP_NET=0 CLAUDEFILES_GSTACK_REPO="file://$h/no-such-repo.git"
     clean_profile g ) >/dev/null 2>&1; then echo "FAIL g-cleaned-with-unreachable-gstack"; exit 1; fi
[ -d "$gd/skills/gstack" ] || { echo "FAIL g-clone-removed-with-unreachable-gstack"; exit 1; }

# fail-closed for a PROFILE, not only for the global wipe: if a backup copy dies mid-way, the
# profile must still be whole. Two passes (copy everything, then delete) are what guarantee it.
fd="$h/.claude-fc"; mkdir -p "$fd/skills/keep"
printf 'S' > "$fd/settings.json"; printf 'M' > "$fd/CLAUDE.md"; printf 'K' > "$fd/skills/keep/SKILL.md"
mkdir -p "$b/vanilla"; chmod 500 "$b/vanilla"
if ( export CLAUDEFILES_TARGET="$fd" CLAUDE_CONFIG_DIR="$fd"; clean_profile vanilla ) >/dev/null 2>&1; then
  chmod 700 "$b/vanilla"; echo "FAIL profile-clean-not-fail-closed"; exit 1; fi
chmod 700 "$b/vanilla"
[ -f "$fd/settings.json" ] || { echo "FAIL settings deleted despite a failed backup"; exit 1; }
[ -f "$fd/CLAUDE.md" ] || { echo "FAIL CLAUDE.md deleted despite a failed backup"; exit 1; }
[ -f "$fd/skills/keep/SKILL.md" ] || { echo "FAIL skills deleted despite a failed backup"; exit 1; }

echo "PASS test-clean"
