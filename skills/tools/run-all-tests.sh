#!/usr/bin/env bash
# Run every skills/tools/test-*.sh and report a summary. Exit non-zero if any fail.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

fail=0
for t in "$here"/test-*.sh; do
  name="$(basename "$t")"
  echo "=== $name ==="
  if bash "$t"; then
    :
  else
    echo "FAIL: $name (exit $?)"
    fail=1
  fi
  echo
done

for t in "$here"/smoke-*.sh; do
  [ -e "$t" ] || continue
  name="$(basename "$t")"
  echo "=== $name ==="
  bash "$t" || { echo "FAIL: $name (exit $?)"; fail=1; }
  echo
done

if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
fi
exit "$fail"
