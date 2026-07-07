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
# type-confused fields must not print a python traceback (exit 0 already covered above)
err="$(printf '%s' '{"model":"Opus","cwd":"/tmp/x"}' | bash "$sl" 2>&1 1>/dev/null)"
echo "$err" | grep -qi "Traceback" && { echo "FAIL traceback-on-type-confusion: $err"; exit 1; }
# format-injection: a %s-laden percentage value must not corrupt the line or eat the effort field
out="$(printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":"50%s%s"},"effort":{"level":"high"}}' | bash "$sl")"
echo "$out" | grep -q "high"   || { echo "FAIL effort-eaten-by-injection: $out"; exit 1; }
echo "$out" | grep -q "50%s"   && { echo "FAIL raw-injection-leaked: $out"; exit 1; }
echo "$out" | grep -q "ctx"    && { echo "FAIL ctx-rendered-for-invalid-pct: $out"; exit 1; }
# a normal numeric percentage still renders NN%
printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42}}' | bash "$sl" | grep -q "42%" || { echo "FAIL normal-pct-broken"; exit 1; }

# --- profile badge: explicit arg wins over env ---
j='{"model":{"display_name":"Opus"},"cwd":"/tmp/x"}'
out="$(printf '%s' "$j" | bash "$sl" super)"
echo "$out" | grep -q "\[super\]"   || { echo "FAIL no-super-badge-arg: $out"; exit 1; }
out="$(printf '%s' "$j" | bash "$sl" vanilla)"
echo "$out" | grep -q "\[vanilla\]" || { echo "FAIL no-vanilla-badge-arg: $out"; exit 1; }

# --- profile badge: CLAUDE_CONFIG_DIR fallback when no arg ---
out="$(printf '%s' "$j" | CLAUDE_CONFIG_DIR="$HOME/.claude-super" bash "$sl")"
echo "$out" | grep -q "\[super\]"   || { echo "FAIL env-super-badge: $out"; exit 1; }
out="$(printf '%s' "$j" | CLAUDE_CONFIG_DIR="$HOME/.claude" bash "$sl")"
echo "$out" | grep -q "\[vanilla\]" || { echo "FAIL env-vanilla-badge: $out"; exit 1; }
out="$(printf '%s' "$j" | env -u CLAUDE_CONFIG_DIR bash "$sl")"
echo "$out" | grep -q "\[vanilla\]" || { echo "FAIL unset-vanilla-badge: $out"; exit 1; }
out="$(printf '%s' "$j" | CLAUDE_CONFIG_DIR="$HOME/.claude-work" bash "$sl")"
echo "$out" | grep -q "\[work\]"    || { echo "FAIL env-work-badge: $out"; exit 1; }

# --- sanitize: control/ANSI content in the config-dir name cannot leak ---
out="$(printf '%s' "$j" | CLAUDE_CONFIG_DIR="$HOME/.claude-$(printf 'a\033[31mb')" bash "$sl")"
stripped="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
first="${stripped%% *}"
echo "$first" | grep -Eq '^\[[A-Za-z0-9_-]+\]$' || { echo "FAIL badge-not-sanitized: $first"; exit 1; }

# --- placement: badge is the very first printable token ---
out="$(printf '%s' "$j" | bash "$sl" super)"
stripped="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
[ "${stripped%% *}" = "[super]" ] || { echo "FAIL badge-not-leftmost: $stripped"; exit 1; }

echo "PASS test-statusline"
