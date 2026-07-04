#!/usr/bin/env bash
# Tests for the SessionStart .NET-detection hook.
set -euo pipefail

HOOK="/home/stsiapan/devTools/claude/hooks/detect-dotnet.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -x "$HOOK" ] || fail "hook missing or not executable"

t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT

# 1. Positive: sln at depth 4 (root/a/b/c/svc.sln) is found
mkdir -p "$t/a/b/c"
touch "$t/a/b/c/svc.sln"
out="$(CLAUDE_PROJECT_DIR="$t" "$HOOK")"
echo "$out" | grep -q 'dotnet-router' || fail "sln at depth 4 not detected"

# 2. Negative: empty tree stays silent
rm "$t/a/b/c/svc.sln"
out="$(CLAUDE_PROJECT_DIR="$t" "$HOOK")"
[ -z "$out" ] || fail "empty tree produced output: $out"

# 3. Prune: csproj under node_modules is ignored
mkdir -p "$t/x/node_modules/junk"
touch "$t/x/node_modules/junk/fake.csproj"
out="$(CLAUDE_PROJECT_DIR="$t" "$HOOK")"
[ -z "$out" ] || fail "pruned node_modules leaked: $out"

# 4. Exit code is 0 in both cases
CLAUDE_PROJECT_DIR="$t" "$HOOK" >/dev/null || fail "non-zero exit on negative"

# 5. Speed on a real large tree: under 2 seconds
start=$(date +%s%N)
CLAUDE_PROJECT_DIR="/home/stsiapan/devTools" "$HOOK" >/dev/null
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
[ "$elapsed_ms" -lt 2000 ] || fail "hook too slow: ${elapsed_ms}ms"

echo "PASS: all hook tests"
