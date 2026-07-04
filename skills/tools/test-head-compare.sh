#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
export CLAUDEFILES_STATE_DIR="$h/.config/claudefiles"; mkdir -p "$CLAUDEFILES_STATE_DIR"
ran="$h/ran"; run_cb() { echo x >> "$ran"; }
source "$cf/lib/apply-if-changed.sh"
apply_if_changed "AAA" run_cb; [ -f "$ran" ] || { echo FAIL first; exit 1; }   # first time: runs
apply_if_changed "AAA" run_cb; [ "$(wc -l < "$ran")" -eq 1 ] || { echo FAIL nochange; exit 1; } # same HEAD: no-op
apply_if_changed "BBB" run_cb; [ "$(wc -l < "$ran")" -eq 2 ] || { echo FAIL changed; exit 1; }  # new HEAD: runs
echo "PASS test-head-compare"
