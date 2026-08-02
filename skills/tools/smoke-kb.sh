#!/usr/bin/env bash
# smoke-kb.sh — the ONE thing the fixture suite cannot prove: the real CLI resolves its memory
# directory inside the vault and loads this profile's kb rule. Costs a live model call, so it runs
# only when asked.
set -uo pipefail
[ "${CLAUDEFILES_KB_SMOKE:-0}" = 1 ] || { echo "SKIP smoke-kb (opt-in: CLAUDEFILES_KB_SMOKE=1; makes one live model call)"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/lib/common.sh"; source "$cf/lib/config.sh"; source "$cf/lib/kb.sh"
command -v claude >/dev/null 2>&1 || { echo "SKIP smoke-kb (claude not on PATH)"; exit 0; }
[ "$(config_flag kb)" = true ] || { echo "SKIP smoke-kb (flags.kb is not enabled on this machine)"; exit 0; }
vault="$(kb_vault_path)"
repo="$(mktemp -d)"; trap 'rm -rf "$repo"' EXIT
git init -q "$repo"
ask='Answer in exactly two lines. Line 1: the absolute path of your auto memory directory. Line 2: YES if your instructions include a knowledge base policy naming a vault, otherwise NO.'
out="$(cd "$repo" && timeout 180 claude -p "$ask" 2>&1 | tail -2)"
path="$(printf '%s\n' "$out" | head -1)"
rules="$(printf '%s\n' "$out" | tail -1)"
case "$path" in
  "$vault"/projects/*/memory/*) echo "ok memory dir ($path)" ;;
  *) echo "FAIL smoke-kb: expected a path under $vault, got: $path"; exit 1 ;;
esac
# The umbrella wiring is provable only live as well: rules are collected up the tree from cwd,
# and no fixture test exercises the real collector.
ctx="$( (kb_context_name) 2>/dev/null )" || ctx=""
if [ -n "$ctx" ] && [ -L "$HOME/main/.claude/rules/context-index.md" ]; then
  wdir="$(mktemp -d "$HOME/main/.kb-smoke.XXXXXX")"
  trap 'rm -rf "$repo" "$wdir"' EXIT
  ask2='Answer YES or NO in one line: do your loaded rules include an index of a work context (wired via a file named context-index)?'
  out2="$(cd "$wdir" && timeout 180 claude -p "$ask2" 2>&1 | tail -1)"
  case "$out2" in
    *YES*) echo "ok context umbrella rule loads" ;;
    *) echo "FAIL smoke-kb: context-index rule did not load under \$HOME/main, got: $out2"; exit 1 ;;
  esac
else
  echo "SKIP smoke-kb umbrella check (kb.context is none or \$HOME/main is not wired)"
fi
# The second line is the only check that the profile-scope rules (and with them the symlinked index)
# actually load: every fixture test runs against a fake CLI that reads no instructions at all.
case "$rules" in
  *YES*) echo "PASS smoke-kb" ;;
  *) echo "FAIL smoke-kb: profile rules did not load, got: $rules"; exit 1 ;;
esac
