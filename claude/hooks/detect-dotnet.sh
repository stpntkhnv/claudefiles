#!/usr/bin/env bash
# SessionStart hook: if the workspace tree contains .NET markers, inject a
# one-line reminder to use the dotnet-router skill. Silent otherwise.
# Multi-service layouts: solutions may sit several levels deep in many branches,
# so search to depth 6 with pruning and stop at the first hit.
d="${CLAUDE_PROJECT_DIR:-$PWD}"
hit="$(find "$d" -maxdepth 6 \
        \( -name .git -o -name node_modules -o -name bin -o -name obj \) -prune \
        -o \( -name '*.sln' -o -name '*.csproj' -o -name global.json \) -print -quit \
        2>/dev/null)"
if [ -n "$hit" ]; then
  echo ".NET workspace detected (found ${hit#"$d"/}). For any .NET work, invoke the dotnet-router skill first — it routes every superpowers stage to the dotnet skill catalog."
fi
exit 0
