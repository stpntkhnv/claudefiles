#!/usr/bin/env bash
# smoke-gstack.sh — verify the REAL upstream installer against a throwaway profile dir.
# OPT-IN: unlike the other smokes this one is not cheap. The upstream installer runs `bun install`
# and `bunx playwright install chromium`, which pulls ~150 MB, grows the throwaway profile to
# ~1.5 GB, and has been observed stalling mid-download with no progress for 12h. That cannot sit in
# the default suite, so it runs only when asked; CLAUDEFILES_GSTACK_TIMEOUT bounds a stall.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
fails=0
chk() { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }

[ "${CLAUDEFILES_GSTACK_SMOKE:-0}" = "1" ] \
  || { echo "SKIP smoke-gstack (opt-in: CLAUDEFILES_GSTACK_SMOKE=1; downloads ~150 MB)"; exit 0; }
command -v bun >/dev/null 2>&1 || { echo "SKIP smoke-gstack (no bun)"; exit 0; }
git ls-remote --exit-code https://github.com/garrytan/gstack.git HEAD >/dev/null 2>&1 \
  || { echo "SKIP smoke-gstack (upstream unreachable)"; exit 0; }

source "$cf/lib/common.sh"; source "$cf/lib/gstack.sh"
: "${CLAUDEFILES_GSTACK_TIMEOUT:=900}"; export CLAUDEFILES_GSTACK_TIMEOUT
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export CLAUDEFILES_TARGET="$SB/.claude-g"
before="$(ls -1 "$HOME/.claude/skills" 2>/dev/null | sort)"

gstack_apply; rc=$?
chk "real install returns 0"       [ "$rc" -eq 0 ]
chk "clone present"                [ -d "$CLAUDEFILES_TARGET/skills/gstack/.git" ]
chk "marker written"               [ -s "$CLAUDEFILES_TARGET/.gstack-setup-head" ]
chk "skills linked in the profile" bash -c 'ls -1 "$1/skills" | grep -qE "^gstack"' _ "$CLAUDEFILES_TARGET"
chk "office-hours skill reachable" bash -c 'ls -1 "$1/skills" | grep -q "office-hours"' _ "$CLAUDEFILES_TARGET"

after="$(ls -1 "$HOME/.claude/skills" 2>/dev/null | sort)"
chk "real ~/.claude/skills untouched" [ "$before" = "$after" ]

marker_before="$(cat "$CLAUDEFILES_TARGET/.gstack-setup-head")"
listing_before="$(ls -1 "$CLAUDEFILES_TARGET/skills" | sort)"
gstack_apply; rc=$?
chk "second run returns 0"         [ "$rc" -eq 0 ]
chk "second run leaves the marker"  [ "$(cat "$CLAUDEFILES_TARGET/.gstack-setup-head")" = "$marker_before" ]
chk "second run leaves the skills"  [ "$(ls -1 "$CLAUDEFILES_TARGET/skills" | sort)" = "$listing_before" ]

[ "$fails" -eq 0 ] && echo "PASS smoke-gstack" || { echo "SOME smoke-gstack CASES FAILED"; exit 1; }
