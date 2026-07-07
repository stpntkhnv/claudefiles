#!/usr/bin/env bash
# Claude Code statusLine — light-theme friendly. Reads the status JSON on stdin.
# Parses with python3 (no jq dependency). Fields per Claude Code 2.1.x contract.
in="$(cat)"
parsed="$(printf '%s' "$in" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
m = (d.get("model") or {}).get("display_name", "?")
w = d.get("workspace") or {}
cur = w.get("current_dir") or d.get("cwd") or ""
cw = d.get("context_window") or {}
pct = cw.get("used_percentage")
eff = (d.get("effort") or {}).get("level", "")
print("\t".join([m, cur if cur else "-", str(pct) if pct is not None else "-", eff or "-"]))
')"
IFS=$'\t' read -r MODEL DIR PCT EFFORT <<<"$parsed"

base="${DIR##*/}"; [ -z "$base" ] && base="$DIR"

branch=""
if b="$(git -C "$DIR" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
  dirty=""; [ -n "$(git -C "$DIR" --no-optional-locks status --porcelain 2>/dev/null)" ] && dirty="*"
  branch=" ${b}${dirty}"
fi

ctx=""
if [ "$PCT" != "-" ]; then
  p="${PCT%%.*}"; [ -z "$p" ] && p=0
  col=$'\033[32m'; [ "$p" -ge 70 ] 2>/dev/null && col=$'\033[33m'; [ "$p" -ge 90 ] 2>/dev/null && col=$'\033[31m'
  ctx="  ${col}ctx ${p}%%\033[0m"
fi

eff=""; [ "$EFFORT" != "-" ] && [ -n "$EFFORT" ] && eff=" · ${EFFORT}"

# cyan model, blue dir, magenta branch
printf '\033[36m%s\033[0m \033[34m%s\033[0m\033[35m%s\033[0m'"$ctx"'\033[2m%s\033[0m\n' \
  "$MODEL" "$base" "$branch" "$eff"
