# dotnet-skills → superpowers Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Построить схему доставки 98 dotnet-скиллов во все этапы superpowers: роутер-скилл (~постоянно в контексте), генерируемый каталог (по требованию), доставка субагентам через план, детекция .NET-воркспейса хуком, нативная установка одного LSP-плагина.

**Architecture:** Единственный постоянный житель контекста — тонкий скилл `dotnet-router` (личный, через симлинк из версионируемого источника в devTools). Его тело отправляет читать `INDEX.md` (карта этапов + имена по доменам) и затронутые работой `CATALOG-<домен>.md` — сгенерированное двухуровневое оглавление всех 98 скиллов с полными описаниями и абсолютными путями. Полные скиллы читаются `Read`-ом по пути; к субагентам знание едет блоками `**Skills:**` и `**Service root:**`, вшитыми в планы. SessionStart-хук детерминированно напоминает про роутер в .NET-деревьях.

**Tech Stack:** bash + awk (генератор, хук, тесты), python3 stdlib (JSON-правка settings.json, verbatim-тест каталога; jq на машине отсутствует, PyYAML тоже), Claude Code personal skills / hooks / plugins.

**Spec:** `/home/stsiapan/devTools/docs/superpowers/specs/2026-07-04-dotnet-skills-delivery-design.md`

## Global Constraints

- Файлы superpowers (`~/.claude/plugins/cache/claude-plugins-official/superpowers/`) и dotnet-skills (`/home/stsiapan/devTools/skills/dotnet-skills/`) НЕ модифицируются.
- Описания в каталоге переносятся из frontmatter дословно, без сжатия (включая USE FOR / DO NOT USE FOR).
- Каталог двухуровневый: `INDEX.md` (≤ 8000 символов; карта этапов + все имена по доменам + указатели) и 16 файлов `CATALOG-<домен>.md` (≤ 40 000 символов каждый; полные описания); генератор падает при превышении потолков. Реальный объём описаний — 65 222 символа на 98 скиллов.
- Все пути в каталоге — абсолютные.
- Description роутера ≤ 420 символов (~60–80 токенов постоянной цены).
- Хук: `find` c `-maxdepth 6`, prune `.git`/`node_modules`/`bin`/`obj`, `-print -quit`; в не-.NET-дереве — пустой вывод, exit 0.
- Нативно устанавливается только плагин `dotnet` (LSP); остальные 15 плагинов — только через каталог.
- Канонические источники артефактов живут в `/home/stsiapan/devTools/` (git); в `~/.claude/` попадают симлинком (skills) или абсолютной ссылкой из settings.json (hook).

---

### Task 1: Генератор каталога + git-инициализация devTools

**Files:**
- Create: `/home/stsiapan/devTools/.gitignore`
- Create: `/home/stsiapan/devTools/skills/tools/gen-dotnet-catalog.sh`
- Create: `/home/stsiapan/devTools/skills/tools/test-gen-dotnet-catalog.sh`
- Create (генерируются): `/home/stsiapan/devTools/claude/skills/dotnet-router/INDEX.md` + `/home/stsiapan/devTools/claude/skills/dotnet-router/CATALOG-<plugin>.md` (16 файлов)

**Interfaces:**
- Consumes: `/home/stsiapan/devTools/skills/dotnet-skills/plugins/*/skills/*/SKILL.md` (только чтение).
- Produces: CLI `gen-dotnet-catalog.sh [REPO_DIR] [OUT_DIR]` (по умолчанию: репозиторий dotnet-skills → `/home/stsiapan/devTools/claude/skills/dotnet-router/`; exit 0 + строка `OK: <N> entries across <D> domain files...` при успехе, exit 1 + `ERROR: ...` в stderr при любой проблеме). `INDEX.md` — секции `## Stage map` и `## Domains` (на домен: заголовок с указателем на файл + список имён через запятую); `CATALOG-<plugin>.md` — записи вида `- **<name>** — <description>` + строка с путём в бэктиках.

- [ ] **Step 1: git-инициализация devTools**

`devTools` — не git-репозиторий, а superpowers требует коммитов. Внутри лежит чужой клон `skills/dotnet-skills` (собственный git-репозиторий) — исключить.

```bash
cd /home/stsiapan/devTools
git init -b main
cat > .gitignore <<'EOF'
skills/dotnet-skills/
*.log
EOF
git add .gitignore docs/
git commit -m "chore: init devTools repo, add dotnet-skills delivery spec"
```

- [ ] **Step 2: Написать падающий тест**

Создать `/home/stsiapan/devTools/skills/tools/test-gen-dotnet-catalog.sh` (и `chmod +x`):

```bash
#!/usr/bin/env bash
# Tests for gen-dotnet-catalog.sh — runs against the real dotnet-skills checkout.
set -euo pipefail

GEN="/home/stsiapan/devTools/skills/tools/gen-dotnet-catalog.sh"
REPO="/home/stsiapan/devTools/skills/dotnet-skills"
OUTDIR="$(mktemp -d)"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -x "$GEN" ] || fail "generator missing or not executable"
"$GEN" "$REPO" "$OUTDIR" || fail "generator exited non-zero"
[ -f "$OUTDIR/INDEX.md" ] || fail "no INDEX.md written"

# 1. Entry count across domain files matches SKILL.md count in the repo
expected=$(find "$REPO/plugins" -name SKILL.md | wc -l)
actual=$(cat "$OUTDIR"/CATALOG-*.md | grep -c '^- \*\*')
[ "$actual" -eq "$expected" ] || fail "entries: $actual != $expected"

# 2. Long descriptions survive verbatim, incl. negative triggers
grep -q '\*\*assertion-quality\*\*' "$OUTDIR/CATALOG-dotnet-test.md" || fail "assertion-quality entry missing"
grep 'DO NOT USE FOR' "$OUTDIR/CATALOG-dotnet-test.md" | grep -q 'test-gap-analysis' \
  || fail "DO NOT USE FOR disambiguation lost — descriptions were truncated"

# 3. Every listed path exists and is absolute
while IFS= read -r p; do
  case "$p" in /*) ;; *) fail "non-absolute path: $p" ;; esac
  [ -f "$p" ] || fail "listed path missing: $p"
done < <(cat "$OUTDIR"/CATALOG-*.md | grep -o '`/[^`]*SKILL\.md`' | tr -d '\`')

# 4. Size caps: INDEX ≤8000 chars, each domain file ≤40000 chars
ichars=$(wc -c < "$OUTDIR/INDEX.md")
[ "$ichars" -le 8000 ] || fail "INDEX too big: $ichars chars"
for f in "$OUTDIR"/CATALOG-*.md; do
  c=$(wc -c < "$f")
  [ "$c" -le 40000 ] || fail "$(basename "$f") too big: $c chars"
done

# 5. Stage map present in INDEX
grep -q '^## Stage map' "$OUTDIR/INDEX.md" || fail "stage map missing"

# 5b. INDEX completeness: every domain file pointed to, every skill name listed
for f in "$OUTDIR"/CATALOG-*.md; do
  grep -qF -- "$(basename "$f")" "$OUTDIR/INDEX.md" || fail "INDEX misses pointer to $(basename "$f")"
done
while IFS= read -r name; do
  grep -qF -- "$name" "$OUTDIR/INDEX.md" || fail "INDEX misses skill name: $name"
done < <(cat "$OUTDIR"/CATALOG-*.md | sed -n 's/^- \*\*\([^*]*\)\*\*.*/\1/p')

# 5c. Name-list lines are strictly ", "-separated (regression guard: paste
# delimiter-list cycling once produced mixed "a,b c" separators)
while IFS= read -r line; do
  echo "$line" | grep -Eq '^[a-z0-9-]+(, [a-z0-9-]+)*$' \
    || fail "malformed name-list line in INDEX: $line"
done < <(awk '/^### /{getline; print}' "$OUTDIR/INDEX.md")

# 6. No duplicate skill names — name→path cross-referencing needs uniqueness
dups="$(cat "$OUTDIR"/CATALOG-*.md | grep -o '^- \*\*[^*]*\*\*' | sort | uniq -d)"
[ -z "$dups" ] || fail "duplicate skill names: $dups"

# 7. Verbatim property: for EVERY skill the catalog description equals the
# frontmatter description modulo whitespace/quoting. Reference extraction is
# independent (python3 stdlib, line-based) — not the generator's awk.
python3 - "$OUTDIR" "$REPO" <<'PY' || fail "verbatim property violated (see stderr)"
import re, sys, pathlib

outdir, repo = sys.argv[1], sys.argv[2]

def norm(s):
    return re.sub(r'[\s"\'\\]', '', s)

def ref_desc(text):
    fm = text.split('---', 2)[1]
    desc, on = [], False
    for ln in fm.splitlines():
        if on:
            if re.match(r'^[A-Za-z_-]+:', ln):
                break
            if ln.strip():
                desc.append(ln.strip())
        elif ln.startswith('description:'):
            on = True
            first = ln[len('description:'):].strip()
            if first and not re.fullmatch(r'[>|][+-]?', first):
                desc.append(first)
    return ' '.join(desc)

catalog = {}
for cf in pathlib.Path(outdir).glob('CATALOG-*.md'):
    lines = cf.read_text(encoding='utf-8').splitlines()
    for i, ln in enumerate(lines):
        m = re.match(r'^- \*\*(.+?)\*\* — (.*)$', ln)
        if m:
            pm = re.match(r'^  `(/.+/SKILL\.md)`$', lines[i + 1])
            if not pm:
                print(f"no path line after entry: {m.group(1)} in {cf.name}", file=sys.stderr)
                sys.exit(1)
            catalog[pm.group(1)] = m.group(2)

bad = []
for sk in pathlib.Path(repo, 'plugins').rglob('SKILL.md'):
    text = sk.read_text(encoding='utf-8')
    sk = str(sk)
    if sk not in catalog:
        bad.append(f"missing from catalog: {sk}")
    elif norm(ref_desc(text)) != norm(catalog[sk]):
        bad.append(f"description differs from frontmatter: {sk}")

if bad:
    print('\n'.join(bad), file=sys.stderr)
    sys.exit(1)
PY

echo "PASS: all catalog tests"
```

- [ ] **Step 3: Запустить тест, убедиться в падении**

Run: `/home/stsiapan/devTools/skills/tools/test-gen-dotnet-catalog.sh`
Expected: `FAIL: generator missing or not executable`, exit 1.

- [ ] **Step 4: Написать генератор**

Создать `/home/stsiapan/devTools/skills/tools/gen-dotnet-catalog.sh` (и `chmod +x`):

```bash
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
    printf '%s, ' "${names[@]}" | sed 's/, $//'
    echo
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
```

- [ ] **Step 5: Запустить тест, убедиться в прохождении**

Run: `/home/stsiapan/devTools/skills/tools/test-gen-dotnet-catalog.sh`
Expected: `PASS: all catalog tests`, exit 0.

Если падает пункт 2 (DO NOT USE FOR потерян) — дефект в awk-извлечении многострочных описаний; чинить `extract_description`, не тест.

- [ ] **Step 6: Сгенерировать боевой каталог**

Run: `/home/stsiapan/devTools/skills/tools/gen-dotnet-catalog.sh`
Expected: `OK: 98 entries across 16 domain files, INDEX <I> chars, total <T> chars (~<M> tokens) -> /home/stsiapan/devTools/claude/skills/dotnet-router`, где I ≤ 8000, M в диапазоне 19000–24000.

- [ ] **Step 7: Commit**

```bash
cd /home/stsiapan/devTools
git add skills/tools/ claude/skills/dotnet-router/
git commit -m "feat: two-level dotnet catalog generator (INDEX + domain files) + tests"
```

---

### Task 2: Роутер-скилл и симлинк в ~/.claude/skills

**Files:**
- Create: `/home/stsiapan/devTools/claude/skills/dotnet-router/SKILL.md`
- Create (симлинк): `/home/stsiapan/.claude/skills/dotnet-router` → `/home/stsiapan/devTools/claude/skills/dotnet-router`

**Interfaces:**
- Consumes: `INDEX.md` + `CATALOG-<домен>.md` из Task 1 (лежат в той же директории; через симлинк доступны как `/home/stsiapan/.claude/skills/dotnet-router/...`).
- Produces: личный скилл `dotnet-router`, видимый Claude Code; канонический путь индекса для всех потребителей: `/home/stsiapan/.claude/skills/dotnet-router/INDEX.md`.

- [ ] **Step 1: Написать SKILL.md**

Создать `/home/stsiapan/devTools/claude/skills/dotnet-router/SKILL.md` с точно этим содержимым:

```markdown
---
name: dotnet-router
description: Use for ANY .NET work at ANY superpowers stage — brainstorming, planning, implementation, review, debugging. Triggers - C#, F#, .NET, csproj, sln, ASP.NET Core, EF Core, Blazor, MAUI, MSBuild, NuGet, xUnit, MSTest, dotnet CLI, Roslyn. Routes to ~100 dotnet skills via a catalog and defines how they travel into plans and subagent prompts.
---

# dotnet-router

Routes knowledge from the dotnet-skills catalog into every superpowers stage.

## First action

Read the index: `/home/stsiapan/.claude/skills/dotnet-router/INDEX.md`
It maps superpowers stages to domains and lists every skill name with a pointer to its domain file (`CATALOG-<domain>.md`). Then Read the domain files relevant to the current work — they carry each skill's full description (USE FOR / DO NOT USE FOR) and the absolute path to its SKILL.md. Keep the index in context for the rest of the session; load domain files as the work touches their domains.

## Core rules

1. **Never invoke dotnet skills via the Skill tool** — they are not installed as plugins. Always `Read` the SKILL.md at the path given in the domain file. Files a skill mentions by relative path (references/, scripts) resolve against that SKILL.md's directory.
2. **Cross-references:** when a dotnet skill says "use skill X" / "call the X skill", resolve X via the index (find the name, Read its domain file, take the path) and Read it.
3. **Match by USE FOR / DO NOT USE FOR from the domain file**, not by name similarity in the index — sibling skills (especially in dotnet-test and dotnet-msbuild) are deliberately disambiguated in their full descriptions.

## Stage rules

**Reference in the main session** (brainstorming, quick questions): index → domain file → Read that one SKILL.md. Two or three Reads, no agent spawns.

**Writing a plan** (superpowers:writing-plans), for .NET work:
- Add to the plan header: `Skill catalog index: /home/stsiapan/.claude/skills/dotnet-router/INDEX.md`
- Give every task a `**Skills:**` block: absolute paths of the 1–3 SKILL.md files the implementer must Read before starting. Choose by USE FOR / DO NOT USE FOR from the relevant domain files.
- Multi-service workspace (several .sln branches under one root): give every task a `**Service root:**` block — the absolute directory of the .sln it belongs to. A task touching several services lists all roots and marks the primary. A .NET plan task without a Service root block is a plan defect.

**Dispatching subagents** (subagent-driven-development, dispatching-parallel-agents) — copy mechanically from the plan, no judgment calls:
- The task's `**Skills:**` paths → into the prompt's Context section as: "Before starting, Read these skill files: <paths>".
- The primary `**Service root:**` → the prompt's "Work from:" slot. dotnet commands (build/test/run) execute from the service root, never from the workspace root.
- Always append: "Index of all dotnet skills: /home/stsiapan/.claude/skills/dotnet-router/INDEX.md — if you hit a .NET problem not covered by the files above, find the skill there (index → domain file → SKILL.md path) and Read it."

**Code review** (requesting-code-review): add to the reviewer prompt the paths of the review set — test-anti-patterns, assertion-quality, test-gap-analysis (from CATALOG-dotnet-test.md) — plus the `**Skills:**` paths of the tasks under review.

**Debugging** (systematic-debugging): consult CATALOG-dotnet-diag.md first; for failing tests also run-tests and platform-detection from CATALOG-dotnet-test.md.

**Finishing a branch:** no dotnet knowledge needed.

## Maintenance

The index and domain files are generated by `/home/stsiapan/devTools/skills/tools/gen-dotnet-catalog.sh`. If a listed path fails to Read (repo moved/updated), rerun the generator and retry.
```

- [ ] **Step 2: Проверить description-бюджет**

Run: `awk '/^description:/ {print length($0)}' /home/stsiapan/devTools/claude/skills/dotnet-router/SKILL.md`
Expected: число ≤ 420.

- [ ] **Step 3: Создать симлинк**

`ln -sfn` на существующую реальную директорию падает («cannot overwrite directory») — если по пути уже лежит директория (например, от ручных экспериментов), её содержимое надо посмотреть и убрать руками, а не затирать автоматически:

```bash
dst=/home/stsiapan/.claude/skills/dotnet-router
mkdir -p /home/stsiapan/.claude/skills
if [ -e "$dst" ] && [ ! -L "$dst" ]; then
  echo "ERROR: $dst exists and is not a symlink — inspect its contents and remove it manually first" >&2
  exit 1
fi
ln -sfnT /home/stsiapan/devTools/claude/skills/dotnet-router "$dst"
```

- [ ] **Step 4: Проверить разрешение путей через симлинк**

Run: `test -f /home/stsiapan/.claude/skills/dotnet-router/SKILL.md && test -f /home/stsiapan/.claude/skills/dotnet-router/INDEX.md && test -f /home/stsiapan/.claude/skills/dotnet-router/CATALOG-dotnet-test.md && echo OK`
Expected: `OK`.

**Fallback:** если на смоуке (Task 5, п. 2) выяснится, что Claude Code не открывает скилл через симлинк — заменить симлинк копированием (`cp -r`) и дописать шаг копирования в конец `gen-dotnet-catalog.sh`.

- [ ] **Step 5: Commit**

```bash
cd /home/stsiapan/devTools
git add claude/skills/dotnet-router/SKILL.md
git commit -m "feat: dotnet-router skill — stage rules, service-root rule, catalog pointer"
```

---

### Task 3: SessionStart-хук детекции .NET-воркспейса

**Files:**
- Create: `/home/stsiapan/devTools/claude/hooks/detect-dotnet.sh`
- Create: `/home/stsiapan/devTools/skills/tools/test-detect-dotnet.sh`
- Modify: `/home/stsiapan/.claude/settings.json` (merge, не перезапись)

**Interfaces:**
- Consumes: env `CLAUDE_PROJECT_DIR` (ставится Claude Code при запуске хука), fallback `$PWD`.
- Produces: при обнаружении .NET — одна строка в stdout (попадает в контекст сессии), упоминающая скилл `dotnet-router`; иначе пустой stdout. Всегда exit 0.

- [ ] **Step 1: Написать падающий тест**

Создать `/home/stsiapan/devTools/skills/tools/test-detect-dotnet.sh` (и `chmod +x`):

```bash
#!/usr/bin/env bash
# Tests for the SessionStart .NET-detection hook.
set -euo pipefail

HOOK="/home/stsiapan/devTools/claude/hooks/detect-dotnet.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -x "$HOOK" ] || fail "hook missing or not executable"

t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT

# 1. Positive: sln at depth 4 (root/a/b/c/svc.sln) is found
mkdir -p "$t/a/b/c"
touch "$t/a/b/c/svc.sln"
out="$(CLAUDE_PROJECT_DIR="$t" "$HOOK")"
echo "$out" | grep -q 'dotnet-router' || fail "sln at depth 4 not detected"

# 2. Negative: empty tree stays silent
rm "$t/a/b/c/svc.sln"
out="$(CLAUDE_PROJECT_DIR="$t" "$HOOK")"
[ -z "$out" ] || fail "empty tree produced output: $out"

# 3. Prune: csproj under node_modules is ignored
mkdir -p "$t/x/node_modules/junk"
touch "$t/x/node_modules/junk/fake.csproj"
out="$(CLAUDE_PROJECT_DIR="$t" "$HOOK")"
[ -z "$out" ] || fail "pruned node_modules leaked: $out"

# 4. Exit code is 0 in both cases
CLAUDE_PROJECT_DIR="$t" "$HOOK" >/dev/null || fail "non-zero exit on negative"

# 5. Speed on a real large tree: under 2 seconds
start=$(date +%s%N)
CLAUDE_PROJECT_DIR="/home/stsiapan/devTools" "$HOOK" >/dev/null
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
[ "$elapsed_ms" -lt 2000 ] || fail "hook too slow: ${elapsed_ms}ms"

echo "PASS: all hook tests"
```

- [ ] **Step 2: Запустить тест, убедиться в падении**

Run: `/home/stsiapan/devTools/skills/tools/test-detect-dotnet.sh`
Expected: `FAIL: hook missing or not executable`, exit 1.

- [ ] **Step 3: Написать хук**

Создать `/home/stsiapan/devTools/claude/hooks/detect-dotnet.sh` (и `chmod +x`):

```bash
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
```

- [ ] **Step 4: Запустить тест, убедиться в прохождении**

Run: `/home/stsiapan/devTools/skills/tools/test-detect-dotnet.sh`
Expected: `PASS: all hook tests`, exit 0.

- [ ] **Step 5: Подключить хук в settings.json (merge через python3 — jq на машине нет)**

Порядок обязателен: сначала бутстрап отсутствующего файла, потом бэкап, потом идемпотентный merge:

```bash
S=/home/stsiapan/.claude/settings.json
mkdir -p /home/stsiapan/.claude
[ -f "$S" ] || echo '{}' > "$S"
cp "$S" "$S.bak-dotnet-router"
python3 - "$S" <<'PY'
import json, sys
path = sys.argv[1]
cmd = "/home/stsiapan/devTools/claude/hooks/detect-dotnet.sh"
cfg = json.load(open(path))
entries = cfg.setdefault("hooks", {}).setdefault("SessionStart", [])
already = any(h.get("command") == cmd
              for e in entries for h in e.get("hooks", []))
if already:
    print("already wired")
else:
    entries.append({"hooks": [{"type": "command", "command": cmd}]})
    json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
    print("wired")
PY
python3 -m json.tool "$S" > /dev/null && echo "settings.json valid"
```

Expected: `wired` (при повторном прогоне — `already wired`) и `settings.json valid`.

- [ ] **Step 6: Проверить итоговую проводку**

Run: `python3 -c "import json; print(json.load(open('/home/stsiapan/.claude/settings.json'))['hooks']['SessionStart'])"`
Expected: массив, содержащий объект с `"command": "/home/stsiapan/devTools/claude/hooks/detect-dotnet.sh"`; прежние SessionStart-хуки (если были) сохранены в массиве.

- [ ] **Step 7: Commit**

```bash
cd /home/stsiapan/devTools
git add claude/hooks/detect-dotnet.sh skills/tools/test-detect-dotnet.sh
git commit -m "feat: SessionStart hook — deep pruned .NET workspace detection"
```

---

### Task 4 [OPTIONAL]: Нативная установка LSP-плагина `dotnet`

Ядро схемы (роутер, каталог, план-транспорт, хук) от LSP не зависит. Любой провал этой задачи — статус SKIPPED с докладом пользователю и переход к Task 5, НЕ BLOCKED для плана.

**Files:**
- Modify: конфигурация плагинов Claude Code (через CLI/REPL-команды, не прямой правкой файлов).

**Interfaces:**
- Consumes: маркетплейс `dotnet/skills` (GitHub).
- Produces: установленный плагин `dotnet@dotnet-agent-skills` — Roslyn LSP (`--autoLoadProjects`) + скилл `setup-local-sdk`.

- [ ] **Step 1: Проверить прерequisites**

Run: `dotnet --version`
Expected: `10.x`. Если команда отсутствует или мажорная версия < 10 — пометить задачу SKIPPED и доложить: LSP-плагину нужен .NET 10 SDK (скилл `setup-local-sdk` из этого же плагина умеет ставить SDK локально, но решение об установке SDK — за пользователем). План продолжается с Task 5.

- [ ] **Step 2: Попробовать установку через CLI**

```bash
claude plugin marketplace add dotnet/skills && claude plugin install dotnet@dotnet-agent-skills
```

Expected: сообщения об успешном добавлении маркетплейса и установке. Если субкоманда `plugin` в CLI отсутствует — не изобретать обходов: доложить пользователю точные интерактивные команды и остановиться на этом шаге как выполненном условно:

```
/plugin marketplace add dotnet/skills
/plugin install dotnet@dotnet-agent-skills
```

(и перезапуск сессии после установки).

- [ ] **Step 3: Проверить установку**

Run: `ls /home/stsiapan/.claude/plugins/cache/ | grep -i dotnet || claude plugin list 2>/dev/null | grep -i dotnet`
Expected: непустой вывод с именем плагина/маркетплейса dotnet. Если установка была отдана пользователю в Step 2 — пропустить с пометкой «проверяется на смоуке».

- [ ] **Step 4: Commit (запись факта в план-леджер)**

Изменяемых файлов в devTools у задачи нет; коммит не требуется. Отметить в леджере исполнения способ установки (CLI или передано пользователю).

---

### Task 5: Смоук-проверки (частично с участием пользователя)

**Files:**
- Create: `/home/stsiapan/devTools/docs/superpowers/smoke-results-dotnet-delivery.md` (результаты).

**Interfaces:**
- Consumes: все артефакты Task 1–4.
- Produces: заполненный протокол смоука; список дефектов, если найдены.

Автоматизируемая часть выполняется агентом; поведенческая (живые сессии, LSP) — короткий чеклист для пользователя. Протокол пишется в файл результатов по мере прохождения.

- [ ] **Step 1: Автопроверки артефактов**

```bash
/home/stsiapan/devTools/skills/tools/test-gen-dotnet-catalog.sh
/home/stsiapan/devTools/skills/tools/test-detect-dotnet.sh
test -f /home/stsiapan/.claude/skills/dotnet-router/SKILL.md && echo "skill reachable"
test -f /home/stsiapan/.claude/skills/dotnet-router/INDEX.md && test -f /home/stsiapan/.claude/skills/dotnet-router/CATALOG-dotnet-test.md && echo "catalog reachable"
python3 -m json.tool /home/stsiapan/.claude/settings.json > /dev/null && echo "settings valid"
```

Expected: оба `PASS`, `skill reachable`, `catalog reachable`, `settings valid`.

- [ ] **Step 2: Смоук мультисервисной детекции на реальном воркспейсе**

Запустить хук от корня реального рабочего воркспейса пользователя (директория, из которой обычно стартует Claude Code; уточнить у пользователя путь, если он не в контексте):

```bash
time CLAUDE_PROJECT_DIR="<workspace-root>" /home/stsiapan/devTools/claude/hooks/detect-dotnet.sh
```

Expected: строка с `dotnet-router` и найденным маркером; `real` < 2s. Записать фактическое время в протокол.

- [ ] **Step 3: Чеклист пользователю — поведенческий смоук**

Вписать в файл результатов и показать пользователю чеклист (выполняется в НОВОЙ сессии Claude Code, запущенной из корня рабочего воркспейса):

```markdown
## Поведенческий смоук (новая сессия из корня воркспейса)

1. [ ] Детекция: в начале сессии Claude знает о .NET-контексте
   (спросить: «это .NET-воркспейс?» — ответ должен ссылаться на детекцию,
   без поиска по файлам).
2. [ ] Автосрабатывание роутера: попросить «спланируй небольшую фичу в
   <сервис> на ASP.NET Core». Ожидание: Claude сам вызывает dotnet-router,
   читает INDEX.md и нужные CATALOG-<домен>.md, и в плане у каждой задачи
   есть блоки **Skills:** (абсолютные пути) и **Service root:**.
3. [ ] Делегирование: попросить выполнить одну задачу этого плана через
   субагента. Ожидание: в промпте субагента видны «Before starting, Read
   these skill files: …», «Work from: <service root>» и pull-строка с путём
   каталога.
4. [ ] LSP (только если Task 4 выполнена; при SKIPPED — пропустить):
   открыть вопрос по коду в двух РАЗНЫХ сервисах (например, «где определён
   класс X и кто его использует?» в сервисе A, затем в B).
   Ожидание: точная навигация без grep-перебора; сессия не деградирует
   по памяти (наблюдаемо: нет многоминутных зависаний warmup после первого).
5. [ ] Не-.NET контроль: сессия из любой не-.NET директории — напоминание
   хука отсутствует.
```

- [ ] **Step 4: Зафиксировать результаты и дефекты**

Каждый провал чеклиста — отдельная запись в файле результатов: наблюдение, ожидание, подозреваемый компонент. Известные запасные ходы: симлинк не читается → fallback из Task 2 Step 4; LSP прожорлив на связанных сервисах → выключить плагин (`/plugin uninstall dotnet@dotnet-agent-skills`) — остальная схема от него не зависит; хук не сработал в реальном воркспейсе → проверить глубину залегания маркеров (`find <root> -maxdepth 8 -name '*.sln'`) и при необходимости поднять `-maxdepth` в хуке и тесте.

- [ ] **Step 5: Commit**

```bash
cd /home/stsiapan/devTools
git add docs/superpowers/smoke-results-dotnet-delivery.md
git commit -m "test: smoke protocol for dotnet-skills delivery"
```
