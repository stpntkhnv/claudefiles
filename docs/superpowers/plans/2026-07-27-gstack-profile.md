# Профиль `g` (gstack): план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить третий профиль `g` (`~/.claude-g`, команда `claude-g`) с установленным gstack, отвечающий за этап видения, и закрепить передачу артефакта в профиль `super` через `docs/vision/`.

**Architecture:** Профиль — это функция-рецепт `recipe_g` в `lib/profiles.sh`, зовущая существующие идемпотентные `*_apply` с `CLAUDEFILES_TARGET=~/.claude-g`. Новый модуль `lib/gstack.sh` владеет клоном апстрима внутри `~/.claude-g/skills/gstack` и запускает его инсталлятор неинтерактивно, только когда upstream HEAD сдвинулся. Договорённость о `docs/vision/` живёт marker-блоками в `CLAUDE.md` профилей `g` и `super`.

**Tech Stack:** bash (`set -euo pipefail`), python3 stdlib, git, bun (только для инсталлятора gstack). Тесты — `skills/tools/test-*.sh` против фикстурного `$HOME` и фейковых CLI.

**Спека:** `docs/superpowers/specs/2026-07-27-gstack-profile-design.md`

## Global Constraints

- Повторный `./setup.sh` не даёт diff ни в одном каталоге профиля и выходит 0.
- Все новые модули `lib/*.sh` — source, не execute; никаких side-effect'ов на уровне файла.
- Репозиторий публичный: ни клон gstack, ни каталоги профилей, ни маркеры в git не попадают.
- Провал одного профиля не рушит остальные; агрегируется в non-zero выход `setup.sh`.
- Тесты гоняются через `bash skills/tools/run-all-tests.sh`, ожидаемый итог — `ALL TESTS PASSED`.
- Стиль текстов в marker-блоках — английский, как в существующих `_CLAUDEMD_RULE` и `_PERSONAL_RULE`.
- Целевой каталог всегда берётся из `${CLAUDEFILES_TARGET:-$HOME/.claude}`, никогда не хардкодится.
- Флаги читаются через `config_flag <name>` и сравниваются со строкой `true`.

## Отклонение от спеки (осознанное)

Спека называла правку `readiness_report` (`lib/deps.sh:110`) — строку про `bun`. Она **не делается**: `readiness_report` не вызывается из `setup.sh` (единственные вызовы — в `skills/tools/test-deps.sh`), то есть добавленная строка была бы мёртвым кодом. `deps_apply` расширяется как запланировано.

## File Structure

| Файл | Ответственность |
|------|-----------------|
| `lib/gstack.sh` | **создаётся.** Клон gstack в каталоге профиля, обновление, гейт по SHA, запуск инсталлятора |
| `lib/claudemd.sh` | правится. Общий `_claudemd_block_apply` + третий блок `claudefiles:vision` |
| `lib/profiles.sh` | правится. `recipe_g`; `recipe_super` получает vision-блок в роли consumer |
| `lib/deps.sh` | правится. Седьмой параметр `deps_apply` — зависимость `bun` |
| `setup.sh` | правится. Флаг `profile_gstack`, deps, состав `selected`, итоговая строка |
| `claude/settings/settings.g.template.json` | **создаётся.** Управляемые ключи профиля `g` |
| `claude/mcp/build_servers.py` | правится. Профиль `g` получает только `context7` |
| `claude/statusline/statusline.sh` | правится. Свой цвет бейджа `[g]` |
| `skills/tools/lib/faketools.bash` | правится. Фикстура не наследует `CLAUDE_CONFIG_DIR` |
| `skills/tools/test-gstack.sh` | **создаётся.** Юнит-тесты модуля против фикстурного апстрима |
| `skills/tools/test-*.sh` | правятся. Расширение на третий профиль |
| `README.md`, `docs/*.md` | правятся. Три профиля вместо двух |

---

### Task 0: Вернуть тест-сьют в зелёное

Ветка `main` красная **до** этой работы: коммит `e61f263` сменил тему шаблонов на `auto`, но четыре ассерта в тестах всё ещё ждут `light`/`dark`. Плюс фикстурный `$HOME` наследует `CLAUDE_CONFIG_DIR` из окружения разработчика, поэтому суит падает, если гонять его изнутри `claude-super`. Без зелёного базиса новую работу не на чем верифицировать.

**Files:**
- Modify: `skills/tools/lib/faketools.bash:14`
- Modify: `skills/tools/test-settings.sh:17`, `skills/tools/test-settings.sh:49`
- Modify: `skills/tools/test-multiprofile.sh:26`
- Modify: `skills/tools/test-profiles.sh:51`

**Interfaces:**
- Consumes: ничего.
- Produces: зелёный `run-all-tests.sh`; `setup_fixture_home` гарантирует отсутствие `CLAUDE_CONFIG_DIR` в фикстуре.

- [ ] **Step 1: Зафиксировать красный базис**

Run: `bash skills/tools/run-all-tests.sh 2>&1 | grep -E "^(=== |FAIL|PASS|SOME|ALL)"`

Expected: `FAIL: test-multiprofile.sh`, `FAIL: test-profiles.sh`, `FAIL: test-settings.sh`, итог `SOME TESTS FAILED`.

- [ ] **Step 2: Изолировать фикстуру от `CLAUDE_CONFIG_DIR`**

В `skills/tools/lib/faketools.bash`, в функции `setup_fixture_home`, сразу после `export HOME="$h"` добавить:

```bash
  # The claudefiles wrapper exports CLAUDE_CONFIG_DIR, so the suite may be run from inside a
  # non-default profile. A fixture must never inherit it: modules under test would write to
  # the developer's real profile dir instead of the fixture.
  unset CLAUDE_CONFIG_DIR
```

- [ ] **Step 3: Поправить четыре устаревших ассерта темы**

`skills/tools/test-settings.sh:17` — было `d["theme"]=="dark"`, стало:

```python
assert d["model"]=="opus[1m]" and d["theme"]=="auto" and d["tui"]=="fullscreen"
```

`skills/tools/test-settings.sh:49`:

```python
assert d["theme"]=="auto", "vanilla theme not applied"
```

`skills/tools/test-multiprofile.sh:26`:

```python
assert d["theme"]=="auto", d.get("theme")
```

`skills/tools/test-profiles.sh:51`:

```bash
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["theme"]=="auto";assert "enabledPlugins" not in d;print("ok vanilla-recipe")' "$h/.claude/settings.json"
```

Фикстуры-входы `test-settings.sh:41` и `test-multiprofile.sh:9` (`"theme":"dark"` в «сегодняшнем» settings.json) **не трогать** — это исходное состояние миграции, а не ожидание.

- [ ] **Step 4: Прогнать сьют**

Run: `bash skills/tools/run-all-tests.sh 2>&1 | grep -E "^(=== |FAIL|PASS|SOME|ALL)"`

Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add skills/tools/lib/faketools.bash skills/tools/test-settings.sh skills/tools/test-multiprofile.sh skills/tools/test-profiles.sh
git commit -m "test: fix stale theme assertions and isolate fixtures from CLAUDE_CONFIG_DIR"
```

---

### Task 1: Общий marker-блок и `claudemd_vision_apply`

`claudemd_apply` (`lib/claudemd.sh:13-34`) и `claudemd_personal_apply` (`:41-60`) уже почти идентичны. Третья копия того же awk сделала бы файл нечитаемым, поэтому сначала выделяется общий helper, затем на нём строится третий блок.

**Files:**
- Modify: `lib/claudemd.sh` (весь файл переписывается)
- Test: `skills/tools/test-claudemd.sh`

**Interfaces:**
- Consumes: `CLAUDEFILES_CLAUDE_MD` / `CLAUDEFILES_TARGET` (как сейчас).
- Produces:
  - `_claudemd_block_apply <begin> <end> <rule> <enabled:true|false>` — приватный, возвращает 0.
  - `claudemd_apply <enabled:true|false>` — без изменений в сигнатуре и поведении.
  - `claudemd_personal_apply <enabled:true|false>` — без изменений.
  - `claudemd_vision_apply <role:producer|consumer|off>` — новый, возвращает 0. Маркер блока: `claudefiles:vision`.

- [ ] **Step 1: Написать падающий тест**

В конец `skills/tools/test-claudemd.sh`, **перед** финальной строкой `[ "$fails" -eq 0 ] && ...`, вставить:

```bash
# vision block: producer/consumer/off, coexisting with the other two blocks
setup_fixture_home >/dev/null; hv="$HOME"
export CLAUDEFILES_CLAUDE_MD="$hv/.claude/CLAUDE.md"
printf 'user notes\n' > "$CLAUDEFILES_CLAUDE_MD"

claudemd_vision_apply producer
chk "vision producer writes block"   grep -q "claudefiles:vision" "$CLAUDEFILES_CLAUDE_MD"
chk "vision producer names docs/vision" grep -q "docs/vision/" "$CLAUDEFILES_CLAUDE_MD"
chk "exactly one vision begin"       [ "$(grep -c '>>> claudefiles:vision >>>' "$CLAUDEFILES_CLAUDE_MD")" -eq 1 ]

cp "$CLAUDEFILES_CLAUDE_MD" "$hv/vision-first.md"
claudemd_vision_apply producer
chk "vision producer idempotent"     cmp -s "$hv/vision-first.md" "$CLAUDEFILES_CLAUDE_MD"

claudemd_vision_apply consumer
chk "consumer replaces in place"     [ "$(grep -c '>>> claudefiles:vision >>>' "$CLAUDEFILES_CLAUDE_MD")" -eq 1 ]
chk "consumer text differs"          bash -c '! cmp -s "$1" "$CLAUDEFILES_CLAUDE_MD"' _ "$hv/vision-first.md"

# all three blocks coexist
claudemd_apply true; claudemd_personal_apply true
chk "three blocks coexist: vision"   grep -q "claudefiles:vision" "$CLAUDEFILES_CLAUDE_MD"
chk "three blocks coexist: codex"    grep -q "claudefiles:codex-review" "$CLAUDEFILES_CLAUDE_MD"
chk "three blocks coexist: personal" grep -q "claudefiles:personal" "$CLAUDEFILES_CLAUDE_MD"
chk "user content still there"       grep -q "user notes" "$CLAUDEFILES_CLAUDE_MD"

claudemd_vision_apply off
chk "off removes vision"             bash -c '! grep -q "claudefiles:vision" "$CLAUDEFILES_CLAUDE_MD"'
chk "off keeps codex block"          grep -q "claudefiles:codex-review" "$CLAUDEFILES_CLAUDE_MD"
chk "off keeps personal block"       grep -q "claudefiles:personal" "$CLAUDEFILES_CLAUDE_MD"
chk "off keeps user content"         grep -q "user notes" "$CLAUDEFILES_CLAUDE_MD"

# off on a missing file must not create it
setup_fixture_home >/dev/null; hv2="$HOME"
export CLAUDEFILES_CLAUDE_MD="$hv2/.claude/CLAUDE.md"
claudemd_vision_apply off
chk "off on missing file -> no file" [ ! -e "$CLAUDEFILES_CLAUDE_MD" ]
unset CLAUDEFILES_CLAUDE_MD
```

- [ ] **Step 2: Прогнать тест, убедиться что падает**

Run: `bash skills/tools/test-claudemd.sh`

Expected: FAIL со строкой вида `claudemd_vision_apply: command not found`.

- [ ] **Step 3: Переписать `lib/claudemd.sh`**

Полное содержимое файла:

```bash
# claudemd.sh — own marker-delimited blocks in a profile's CLAUDE.md, preserve the rest.
# Deterministic: strip our block + trailing blank lines, then re-append if enabled.
# Re-running with the same arguments yields a byte-identical file. Source, don't execute.

_claudemd_file() { echo "${CLAUDEFILES_CLAUDE_MD:-${CLAUDEFILES_TARGET:-$HOME/.claude}/CLAUDE.md}"; }

_claudemd_block_apply() { # <begin> <end> <rule> <enabled:true|false>
  local begin="$1" end="$2" rule="$3" enabled="${4:-false}"
  local f; f="$(_claudemd_file)"
  # disable + no file -> nothing to do (don't create a spurious file)
  [ "$enabled" != true ] && [ ! -f "$f" ] && return 0
  mkdir -p "$(dirname "$f")"
  # base = existing content minus our block, with trailing blank lines trimmed
  local base=""
  [ -f "$f" ] && base="$(awk -v b="$begin" -v e="$end" '
      $0==b{skip=1;next} $0==e{skip=0;next}
      !skip{a[++n]=$0; if(NF)last=n}
      END{for(i=1;i<=last;i++)print a[i]}' "$f")"
  {
    if [ "$enabled" = true ]; then
      [ -n "$base" ] && printf '%s\n\n' "$base"
      printf '%s\n%s\n%s\n' "$begin" "$rule" "$end"
    else
      [ -n "$base" ] && printf '%s\n' "$base"
    fi
  } > "$f"
  return 0
}

_CLAUDEMD_BEGIN="# >>> claudefiles:codex-review >>>"
_CLAUDEMD_END="# <<< claudefiles:codex-review <<<"
_CLAUDEMD_RULE='At superpowers checkpoints, run the `codex-review` skill for an independent Codex
cross-review, then triage its findings (superpowers:receiving-code-review) before showing the user:
- after writing a spec to docs/superpowers/specs/ (before the user-review gate),
- after writing a plan to docs/superpowers/plans/,
- at requesting-code-review, on the task diff.
Advisory and single-shot: Codex informs, it does not gate. If codex is unauthenticated, report and skip.'

claudemd_apply() { # <enabled:true|false>
  _claudemd_block_apply "$_CLAUDEMD_BEGIN" "$_CLAUDEMD_END" "$_CLAUDEMD_RULE" "${1:-false}"
}

_PERSONAL_BEGIN="# >>> claudefiles:personal >>>"
_PERSONAL_END="# <<< claudefiles:personal <<<"
_PERSONAL_RULE='Write short and direct. No emojis. No em-dashes. Avoid "ensure", "leverage",
"robust", "seamless", "utilize". Cite file:line when referencing code. No code comments unless asked.'

claudemd_personal_apply() { # <enabled:true|false>
  _claudemd_block_apply "$_PERSONAL_BEGIN" "$_PERSONAL_END" "$_PERSONAL_RULE" "${1:-false}"
}

_VISION_BEGIN="# >>> claudefiles:vision >>>"
_VISION_END="# <<< claudefiles:vision <<<"
_VISION_PRODUCER='This profile owns the VISION stage only. When a discussion settles, write the
outcome to docs/vision/YYYY-MM-DD-<topic>.md: which features are needed, what was decided, what was
dropped and why, how it should look and feel. Do NOT write a specification or an implementation
plan — those belong to the superpowers profile (`claude-super`).'
_VISION_CONSUMER='Before superpowers:brainstorming, check docs/vision/ for a vision document on the
topic at hand. If one exists, read it and treat it as settled input: which features are needed, what
was decided, what was dropped. Do not re-open those questions — turn the vision into a specification.'

claudemd_vision_apply() { # <role:producer|consumer|off>
  case "${1:-off}" in
    producer) _claudemd_block_apply "$_VISION_BEGIN" "$_VISION_END" "$_VISION_PRODUCER" true ;;
    consumer) _claudemd_block_apply "$_VISION_BEGIN" "$_VISION_END" "$_VISION_CONSUMER" true ;;
    *)        _claudemd_block_apply "$_VISION_BEGIN" "$_VISION_END" "" false ;;
  esac
}
```

- [ ] **Step 4: Прогнать тест, убедиться что проходит**

Run: `bash skills/tools/test-claudemd.sh`

Expected: `PASS test-claudemd`, все строки `ok`.

- [ ] **Step 5: Убедиться, что рефакторинг ничего не сломал**

Run: `bash skills/tools/run-all-tests.sh 2>&1 | grep -E "^(=== |FAIL|PASS|SOME|ALL)"`

Expected: `ALL TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add lib/claudemd.sh skills/tools/test-claudemd.sh
git commit -m "feat(claudemd): extract shared block applier, add the vision block"
```

---

### Task 2: `lib/gstack.sh`

Сердце фичи. Модуль владеет клоном апстрима внутри каталога профиля и запускает чужой инсталлятор так, чтобы он не задавал вопросов, не лез в `sudo` и не выходил за пределы профиля.

**Files:**
- Create: `lib/gstack.sh`
- Test: `skills/tools/test-gstack.sh`

**Interfaces:**
- Consumes: `CLAUDEFILES_TARGET` (каталог профиля), `log`/`warn` из `lib/common.sh`, `CLAUDEFILES_GSTACK_REPO` (override источника, только для тестов).
- Produces: `gstack_apply` — без аргументов. Возврат 0 при успехе или когда SHA не изменился, 1 при любом провале. Артефакты: клон в `$CLAUDEFILES_TARGET/skills/gstack`, маркер `$CLAUDEFILES_TARGET/.gstack-setup-head`.

- [ ] **Step 1: Написать падающий тест**

Создать `skills/tools/test-gstack.sh`:

```bash
#!/usr/bin/env bash
# test-gstack.sh — unit tests for lib/gstack.sh against a fixture upstream repo.
# No network: the "upstream" is a local bare repo whose ./setup only records its invocation.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
fails=0
chk() { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }
source "$cf/skills/tools/lib/faketools.bash"
source "$cf/lib/common.sh"; source "$cf/lib/gstack.sh"

WORK=""; BARE=""
trap '[ -n "$WORK" ] && rm -rf "$WORK"; [ -n "$BARE" ] && rm -rf "$BARE"' EXIT

# fixture upstream: ./setup records how it was called, and can be told to fail
mk_upstream() {
  WORK="$(mktemp -d)"; BARE="$(mktemp -d)/gstack.git"
  git init -q "$WORK"
  cat > "$WORK/setup" <<'EOS'
#!/usr/bin/env bash
{ echo "args: $*"; echo "fonts: ${GSTACK_SKIP_FONTS:-unset}"; } >> "${GSTACK_FAKE_LOG:?}"
[ "${GSTACK_FAKE_FAIL:-0}" = "1" ] && exit 1
exit 0
EOS
  chmod +x "$WORK/setup"; echo v1 > "$WORK/VERSION"
  git -C "$WORK" add -A
  git -C "$WORK" -c user.email=t@t -c user.name=t commit -qm init
  git clone -q --bare "$WORK" "$BARE"
}
bump_upstream() {   # add a commit and publish it to the bare repo
  echo "$1" > "$WORK/VERSION"
  git -C "$WORK" add -A
  git -C "$WORK" -c user.email=t@t -c user.name=t commit -qm "$1"
  git -C "$WORK" push -q origin HEAD 2>/dev/null || git -C "$WORK" push -q "$BARE" HEAD:master
}
setup_calls() { grep -c '^args:' "$GSTACK_FAKE_LOG" 2>/dev/null || echo 0; }

mk_upstream
setup_fixture_home >/dev/null; h="$HOME"
export CLAUDEFILES_GSTACK_REPO="file://$BARE"
export CLAUDEFILES_TARGET="$h/.claude-g"
export GSTACK_FAKE_LOG="$h/gstack-setup.log"; : > "$GSTACK_FAKE_LOG"
printf '#!/usr/bin/env bash\nexit 0\n' > "$h/bin/bun"; chmod +x "$h/bin/bun"; hash -r 2>/dev/null || true

# A: fresh install
gstack_apply; rc=$?
chk "fresh install returns 0"        [ "$rc" -eq 0 ]
chk "clone landed in the profile"    [ -d "$h/.claude-g/skills/gstack/.git" ]
chk "installer ran once"             [ "$(setup_calls)" -eq 1 ]
chk "marker written"                 [ -s "$h/.claude-g/.gstack-setup-head" ]
chk "marker equals clone HEAD" \
  bash -c '[ "$(cat "$1/.gstack-setup-head")" = "$(git -C "$1/skills/gstack" rev-parse HEAD)" ]' _ "$h/.claude-g"

# B: installer arguments are pinned
chk "installer got --host claude"          grep -q -- '--host claude'          "$GSTACK_FAKE_LOG"
chk "installer got --no-team"              grep -q -- '--no-team'              "$GSTACK_FAKE_LOG"
chk "installer got --no-plan-tune-hooks"   grep -q -- '--no-plan-tune-hooks'   "$GSTACK_FAKE_LOG"
chk "installer got -q"                     grep -q -- '-q'                     "$GSTACK_FAKE_LOG"
chk "fonts install suppressed"             grep -q '^fonts: 1$'                "$GSTACK_FAKE_LOG"

# C: the default profile dir is never touched
chk "default profile untouched"      [ ! -e "$h/.claude/skills/gstack" ]

# D: re-run with an unchanged upstream is a no-op
gstack_apply; rc=$?
chk "unchanged re-run returns 0"     [ "$rc" -eq 0 ]
chk "installer NOT run again"        [ "$(setup_calls)" -eq 1 ]

# E: a dirty worktree (the real installer patches SKILL.md name: fields) still updates
echo "patched by the installer" >> "$h/.claude-g/skills/gstack/VERSION"
bump_upstream v2
gstack_apply; rc=$?
chk "dirty tree + moved upstream ok" [ "$rc" -eq 0 ]
chk "installer ran again"            [ "$(setup_calls)" -eq 2 ]
chk "clone is at the new upstream"   bash -c 'grep -qx v2 "$1/skills/gstack/VERSION"' _ "$h/.claude-g"

# F: installer failure -> rc 1 and NO marker update (next run retries)
prev_marker="$(cat "$h/.claude-g/.gstack-setup-head")"
bump_upstream v3
GSTACK_FAKE_FAIL=1 gstack_apply; rc=$?
chk "installer failure returns 1"    [ "$rc" -eq 1 ]
chk "marker not advanced on failure" [ "$(cat "$h/.claude-g/.gstack-setup-head")" = "$prev_marker" ]
gstack_apply; rc=$?
chk "retry after failure succeeds"   [ "$rc" -eq 0 ]

# G: no bun -> rc 1 before any git work (minimal PATH keeps this deterministic)
rm -f "$h/bin/bun"; hash -r 2>/dev/null || true
( PATH="$h/bin"; gstack_apply ); rc=$?
chk "missing bun returns 1"          [ "$rc" -eq 1 ]

unset CLAUDEFILES_TARGET CLAUDEFILES_GSTACK_REPO GSTACK_FAKE_LOG
[ "$fails" -eq 0 ] && echo "PASS test-gstack" || { echo "SOME test-gstack CASES FAILED"; exit 1; }
```

- [ ] **Step 2: Прогнать тест, убедиться что падает**

Run: `bash skills/tools/test-gstack.sh`

Expected: FAIL — `lib/gstack.sh: No such file or directory`.

- [ ] **Step 3: Написать `lib/gstack.sh`**

```bash
# gstack.sh — own the gstack clone inside a profile's skills/ dir and drive its installer.
# The upstream installer is imperative and interactive by default; every flag below buys back
# one specific behaviour. Idempotent: the installer runs only when upstream HEAD moved.
# Source, don't execute.

gstack_apply() {   # no args; target comes from CLAUDEFILES_TARGET. 0 = ok/unchanged, 1 = failed.
  local repo="${CLAUDEFILES_GSTACK_REPO:-https://github.com/garrytan/gstack.git}"
  local target="${CLAUDEFILES_TARGET:-$HOME/.claude}"
  local dst="$target/skills/gstack" marker="$target/.gstack-setup-head"

  # gstack setup:6 exits hard without bun. Fail the profile rather than leave an empty shell.
  if ! command -v bun >/dev/null 2>&1; then
    warn "gstack needs bun — install it: sudo pacman -S --needed bun"
    return 1
  fi

  if [ -d "$dst/.git" ]; then
    # The installer rewrites `name:` fields inside the clone (gstack setup:993, setup:999), so the
    # worktree is permanently dirty and `git pull --ff-only` would fail. Reset to upstream instead.
    git -C "$dst" fetch --depth 1 origin >/dev/null 2>&1 || { warn "gstack: fetch from $repo failed"; return 1; }
    git -C "$dst" reset --hard FETCH_HEAD >/dev/null 2>&1 || { warn "gstack: reset to upstream failed"; return 1; }
  else
    rm -rf "$dst"                       # drop a partial or non-git leftover
    mkdir -p "$(dirname "$dst")"
    git clone --single-branch --depth 1 "$repo" "$dst" >/dev/null 2>&1 \
      || { warn "gstack: clone of $repo failed"; return 1; }
  fi

  local head; head="$(git -C "$dst" rev-parse HEAD)" || { warn "gstack: cannot read clone HEAD"; return 1; }
  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$head" ]; then
    log "gstack unchanged ($head)"; return 0
  fi

  # --host claude is already the upstream default (setup:79), pinned explicitly so a future
  # default of `auto` (setup:204-208) can't pick up a local `codex` and install outside this
  # profile. --no-team leaves project repos alone; --no-plan-tune-hooks kills the interactive
  # prompt at setup:1476; GSTACK_SKIP_FONTS=1 kills the sudo pacman font install at setup:312.
  if ( cd "$dst" && GSTACK_SKIP_FONTS=1 ./setup --host claude --no-team --no-plan-tune-hooks -q ); then
    printf '%s' "$head" > "$marker"
    log "gstack installed → $dst ($head)"
    return 0
  fi
  warn "gstack: installer failed; marker left unchanged so the next run retries"
  return 1
}
```

- [ ] **Step 4: Прогнать тест, убедиться что проходит**

Run: `bash skills/tools/test-gstack.sh`

Expected: `PASS test-gstack`, все строки `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/gstack.sh skills/tools/test-gstack.sh
git commit -m "feat(gstack): clone and install gstack inside the profile, gated on upstream SHA"
```

---

### Task 3: Статика профиля `g`

Три маленькие правки, которые вместе делают профиль `g` опознаваемым: свой шаблон настроек, свой MCP-набор, свой цвет бейджа.

**Files:**
- Create: `claude/settings/settings.g.template.json`
- Modify: `claude/mcp/build_servers.py:23`
- Modify: `claude/statusline/statusline.sh:52-56`
- Test: `skills/tools/test-settings.sh`, `skills/tools/test-statusline.sh`

**Interfaces:**
- Consumes: плейсхолдеры `<STATUSLINE_PATH>` и `<SOUND_PATH>`, которые подставляет `settings_apply` (`lib/settings.sh:11`).
- Produces: путь `claude/settings/settings.g.template.json` (используется `recipe_g` в Task 5); `build_servers.py <cfg> g` печатает JSON с единственным ключом `context7`.

- [ ] **Step 1: Написать падающие тесты**

В конец `skills/tools/test-settings.sh`, перед финальной строкой `echo "PASS test-settings"`, вставить:

```bash
# --- profile g: vanilla-shaped base plus the heavy model, no plugin machinery ---
setup_fixture_home >/dev/null; hg="$HOME"
G="$cf/claude/settings/settings.g.template.json"
CLAUDEFILES_TARGET="$hg/.claude-g" settings_apply "$G" false false
python3 - "$hg/.claude-g/settings.json" "$cf" <<'PY'
import json,sys; d=json.load(open(sys.argv[1])); cf=sys.argv[2]
assert d["model"]=="opus[1m]", d.get("model")
assert d["effortLevel"]=="xhigh", d.get("effortLevel")
assert d["theme"]=="auto" and d["tui"]=="fullscreen"
assert d["statusLine"]["command"]==f"{cf}/claude/statusline/statusline.sh g", d["statusLine"]["command"]
assert "enabledPlugins" not in d, "g must not enable plugins"
assert "extraKnownMarketplaces" not in d, "g must not add marketplaces"
assert set(d["hooks"]) == {"Stop", "Notification"}, d.get("hooks")
assert d["hooks"]["Stop"][0]["hooks"][0]["command"] == f"paplay {cf}/claude/sounds/ready.wav >/dev/null 2>&1"
print("ok profile-g settings")
PY

# --- profile g MCP: context7 only, regardless of super-only flags ---
printf '%s' '{"flags":{"playwright":true,"azure_mcp":true,"context7":false}}' > "$hg/secrets.json"
python3 - "$cf" "$hg/secrets.json" <<'PY'
import json,subprocess,sys
cf, cfg = sys.argv[1], sys.argv[2]
out = subprocess.run(["python3", f"{cf}/claude/mcp/build_servers.py", cfg, "g"],
                     capture_output=True, text=True, check=True).stdout
d = json.loads(out)
assert list(d) == ["context7"], d
print("ok profile-g mcp")
PY
```

В `skills/tools/test-statusline.sh`, перед финальной строкой `echo "PASS test-statusline"`, вставить:

```bash
# profile g renders its own badge colour (not the unknown-profile yellow)
out_g="$(printf '%s' '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}' | bash "$cf/claude/statusline/statusline.sh" g)"
out_x="$(printf '%s' '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}' | bash "$cf/claude/statusline/statusline.sh" zzz)"
chk "g badge is present"        bash -c 'printf "%s" "$1" | grep -qF "[g]"' _ "$out_g"
chk "g badge is not the unknown colour" bash -c '
  g="$(printf "%s" "$1" | sed -n "s/.*\\(\\x1b\\[1;[0-9]*m\\)\\[g\\].*/\\1/p")"
  x="$(printf "%s" "$2" | sed -n "s/.*\\(\\x1b\\[1;[0-9]*m\\)\\[zzz\\].*/\\1/p")"
  [ -n "$g" ] && [ "$g" != "$x" ]' _ "$out_g" "$out_x"
```

- [ ] **Step 2: Прогнать тесты, убедиться что падают**

Run: `bash skills/tools/test-settings.sh; bash skills/tools/test-statusline.sh`

Expected: `test-settings` падает на отсутствующем `settings.g.template.json`; `test-statusline` падает на `g badge is not the unknown colour`.

- [ ] **Step 3: Создать `claude/settings/settings.g.template.json`**

```json
{
  "model": "opus[1m]",
  "effortLevel": "xhigh",
  "theme": "auto",
  "tui": "fullscreen",
  "statusLine": {
    "type": "command",
    "command": "<STATUSLINE_PATH> g",
    "padding": 2
  },
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "paplay <SOUND_PATH> >/dev/null 2>&1", "async": true } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "paplay <SOUND_PATH> >/dev/null 2>&1", "async": true } ] }
    ]
  }
}
```

- [ ] **Step 4: Правка `claude/mcp/build_servers.py:23`**

Было:

```python
if profile == "vanilla":                 # vanilla always ships context7 only, regardless of flags
```

Стало:

```python
if profile in ("vanilla", "g"):          # vanilla and g always ship context7 only, regardless of flags
```

- [ ] **Step 5: Правка `claude/statusline/statusline.sh:52-56`**

Было:

```bash
case "$prof" in
  vanilla) pcol=$'\033[1;36m' ;;
  super)   pcol=$'\033[1;35m' ;;
  *)       pcol=$'\033[1;33m' ;;
esac
```

Стало:

```bash
case "$prof" in
  vanilla) pcol=$'\033[1;36m' ;;
  super)   pcol=$'\033[1;35m' ;;
  g)       pcol=$'\033[1;32m' ;;
  *)       pcol=$'\033[1;33m' ;;
esac
```

- [ ] **Step 6: Прогнать тесты, убедиться что проходят**

Run: `bash skills/tools/test-settings.sh; bash skills/tools/test-statusline.sh`

Expected: `PASS test-settings` и `PASS test-statusline`.

- [ ] **Step 7: Commit**

```bash
git add claude/settings/settings.g.template.json claude/mcp/build_servers.py claude/statusline/statusline.sh skills/tools/test-settings.sh skills/tools/test-statusline.sh
git commit -m "feat(profile-g): settings template, context7-only MCP, own badge colour"
```

---

### Task 4: Зависимость `bun` в `deps`

**Files:**
- Modify: `lib/deps.sh:67-83`
- Test: `skills/tools/test-deps.sh`

**Interfaces:**
- Consumes: `dep_require` (`lib/deps.sh:37`).
- Produces: `deps_apply <ctx7> <playwright> <azure> <ado> <dotnet> <codex> <gstack>` — седьмой параметр опционален, по умолчанию `false`. Всегда возвращает 0.

- [ ] **Step 1: Написать падающий тест**

В `skills/tools/test-deps.sh`, перед финальной строкой отчёта (`[ "$fails" -eq 0 ] && echo "PASS test-deps" || ...`), вставить четыре кейса. Файл уже даёт всё нужное: `mk_sandbox` (`skills/tools/test-deps.sh:23`) ставит `PATH="$BIN"`, то есть `bun` в песочнице отсутствует детерминированно, независимо от машины; `present bun` его добавляет; `load` пересоединяет модули; `$PACLOG` пишет фейковый `pacman`.

```bash
# N: gstack on -> bun is missing on the isolated PATH, so pacman is offered it
mk_sandbox; fake_pacman; fake_sudo
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply false false false false false false true <<< "y"
chk "gstack on -> pacman installs bun" haspac "pacman -S --needed --noconfirm bun" "$PACLOG"

# O: gstack off -> bun never mentioned
mk_sandbox; fake_pacman; fake_sudo
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply false false false false false false false <<< "y"
chk "gstack off -> bun not offered" nogrep_i "bun" "$PACLOG"

# P: bun already present -> nothing offered
mk_sandbox; fake_pacman; fake_sudo; present bun
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply false false false false false false true <<< "y"
chk "bun present -> pacman not called" isempty "$PACLOG"

# Q: the seventh parameter keeps the non-fatal contract; the legacy 6-arg call still works
mk_sandbox; fake_pacman; fake_sudo
load; export CLAUDEFILES_ASSUME_TTY=0
( set -e; deps_apply false false false false false false true ); rc=$?
chk "7-arg deps_apply returns 0 under set -e" [ "$rc" -eq 0 ]
( set -e; deps_apply false false false false false false ); rc=$?
chk "6-arg legacy call still returns 0"       [ "$rc" -eq 0 ]
```

- [ ] **Step 2: Прогнать тест, убедиться что падает**

Run: `bash skills/tools/test-deps.sh`

Expected: FAIL на `gstack=true offers bun` (седьмой аргумент пока игнорируется).

- [ ] **Step 3: Расширить `deps_apply`**

`lib/deps.sh:67-68` — заменить сигнатуру и разбор:

```bash
deps_apply() {   # <ctx7> <playwright> <azure> <ado> <dotnet> <codex> <gstack> — offer-install each needed dep; always 0
  local ctx7="${1:-false}" pw="${2:-false}" azure="${3:-false}" ado="${4:-false}" dotnet="${5:-false}" codex="${6:-false}" gstack="${7:-false}"
```

Перед завершающим `return 0` (`lib/deps.sh:82`) добавить блок:

```bash
  if [ "$gstack" = true ]; then
    dep_require "gstack installer (its setup exits without bun)" bun -- bun
  fi
```

- [ ] **Step 4: Прогнать тест, убедиться что проходит**

Run: `bash skills/tools/test-deps.sh`

Expected: `PASS test-deps`.

- [ ] **Step 5: Commit**

```bash
git add lib/deps.sh skills/tools/test-deps.sh
git commit -m "feat(deps): bun dependency behind the gstack flag"
```

---

### Task 5: `recipe_g` и проводка в `setup.sh`

Собирает всё предыдущее в работающий профиль и включает vision-блок в `super`.

**Files:**
- Modify: `lib/profiles.sh:16-36` (`recipe_super`), добавить `recipe_g` после него
- Modify: `setup.sh:5`, `setup.sh:12-43`, `setup.sh:47-56`, `setup.sh:66-67`, `setup.sh:82`
- Test: `skills/tools/test-profiles.sh`, `skills/tools/test-multiprofile.sh`

**Interfaces:**
- Consumes: `settings_apply`, `skills_apply`, `claudemd_apply`, `claudemd_personal_apply`, `claudemd_vision_apply` (Task 1), `gstack_apply` (Task 2), `mcp_apply`, `_mcp_manifest`, `config_flag`, `profile_dir`.
- Produces: `recipe_g <repo_root>` — возвращает 0 при успехе, 1 при провале `gstack_apply`; флаг `flags.profile_gstack` в `secrets.json`; профиль `g` в массиве `selected`.

- [ ] **Step 1: Написать падающий тест**

В конец `skills/tools/test-profiles.sh`, перед `echo "PASS test-profiles"`, вставить:

```bash
# --- profile g: dir mapping, recipe writes to ~/.claude-g, gstack failure fails the profile ---
setup_fixture_home >/dev/null; hg="$HOME"
[ "$(profile_dir g)" = "$hg/.claude-g" ] || { echo FAIL dir-g; exit 1; }
mkdir -p "$hg/.config/claudefiles"
cat > "$hg/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"profile_gstack":true,"context7":false,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false},"context7_api_key":"" }
EOF

# gstack_apply is stubbed here: this test owns the WIRING, test-gstack.sh owns the module.
gstack_apply() { : > "${CLAUDEFILES_TARGET:?}/.gstack-called"; return 0; }
provision_selected "$cf" g
[ "${#PROVISION_FAILED[@]}" -eq 0 ] || { echo FAIL g-recipe-failed; exit 1; }
[ -f "$hg/.claude-g/.gstack-called" ] || { echo FAIL g-gstack-not-called; exit 1; }
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["model"]=="opus[1m]";assert "enabledPlugins" not in d;print("ok g-recipe")' "$hg/.claude-g/settings.json"
[ -f "$hg/.claude-g/skills/context7-mcp/SKILL.md" ] || { echo FAIL g-skill; exit 1; }
grep -q "claudefiles:personal" "$hg/.claude-g/CLAUDE.md" || { echo FAIL g-personal; exit 1; }
grep -q "claudefiles:vision"   "$hg/.claude-g/CLAUDE.md" || { echo FAIL g-vision; exit 1; }
grep -q "docs/vision/"         "$hg/.claude-g/CLAUDE.md" || { echo FAIL g-vision-path; exit 1; }
[ -f "$hg/.local/bin/claude-g" ] || { echo FAIL g-wrapper; exit 1; }
[ -e "$hg/.claude/skills/gstack" ] && { echo FAIL g-leaked-into-default; exit 1; }
[ -f "$hg/.config/claudefiles/managed-mcp.g.json" ] || { echo FAIL g-mcp-manifest; exit 1; }
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert list(d)==["context7"],d' "$hg/.config/claudefiles/managed-mcp.g.json"

# a failing gstack_apply must fail exactly this profile
setup_fixture_home >/dev/null; hgf="$HOME"
mkdir -p "$hgf/.config/claudefiles"
cat > "$hgf/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"profile_gstack":true,"context7":false,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false},"context7_api_key":"" }
EOF
gstack_apply() { return 1; }
provision_selected "$cf" vanilla g
printf '%s\n' "${PROVISION_FAILED[@]:-}" | grep -qx g || { echo FAIL g-failure-not-recorded; exit 1; }
printf '%s\n' "${PROVISION_FAILED[@]:-}" | grep -qx vanilla && { echo FAIL vanilla-collateral; exit 1; }
unset -f gstack_apply
```

- [ ] **Step 2: Прогнать тест, убедиться что падает**

Run: `env -u CLAUDE_CONFIG_DIR bash skills/tools/test-profiles.sh`

Expected: FAIL `dir-g` или `recipe_g: command not found`.

- [ ] **Step 3: Добавить `recipe_g` и vision-блок в `recipe_super`**

В `lib/profiles.sh`, внутри `recipe_super`, сразу после строки `claudemd_personal_apply false` (`lib/profiles.sh:23`) добавить:

```bash
  # consume the vision doc only when the profile that produces it is installed
  if [ "$(config_flag profile_gstack)" = true ]; then claudemd_vision_apply consumer; else claudemd_vision_apply off; fi
```

После закрывающей скобки `recipe_super` добавить:

```bash
recipe_g() { # <repo_root>  (caller exports CLAUDEFILES_TARGET + CLAUDE_CONFIG_DIR)
  local root="$1"
  settings_apply "$root/claude/settings/settings.g.template.json" false false
  skills_apply "$root" false false
  claudemd_apply false                 # no codex nudge in the vision profile
  claudemd_personal_apply true
  claudemd_vision_apply producer
  # gstack IS this profile: without it `g` is an empty shell, exactly like super without
  # superpowers (see the P1a check above). Fail the profile rather than report a hollow success.
  gstack_apply || { warn "g: gstack_apply failed — marking profile failed"; return 1; }
  local servers; servers="$(python3 "$root/claude/mcp/build_servers.py" "$(config_path)" g)"
  mcp_apply "$servers" "$(_mcp_manifest g)"
}
```

- [ ] **Step 4: Проводка в `setup.sh`**

`setup.sh:5` — добавить `gstack` в список загружаемых модулей:

```bash
for m in common config deps settings skills plugins mcp claudemd gstack profiles; do source "$ROOT/lib/$m.sh"; done
```

`setup.sh:39` — добавить вопрос про профиль перед общим вопросом про `context7`:

```bash
  config_ensure_flag profile_gstack "Install the 'g' profile (gstack, vision stage)? (y/N)"
  config_ensure_flag context7      "Enable Context7 MCP? (y/N)"
```

`setup.sh:47-56` — добавить флаг и седьмой аргумент:

```bash
super_sel=false; [ "$(config_flag profile_super)" = true ] && super_sel=true
g_sel=false;     [ "$(config_flag profile_gstack)" = true ] && g_sel=true
```

и ниже:

```bash
deps_apply "$c7_dep" "$pw_dep" "$az_dep" "$ado_dep" "$dn_dep" "$cr_dep" "$g_sel"
```

`setup.sh:66-67` — добавить профиль в состав:

```bash
selected=(vanilla)
[ "$super_sel" = true ] && selected+=(super)
[ "$g_sel" = true ] && selected+=(g)
```

`setup.sh:82` — итоговая строка:

```bash
log "Done. \`claude\` = vanilla$( [ "$super_sel" = true ] && printf '%s' '; `claude-super` = full stack' )$( [ "$g_sel" = true ] && printf '%s' '; `claude-g` = gstack (vision)' )."
```

- [ ] **Step 5: Прогнать тест профилей**

Run: `env -u CLAUDE_CONFIG_DIR bash skills/tools/test-profiles.sh`

Expected: `PASS test-profiles`.

- [ ] **Step 6: Расширить сквозной тест на три профиля**

В `skills/tools/test-multiprofile.sh` в фикстуре `secrets.json` (`skills/tools/test-multiprofile.sh:16-19`) добавить `"profile_gstack":false` в объект `flags`, чтобы прогон не зависал на вопросе без TTY. Затем в конец файла, перед финальным `echo`, добавить:

```bash
# profile_gstack=false -> no g dir, no wrapper, and super carries no vision block
[ -e "$h/.claude-g" ] && { echo FAIL g-dir-created-when-off; exit 1; }
[ -e "$h/.local/bin/claude-g" ] && { echo FAIL g-wrapper-created-when-off; exit 1; }
grep -q "claudefiles:vision" "$h/.claude-super/CLAUDE.md" && { echo FAIL super-vision-when-g-off; exit 1; }
```

Профиль `g` в этом тесте намеренно выключен: сквозной прогон `setup.sh` с включённым `g` потребовал бы сети и настоящего `bun`. Идемпотентность самого `g` покрыта иначе — кейсом D в `test-gstack.sh` (повторный вызов при неподвижном апстриме не запускает инсталлятор) и живым смоуком из Task 6.

- [ ] **Step 7: Прогнать весь сьют**

Run: `env -u CLAUDE_CONFIG_DIR bash skills/tools/run-all-tests.sh 2>&1 | grep -E "^(=== |FAIL|PASS|SOME|ALL)"`

Expected: `ALL TESTS PASSED`.

- [ ] **Step 8: Commit**

```bash
git add lib/profiles.sh setup.sh skills/tools/test-profiles.sh skills/tools/test-multiprofile.sh
git commit -m "feat(profile-g): recipe_g, orchestrator wiring, vision handoff into super"
```

---

### Task 6: Живой смоук и документация

Юнит-тесты гоняются против фикстурного апстрима, поэтому настоящий gstack ни разу не ставился. Задача закрывает этот разрыв и приводит документацию в соответствие.

**Files:**
- Create: `skills/tools/smoke-gstack.sh`
- Modify: `README.md`, `docs/architecture.md`, `docs/runtime.md`, `docs/user-flow.md`, `docs/invariants.md`, `docs/config-schema.md`

**Interfaces:**
- Consumes: `gstack_apply` (Task 2), реальную сеть и реальный `bun`.
- Produces: `skills/tools/smoke-gstack.sh` — подхватывается циклом `smoke-*.sh` в `run-all-tests.sh:19`.

- [ ] **Step 1: Написать смоук против настоящего апстрима**

Создать `skills/tools/smoke-gstack.sh`:

```bash
#!/usr/bin/env bash
# smoke-gstack.sh — verify the REAL upstream installer against a throwaway profile dir.
# Needs network and bun; skips loudly (exit 0) when either is absent, like the other smokes.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
fails=0
chk() { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }

command -v bun >/dev/null 2>&1 || { echo "SKIP smoke-gstack (no bun)"; exit 0; }
git ls-remote --exit-code https://github.com/garrytan/gstack.git HEAD >/dev/null 2>&1 \
  || { echo "SKIP smoke-gstack (upstream unreachable)"; exit 0; }

source "$cf/lib/common.sh"; source "$cf/lib/gstack.sh"
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export CLAUDEFILES_TARGET="$SB/.claude-g"
before="$(ls -1 "$HOME/.claude/skills" 2>/dev/null | sort)"

gstack_apply; rc=$?
chk "real install returns 0"       [ "$rc" -eq 0 ]
chk "clone present"                [ -d "$CLAUDEFILES_TARGET/skills/gstack/.git" ]
chk "marker written"               [ -s "$CLAUDEFILES_TARGET/.gstack-setup-head" ]
chk "skills linked in the profile" bash -c 'ls -1 "$1/skills" | grep -qE "^gstack"' _ "$CLAUDEFILES_TARGET"
chk "office-hours skill reachable" bash -c 'ls -1 "$1/skills" | grep -q "office-hours"' _ "$CLAUDEFILES_TARGET"

after="$(ls -1 "$HOME/.claude/skills" 2>/dev/null | sort)"
chk "real ~/.claude/skills untouched" [ "$before" = "$after" ]

marker_before="$(cat "$CLAUDEFILES_TARGET/.gstack-setup-head")"
listing_before="$(ls -1 "$CLAUDEFILES_TARGET/skills" | sort)"
gstack_apply; rc=$?
chk "second run returns 0"         [ "$rc" -eq 0 ]
chk "second run leaves the marker"  [ "$(cat "$CLAUDEFILES_TARGET/.gstack-setup-head")" = "$marker_before" ]
chk "second run leaves the skills"  [ "$(ls -1 "$CLAUDEFILES_TARGET/skills" | sort)" = "$listing_before" ]

[ "$fails" -eq 0 ] && echo "PASS smoke-gstack" || { echo "SOME smoke-gstack CASES FAILED"; exit 1; }
```

- [ ] **Step 2: Прогнать смоук**

Run: `env -u CLAUDE_CONFIG_DIR bash skills/tools/smoke-gstack.sh`

Expected: `PASS smoke-gstack`, либо строка `SKIP smoke-gstack (...)` с кодом 0, если нет bun или сети. Если получился `FAIL`, останови работу и разбери причину: значит реальный инсталлятор ведёт себя не так, как предполагала спека.

- [ ] **Step 3: Обновить `README.md`**

- Первый абзац: добавить третий профиль в перечисление.
- Таблица «Профили»: строка `**g** | ~/.claude-g (по флагу profile_gstack) | claude-g | gstack (23 скилла), та же ванильная база (статуслайн с бейджем, звук, context7 MCP, личный marker-блок), плюс marker-блок про docs/vision; model: opus[1m], effortLevel: xhigh; без плагинов и без SessionStart-хука`.
- Раздел «Что делает `setup.sh`»: в пункте 2 добавить `profile_gstack` в список опрашиваемых флагов; в пункт 4 добавить рецепт `g`.
- Таблица «Системные зависимости»: строка `bun | bun | инсталлятор gstack (его setup выходит без bun) | profile_gstack`.
- Новый раздел «Профиль g (этап видения)» после раздела про Codex-ревью: граница ответственности с super, передача через `docs/vision/`, где лежит клон, что обновление автоматическое и гейтится по SHA, что `~/.gstack` не под управлением claudefiles.
- Раздел «Раскладка»: добавить `lib/gstack.sh` и `claude/settings/settings.g.template.json`.

- [ ] **Step 4: Обновить диаграммы `docs/architecture.md`**

- «Компоненты по слоям»: узел `gstack["gstack.sh"]` в подграф `appliers`, ребро `prof --> gstack`.
- «Прогон setup.sh»: в цикле рецептов упомянуть, что `recipe_g` возвращает fail при провале `gstack_apply`.
- «Рецепты»: третий подграф `G["recipe_g (~/.claude-g)"]` с цепочкой `settings_apply (g tmpl) → skills_apply (f, f) → claudemd_apply false → personal true → vision producer → gstack_apply → mcp_apply`.
- «Потоки данных»: ребро `gstack["gstack.sh"] --> gclone[("skills/gstack + .gstack-setup-head")]`.

- [ ] **Step 5: Обновить остальные доки**

- `docs/runtime.md`: подграф «Только g» — gstack-скиллы, context7, отсутствие SessionStart-хука; в общий подграф ничего не добавляется (статуслайн и звук уже там).
- `docs/user-flow.md`: ветка опроса `profile_gstack` и третий выход `claude-g -> gstack`.
- `docs/invariants.md`: строка про контракт фатальности — `gstack_apply` при провале роняет профиль `g`, но не `vanilla` и не `super`; тест-источники `test-gstack.sh`, `test-profiles.sh`.
- `docs/config-schema.md`: `profile_gstack` в список булевых флагов.

- [ ] **Step 6: Финальная проверка**

Run: `env -u CLAUDE_CONFIG_DIR bash skills/tools/run-all-tests.sh 2>&1 | grep -E "^(=== |FAIL|PASS|SKIP|SOME|ALL)"`

Expected: `ALL TESTS PASSED`, среди строк присутствуют `PASS test-gstack` и `PASS smoke-gstack` (или его `SKIP`).

- [ ] **Step 7: Commit**

```bash
git add skills/tools/smoke-gstack.sh README.md docs/architecture.md docs/runtime.md docs/user-flow.md docs/invariants.md docs/config-schema.md
git commit -m "docs: three profiles, gstack install contract, live smoke"
```

---

## Проверка вживую (после Task 6)

Юнит-тесты и смоук не заменяют один настоящий прогон на этой машине:

```bash
./setup.sh                      # ответить y на вопрос про профиль g
./setup.sh                      # второй прогон обязан быть без diff и выйти 0
git -C ~/.claude-g/skills/gstack rev-parse HEAD
cat ~/.claude-g/.gstack-setup-head        # должны совпасть
claude-g                                   # бейдж [g], gstack-скиллы доступны
```
