#!/usr/bin/env bash
# smoke-gstack.sh — verify the REAL upstream installer against a throwaway profile dir.
# Needs network and bun; skips loudly (exit 0) when either is absent, like the other smokes.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
fails=0
chk() { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }

command -v bun >/dev/null 2>&1 || { echo "SKIP smoke-gstack (no bun)"; exit 0; }
git ls-remote --exit-code https://github.com/garrytan/gstack.git HEAD >/dev/null 2>&1 \
  || { echo "SKIP smoke-gstack (upstream unreachable)"; exit 0; }

source "$cf/lib/common.sh"; source "$cf/lib/gstack.sh"
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
