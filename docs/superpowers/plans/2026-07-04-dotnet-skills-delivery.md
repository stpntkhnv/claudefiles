# dotnet-skills → superpowers Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Построить схему доставки 98 dotnet-скиллов во все этапы superpowers: роутер-скилл (~постоянно в контексте), генерируемый каталог (по требованию), доставка субагентам через план, детекция .NET-воркспейса хуком, нативная установка одного LSP-плагина.

**Architecture:** Единственный постоянный житель контекста — тонкий скилл `dotnet-router` (личный, через симлинк из версионируемого источника в devTools). Его тело отправляет читать `CATALOG.md` — сгенерированное оглавление всех 98 скиллов с полными описаниями и абсолютными путями. Полные скиллы читаются `Read`-ом по пути; к субагентам знание едет блоками `**Skills:**` и `**Service root:**`, вшитыми в планы. SessionStart-хук детерминированно напоминает про роутер в .NET-деревьях.

**Tech Stack:** bash + awk (генератор, хук, тесты), python3 stdlib (JSON-правка settings.json, verbatim-тест каталога; jq на машине отсутствует, PyYAML тоже), Claude Code personal skills / hooks / plugins.

**Spec:** `/home/stsiapan/devTools/docs/superpowers/specs/2026-07-04-dotnet-skills-delivery-design.md`

## Global Constraints

- Файлы superpowers (`~/.claude/plugins/cache/claude-plugins-official/superpowers/`) и dotnet-skills (`/home/stsiapan/devTools/skills/dotnet-skills/`) НЕ модифицируются.
- Описания в каталоге переносятся из frontmatter дословно, без сжатия (включая USE FOR / DO NOT USE FOR).
- Размер каталога ≤ 60000 символов (≈15k токенов); генератор падает при превышении.
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
- Create (генерируется): `/home/stsiapan/devTools/claude/skills/dotnet-router/CATALOG.md`

**Interfaces:**
- Consumes: `/home/stsiapan/devTools/skills/dotnet-skills/plugins/*/skills/*/SKILL.md` (только чтение).
- Produces: CLI `gen-dotnet-catalog.sh [REPO_DIR] [OUT_FILE]` (по умолчанию: репозиторий dotnet-skills → `/home/stsiapan/devTools/claude/skills/dotnet-router/CATALOG.md`; exit 0 + строка `OK: <N> entries...` при успехе, exit 1 + `ERROR: ...` в stderr при любой проблеме); файл `CATALOG.md` — секция `## Stage map`, затем секции `## <plugin>` с записями вида `- **<name>** — <description>` + строка с путём в бэктиках.

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
OUT="$(mktemp -d)/CATALOG.md"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -x "$GEN" ] || fail "generator missing or not executable"
"$GEN" "$REPO" "$OUT" || fail "generator exited non-zero"
[ -f "$OUT" ] || fail "no catalog written"

# 1. Entry count matches SKILL.md count in the repo
expected=$(find "$REPO/plugins" -name SKILL.md | wc -l)
actual=$(grep -c '^- \*\*' "$OUT")
[ "$actual" -eq "$expected" ] || fail "entries: $actual != $expected"

# 2. Long descriptions survive verbatim, incl. negative triggers
grep -q '\*\*assertion-quality\*\*' "$OUT" || fail "assertion-quality entry missing"
grep 'DO NOT USE FOR' "$OUT" | grep -q 'test-gap-analysis' \
  || fail "DO NOT USE FOR disambiguation lost — descriptions were truncated"

# 3. Every listed path exists and is absolute
while IFS= read -r p; do
  case "$p" in /*) ;; *) fail "non-absolute path: $p" ;; esac
  [ -f "$p" ] || fail "listed path missing: $p"
done < <(grep -o '`/[^`]*SKILL\.md`' "$OUT" | tr -d '\`')

# 4. Size cap: ≤60000 chars ≈ 15k tokens
chars=$(wc -c < "$OUT")
[ "$chars" -le 60000 ] || fail "catalog too big: $chars chars"

# 5. Stage map present
grep -q '^## Stage map' "$OUT" || fail "stage map missing"

# 6. No duplicate skill names — name→path cross-referencing needs uniqueness
dups="$(grep -o '^- \*\*[^*]*\*\*' "$OUT" | sort | uniq -d)"
[ -z "$dups" ] || fail "duplicate skill names: $dups"

# 7. Verbatim property: for EVERY skill the catalog description equals the
# frontmatter description modulo whitespace/quoting. Reference extraction is
# independent (python3 stdlib, line-based) — not the generator's awk.
python3 - "$OUT" "$REPO" <<'PY' || fail "verbatim property violated (see stderr)"
import re, sys, pathlib

out, repo = sys.argv[1], sys.argv[2]

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
lines = pathlib.Path(out).read_text(encoding='utf-8').splitlines()
for i, ln in enumerate(lines):
    m = re.match(r'^- \*\*(.+?)\*\* — (.*)$', ln)
    if m:
        pm = re.match(r'^  `(/.+/SKILL\.md)`$', lines[i + 1])
        if not pm:
            print(f"no path line after entry: {m.group(1)}", file=sys.stderr)
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
# Generates CATALOG.md for the dotnet-router skill from dotnet-skills frontmatter.
# Descriptions are copied VERBATIM (no compression) — the USE FOR / DO NOT USE FOR
# text is the disambiguation that routing accuracy depends on.
set -euo pipefail

REPO="${1:-/home/stsiapan/devTools/skills/dotnet-skills}"
OUT="${2:-/home/stsiapan/devTools/claude/skills/dotnet-router/CATALOG.md}"
MAX_CHARS=60000   # ~15k tokens at ~4 chars/token

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

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

{
  echo "# dotnet-skills catalog"
  echo
  echo "Generated: $(date -I) by gen-dotnet-catalog.sh"
  echo "Source: $REPO ($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo 'not a git repo'))"
  echo
  echo "One entry per skill: **name** — full description — absolute path."
  echo "These skills are NOT installed: never invoke them via the Skill tool — always Read the SKILL.md at the listed path. Relative paths inside a skill (references/, scripts) resolve against that SKILL.md's directory. Skill names mentioned inside skill texts resolve here (name → path)."
  echo
  echo "## Stage map (superpowers stage → sections below)"
  echo
  echo "- brainstorming / architecture: dotnet, dotnet-aspnetcore, dotnet-blazor, dotnet-maui, dotnet-ai, dotnet-data"
  echo "- planning: whole catalog — pick per task by USE FOR / DO NOT USE FOR"
  echo "- implementation: the section matching the task domain"
  echo "- testing: dotnet-test, dotnet-test-migration"
  echo "- debugging / incidents: dotnet-diag"
  echo "- build & packaging: dotnet-msbuild, dotnet-nuget, dotnet-template-engine"
  echo "- upgrades / migration: dotnet-upgrade, dotnet11, dotnet-test-migration"
  echo "- code review: dotnet-test (test-anti-patterns, assertion-quality, test-gap-analysis) + the task domain section"
  echo
} > "$tmp"

count=0
declare -A seen_names
for plugin_dir in "$REPO"/plugins/*/; do
  plugin="$(basename "$plugin_dir")"
  skills="$(find "$plugin_dir" -name SKILL.md | sort)"
  [ -n "$skills" ] || continue
  { echo "## $plugin"; echo; } >> "$tmp"
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
    printf -- '- **%s** — %s\n' "$name" "$desc" >> "$tmp"
    printf -- '  `%s`\n' "$sk" >> "$tmp"
    count=$((count + 1))
  done <<< "$skills"
  echo >> "$tmp"
done

expected="$(find "$REPO/plugins" -name SKILL.md | wc -l)"
if [ "$count" -ne "$expected" ]; then
  echo "ERROR: wrote $count entries, repo has $expected SKILL.md files" >&2
  exit 1
fi

chars="$(wc -c < "$tmp")"
if [ "$chars" -gt "$MAX_CHARS" ]; then
  echo "ERROR: catalog is $chars chars (> $MAX_CHARS ≈ 15k tokens)" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
mv "$tmp" "$OUT"
trap - EXIT
echo "OK: $count entries, $chars chars (~$((chars / 4)) tokens) -> $OUT"
```

- [ ] **Step 5: Запустить тест, убедиться в прохождении**

Run: `/home/stsiapan/devTools/skills/tools/test-gen-dotnet-catalog.sh`
Expected: `PASS: all catalog tests`, exit 0.

Если падает пункт 2 (DO NOT USE FOR потерян) — дефект в awk-извлечении многострочных описаний; чинить `extract_description`, не тест.

- [ ] **Step 6: Сгенерировать боевой каталог**

Run: `/home/stsiapan/devTools/skills/tools/gen-dotnet-catalog.sh`
Expected: `OK: 98 entries, <N> chars (~<M> tokens) -> /home/stsiapan/devTools/claude/skills/dotnet-router/CATALOG.md`, где M в диапазоне 8000–12000.

- [ ] **Step 7: Commit**

```bash
cd /home/stsiapan/devTools
git add skills/tools/ claude/skills/dotnet-router/CATALOG.md
git commit -m "feat: dotnet catalog generator with verbatim descriptions + tests"
```

---

### Task 2: Роутер-скилл и симлинк в ~/.claude/skills

**Files:**
- Create: `/home/stsiapan/devTools/claude/skills/dotnet-router/SKILL.md`
- Create (симлинк): `/home/stsiapan/.claude/skills/dotnet-router` → `/home/stsiapan/devTools/claude/skills/dotnet-router`

**Interfaces:**
- Consumes: `CATALOG.md` из Task 1 (лежит в той же директории; через симлинк доступен как `/home/stsiapan/.claude/skills/dotnet-router/CATALOG.md`).
- Produces: личный скилл `dotnet-router`, видимый Claude Code; канонический путь каталога для всех потребителей: `/home/stsiapan/.claude/skills/dotnet-router/CATALOG.md`.

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

Read the catalog: `/home/stsiapan/.claude/skills/dotnet-router/CATALOG.md`
One entry per skill: name — full description (USE FOR / DO NOT USE FOR) — absolute path. Keep it in context for the rest of the session.

## Core rules

1. **Never invoke dotnet skills via the Skill tool** — they are not installed as plugins. Always `Read` the SKILL.md at its catalog path. Files a skill mentions by relative path (references/, scripts) resolve against that SKILL.md's directory.
2. **Cross-references:** when a dotnet skill says "use skill X" / "call the X skill", resolve X via the catalog (name → path) and Read it.
3. **Match by USE FOR / DO NOT USE FOR**, not by name similarity — sibling skills (especially in dotnet-test and dotnet-msbuild) are deliberately disambiguated there.

## Stage rules

**Reference in the main session** (brainstorming, quick questions): find the entry in the catalog, Read that one SKILL.md. One Read, no agent spawns.

**Writing a plan** (superpowers:writing-plans), for .NET work:
- Add to the plan header: `Skill catalog: /home/stsiapan/.claude/skills/dotnet-router/CATALOG.md`
- Give every task a `**Skills:**` block: absolute paths of the 1–3 SKILL.md files the implementer must Read before starting. Choose by USE FOR / DO NOT USE FOR.
- Multi-service workspace (several .sln branches under one root): give every task a `**Service root:**` block — the absolute directory of the .sln it belongs to. A task touching several services lists all roots and marks the primary. A .NET plan task without a Service root block is a plan defect.

**Dispatching subagents** (subagent-driven-development, dispatching-parallel-agents) — copy mechanically from the plan, no judgment calls:
- The task's `**Skills:**` paths → into the prompt's Context section as: "Before starting, Read these skill files: <paths>".
- The primary `**Service root:**` → the prompt's "Work from:" slot. dotnet commands (build/test/run) execute from the service root, never from the workspace root.
- Always append: "Catalog of all dotnet skills: /home/stsiapan/.claude/skills/dotnet-router/CATALOG.md — if you hit a .NET problem not covered by the files above, find the skill there and Read it."

**Code review** (requesting-code-review): add to the reviewer prompt the paths of the review set — test-anti-patterns, assertion-quality, test-gap-analysis (dotnet-test section of the catalog) — plus the `**Skills:**` paths of the tasks under review.

**Debugging** (systematic-debugging): consult the dotnet-diag section of the catalog first; for failing tests also run-tests and platform-detection from dotnet-test.

**Finishing a branch:** no dotnet knowledge needed.

## Maintenance

The catalog is generated by `/home/stsiapan/devTools/skills/tools/gen-dotnet-catalog.sh`. If a catalog path fails to Read (repo moved/updated), rerun the generator and retry.
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

Run: `test -f /home/stsiapan/.claude/skills/dotnet-router/SKILL.md && test -f /home/stsiapan/.claude/skills/dotnet-router/CATALOG.md && echo OK`
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
test -f /home/stsiapan/.claude/skills/dotnet-router/CATALOG.md && echo "catalog reachable"
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
   читает CATALOG.md, и в плане у каждой задачи есть блоки **Skills:**
   (абсолютные пути) и **Service root:**.
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
