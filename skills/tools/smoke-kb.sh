#!/usr/bin/env bash
set -uo pipefail
[ "${CLAUDEFILES_KB_SMOKE:-0}" = 1 ] || { echo "SKIP smoke-kb (opt-in: CLAUDEFILES_KB_SMOKE=1; makes live model calls)"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/lib/common.sh"; source "$cf/lib/config.sh"; source "$cf/lib/kb.sh"
command -v claude >/dev/null 2>&1 || { echo "SKIP smoke-kb (claude not on PATH)"; exit 0; }
[ "$(config_flag kb)" = true ] || { echo "SKIP smoke-kb (flags.kb is not enabled on this machine)"; exit 0; }
vault="$(kb_vault_path)"
repo="$(mktemp -d)"; wdir=""; home_dir=""
trap 'rm -rf "$repo" ${wdir:+"$wdir"} ${home_dir:+"$home_dir"}' EXIT
git init -q "$repo"
ask='Answer in exactly two lines. Line 1: the absolute path of your auto memory directory. Line 2: YES if your instructions include a knowledge base policy naming a vault, otherwise NO.'
out="$(cd "$repo" && timeout 180 claude -p "$ask" 2>&1 | tail -2)"
path="$(printf '%s\n' "$out" | head -1)"
rules="$(printf '%s\n' "$out" | tail -1)"
case "$path" in
  "$vault"/repositories/*) echo "ok repository memory ($path)" ;;
  *) echo "FAIL smoke-kb: expected a path under $vault/repositories, got: $path"; exit 1 ;;
esac
case "$rules" in
  *YES*) echo "ok profile rules load" ;;
  *) echo "FAIL smoke-kb: profile rules did not load, got: $rules"; exit 1 ;;
esac
ctx="$( (kb_context_name) 2>/dev/null )" || ctx=""
if [ -n "$ctx" ] && [ -d "$HOME/main" ]; then
  wdir="$(mktemp -d "$HOME/main/kb-smoke.XXXXXX")"
  name="$(basename "$wdir" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  home_dir="$vault/contexts/$ctx/projects/$name"
  out2="$(cd "$wdir" && timeout 180 claude -p "$ask" 2>&1 | tail -2 | head -1)"
  case "$out2" in
    "$home_dir"*) echo "ok project home ($out2)" ;;
    *) echo "FAIL smoke-kb: expected $home_dir, got: $out2"; exit 1 ;;
  esac
else
  echo "SKIP smoke-kb project home (kb.context is none or \$HOME/main is missing)"
fi
echo "PASS smoke-kb"
