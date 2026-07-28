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

echo "PASS test-clean"
