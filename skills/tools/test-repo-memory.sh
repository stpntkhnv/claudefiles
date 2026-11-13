#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
python3 "$here/test_repo_memory.py"
python3 "$here/test_kb_homes.py"
