#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
sl="$cf/claude/statusline/statusline.sh"
[ -x "$sl" ] || { echo "FAIL not-executable"; exit 1; }
json='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp/foo-bar-proj"},"context_window":{"used_percentage":42},"effort":{"level":"xhigh"}}'
out="$(printf '%s' "$json" | bash "$sl")"
echo "$out" | grep -q "Opus"       || { echo "FAIL no-model: $out"; exit 1; }
echo "$out" | grep -q "foo-bar-proj" || { echo "FAIL no-dir: $out"; exit 1; }
echo "$out" | grep -q "42%"        || { echo "FAIL no-ctx: $out"; exit 1; }
# missing optional fields must not crash and must exit 0
printf '%s' '{"model":{"display_name":"Sonnet"},"cwd":"/tmp/x"}' | bash "$sl" >/dev/null || { echo "FAIL crashed-on-sparse"; exit 1; }
echo "PASS test-statusline"
