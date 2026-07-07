#!/usr/bin/env bash
# Claude Code statusLine — light-theme friendly. Reads the status JSON on stdin.
# Parses with python3 (no jq dependency). Fields per Claude Code 2.1.x contract.
in="$(cat)"
parsed="$(printf '%s' "$in" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
def obj(x):
    return x if isinstance(x, dict) else {}
m = obj(d.get("model")).get("display_name") or "?"
cur = obj(d.get("workspace")).get("current_dir") or d.get("cwd") or ""
pct = obj(d.get("context_window")).get("used_percentage")
pct = pct if isinstance(pct, (int, float)) else None
eff = obj(d.get("effort")).get("level") or ""
print("\t".join([str(m), str(cur) if cur else "-", str(pct) if pct is not None else "-", str(eff) if eff else "-"]))
')"
IFS=$'\t' read -r MODEL DIR PCT EFFORT <<<"$parsed"

base="${DIR##*/}"; [ -z "$base" ] && base="$DIR"

branch=""
if [ -n "$DIR" ] && b="$(git -C "$DIR" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
  dirty=""; [ -n "$(git -C "$DIR" --no-optional-locks status --porcelain 2>/dev/null)" ] && dirty="*"
  branch=" ${b}${dirty}"
fi

ctx=""
if [ "$PCT" != "-" ]; then
  p="${PCT%%.*}"; case "$p" in ''|*[!0-9]*) p=0 ;; esac
  col=$'\033[32m'; [ "$p" -ge 70 ] 2>/dev/null && col=$'\033[33m'; [ "$p" -ge 90 ] 2>/dev/null && col=$'\033[31m'
  ctx="  ${col}ctx ${p}%"$'\033[0m'
fi

eff=""; [ "$EFFORT" != "-" ] && [ -n "$EFFORT" ] && eff=" · ${EFFORT}"

# profile badge: $1 wins, else derive from CLAUDE_CONFIG_DIR; sanitize hard
prof="${1:-}"
if [ -z "$prof" ]; then
  d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; b="${d##*/}"
  case "$b" in
    .claude)   prof="vanilla" ;;
    .claude-*) prof="${b#.claude-}" ;;
    *)         prof="$b" ;;
  esac
fi
prof="$(printf '%s' "$prof" | tr -cd 'A-Za-z0-9_-' | cut -c1-16)"; [ -z "$prof" ] && prof="unknown"
case "$prof" in
  vanilla) pcol=$'\033[1;36m' ;;
  super)   pcol=$'\033[1;35m' ;;
  *)       pcol=$'\033[1;33m' ;;
esac
badge="${pcol}[${prof}]"$'\033[0m'" "

# badge (data) then cyan model, blue dir, magenta branch; ctx passed as DATA (%s), never as format
printf '%s\033[36m%s\033[0m \033[34m%s\033[0m\033[35m%s\033[0m%s\033[2m%s\033[0m\n' \
  "$badge" "$MODEL" "$base" "$branch" "$ctx" "$eff"
