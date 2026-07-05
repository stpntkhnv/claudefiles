#!/usr/bin/env bash
set -euo pipefail
cf="$(cd "$(dirname "$0")/../.." && pwd)"
if git -C "$cf" ls-files | grep -Ei 'secrets\.json|managed-mcp\.json|last-applied-head|\.env$'; then
  echo "FAIL: secret-bearing path tracked"; exit 1; fi
echo "PASS test-secrets-not-tracked"
