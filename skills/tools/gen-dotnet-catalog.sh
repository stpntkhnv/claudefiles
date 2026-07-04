#!/usr/bin/env bash
# Generates the two-level dotnet-skills catalog for the dotnet-router skill:
#   INDEX.md            — stage map + every skill name by domain + domain file pointers
#   CATALOG-<plugin>.md — one file per plugin, full frontmatter descriptions
# Descriptions are copied VERBATIM (no compression) — the USE FOR / DO NOT USE FOR
# text is the disambiguation that routing accuracy depends on.
set -euo pipefail

REPO="${1:-/home/stsiapan/devTools/skills/dotnet-skills}"
OUTDIR="${2:-/home/stsiapan/devTools/claude/skills/dotnet-router}"
MAX_INDEX_CHARS=8000     # ~2k tokens at ~4 chars/token
MAX_DOMAIN_CHARS=40000   # ~10k tokens per domain file

[ -d "$REPO/plugins" ] || { echo "ERROR: no plugins/ under $REPO" >&2; exit 1; }

# Extract the description field from YAML frontmatter. Handles: single-line
# plain/quoted scalars, block scalars (>, >-, >+, |, |-), and quoted strings
# folded across multiple indented lines. Joins continuation lines with spaces.
extract_description() {
  awk '
    NR==1 && /^---[[:space:]]*$/ { fm=1; next }
    fm && /^---[[:space:]]*$/    { exit }
    fm && /^description:/ {
      d=1
      sub(/^description:[[:space:]]*/, "")
      if ($0 !~ /^[>|][+-]?[[:space:]]*$/ && length($0)) buf=$0
      next
    }
    d && /^[A-Za-z_-]+:/ { exit }   # next top-level key ends the field
    d {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      if (length(line)) buf = (length(buf) ? buf " " line : line)
      next
    }
    END { print buf }
  ' "$1" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//" -e 's/\\"/"/g'
}

extract_name() {
  awk '
    NR==1 && /^---[[:space:]]*$/ { fm=1; next }
    fm && /^---[[:space:]]*$/    { exit }
    fm && /^name:[[:space:]]*/   { sub(/^name:[[:space:]]*/, ""); gsub(/["\x27]/, ""); print; exit }
  ' "$1"
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

index="$workdir/INDEX.md"
{
  echo "# dotnet-skills catalog — index"
  echo
  echo "Generated: $(date -I) by gen-dotnet-catalog.sh"
  echo "Source: $REPO ($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo 'not a git repo'))"
  echo
  echo "Full VERBATIM skill descriptions (USE FOR / DO NOT USE FOR) live in the per-domain files listed below. Read the domain file before picking a skill — do NOT choose by name alone. These skills are NOT installed: never invoke them via the Skill tool — always Read the SKILL.md at the path given in the domain file. Relative paths inside a skill (references/, scripts) resolve against that SKILL.md's directory. Skill names mentioned inside skill texts resolve here: find the name below, Read its domain file."
  echo
  echo "## Stage map (superpowers stage → domains)"
  echo
  echo "- brainstorming / architecture: dotnet, dotnet-aspnetcore, dotnet-blazor, dotnet-maui, dotnet-ai, dotnet-data"
  echo "- planning: consult every domain matching the feature area — pick per task by USE FOR / DO NOT USE FOR"
  echo "- implementation: the domain matching the task"
  echo "- testing: dotnet-test, dotnet-test-migration"
  echo "- debugging / incidents: dotnet-diag"
  echo "- build & packaging: dotnet-msbuild, dotnet-nuget, dotnet-template-engine"
  echo "- upgrades / migration: dotnet-upgrade, dotnet11, dotnet-test-migration"
  echo "- code review: dotnet-test (test-anti-patterns, assertion-quality, test-gap-analysis) + the task domain"
  echo
  echo "## Domains"
  echo
} > "$index"

count=0
domains=0
declare -A seen_names
for plugin_dir in "$REPO"/plugins/*/; do
  plugin="$(basename "$plugin_dir")"
  skills="$(find "$plugin_dir" -name SKILL.md | sort)"
  [ -n "$skills" ] || continue
  domain_file="$workdir/CATALOG-$plugin.md"
  { echo "# dotnet-skills catalog — $plugin"; echo; } > "$domain_file"
  names=()
  while IFS= read -r sk; do
    name="$(extract_name "$sk")"
    [ -n "$name" ] || name="$(basename "$(dirname "$sk")")"
    if [ -n "${seen_names[$name]:-}" ]; then
      echo "ERROR: duplicate skill name '$name' in $sk and ${seen_names[$name]} — name→path cross-referencing requires unique names" >&2
      exit 1
    fi
    seen_names["$name"]="$sk"
    desc="$(extract_description "$sk")"
    if [ -z "$desc" ]; then
      echo "ERROR: empty description extracted from $sk" >&2
      exit 1
    fi
    printf -- '- **%s** — %s\n' "$name" "$desc" >> "$domain_file"
    printf -- '  `%s`\n' "$sk" >> "$domain_file"
    names+=("$name")
    count=$((count + 1))
  done <<< "$skills"
  dchars="$(wc -c < "$domain_file")"
  if [ "$dchars" -gt "$MAX_DOMAIN_CHARS" ]; then
    echo "ERROR: CATALOG-$plugin.md is $dchars chars (> $MAX_DOMAIN_CHARS)" >&2
    exit 1
  fi
  {
    echo "### $plugin (${#names[@]} skills) — \`$OUTDIR/CATALOG-$plugin.md\`"
    printf '%s\n' "${names[@]}" | paste -sd ', ' -
    echo
  } >> "$index"
  domains=$((domains + 1))
done

expected="$(find "$REPO/plugins" -name SKILL.md | wc -l)"
if [ "$count" -ne "$expected" ]; then
  echo "ERROR: wrote $count entries, repo has $expected SKILL.md files" >&2
  exit 1
fi

ichars="$(wc -c < "$index")"
if [ "$ichars" -gt "$MAX_INDEX_CHARS" ]; then
  echo "ERROR: INDEX.md is $ichars chars (> $MAX_INDEX_CHARS)" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/CATALOG-*.md
cp "$workdir"/CATALOG-*.md "$index" "$OUTDIR"/
total="$(cat "$OUTDIR"/CATALOG-*.md "$OUTDIR/INDEX.md" | wc -c)"
echo "OK: $count entries across $domains domain files, INDEX $ichars chars, total $total chars (~$((total / 4)) tokens) -> $OUTDIR"
