#!/usr/bin/env bash
# smoke-codex-review.sh — assert the REAL codex CLI still exposes the surface codex-review
# depends on. Contract only: help/version/login/doctor-parse. No network model-run. Self-skips
# when codex is absent, so it is safe inside run-all-tests.sh.
set -uo pipefail
if ! command -v codex >/dev/null 2>&1 || ! codex --version >/dev/null 2>&1; then
  echo "SKIP smoke-codex-review (no runnable codex)"; exit 0
fi
fails=0
chk() { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }
v="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
chk "codex >= 0.142.5 (got ${v:-none})" bash -c '[ "$(printf "0.142.5\n%s\n" "'"$v"'" | sort -V | head -1)" = "0.142.5" ]'
chk "codex exec exposes --ephemeral"              bash -c 'codex exec   --help 2>&1 | grep -q -- --ephemeral'
chk "codex exec exposes --skip-git-repo-check"    bash -c 'codex exec   --help 2>&1 | grep -q -- --skip-git-repo-check'
chk "codex exec exposes -o/--output-last-message" bash -c 'codex exec   --help 2>&1 | grep -q -- --output-last-message'
chk "codex exec exposes --cd"                     bash -c 'codex exec   --help 2>&1 | grep -q -- --cd || codex --help 2>&1 | grep -q -- --cd'
chk "codex review exposes --base"                 bash -c 'codex review --help 2>&1 | grep -q -- --base'
chk "codex login has a status subcommand"         bash -c 'codex login  --help 2>&1 | grep -qw status'
chk "codex doctor --json parses"                  bash -c 'timeout 20 codex doctor --json 2>/dev/null | python3 -c "import json,sys; json.load(sys.stdin)"'
[ "$fails" -eq 0 ] && echo "PASS smoke-codex-review" || { echo "SMOKE FAILED — codex CLI surface drifted"; exit 1; }
