#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for t in test_kb_vault test_kb_history test_kb_tasks test_kb_apply test_kb_review; do
  [ -f "$here/$t.py" ] && python3 "$here/$t.py"
done
echo "PASS test-kb-review"
