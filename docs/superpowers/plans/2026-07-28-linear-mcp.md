# Linear MCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дать `setup.sh` флаг `flags.linear`, который ставит удалённый HTTP-сервер Linear MCP во все выбранные профили и доводит его до авторизованного состояния.

**Architecture:** Конфигурация сервера идёт по существующему пути (флаг → `build_servers.py` → `mcp_apply` → манифест) и не требует ни секретов, ни новых системных зависимостей: Linear это `{"type":"http","url":"https://mcp.linear.app/mcp"}` с OAuth. Логин выносится отдельной фазой `setup.sh` после провижна и после проверки упавших профилей — браузерный OAuth посреди установки не должен иметь возможности уронить профиль. Фаза гейтится строкой `Needs authentication` в выводе `claude mcp get linear`, поэтому на уже авторизованной машине она молчит.

**Tech Stack:** bash 5 под `set -euo pipefail`, python3 для JSON, существующий фикстурный тест-харнесс `skills/tools/lib/faketools.bash`.

**Спека:** `docs/superpowers/specs/2026-07-28-linear-mcp-design.md`

## Global Constraints

- Все модули в `lib/` это библиотеки: `Source, don't execute.` в шапке, никакого кода верхнего уровня кроме объявлений.
- `setup.sh` работает под `set -euo pipefail`. Ни одна новая функция не роняет прогон непреднамеренно: ненулевой возврат это всегда осознанное решение. `mcp_linear_login` не возвращает ненулевой код никогда.
- Строки, которые видит пользователь в шелле, английские. Русский только в `docs/` и `README.md`.
- Комментарии в стиле репозитория: объясняют ПОЧЕМУ, а не что делает строка. Плотность как в соседних модулях. Новых комментариев не добавлять там, где код и так очевиден.
- `log`/`warn`/`die` из `lib/common.sh`, никаких голых `echo` в модулях.
- Пути к профилям только через `profile_dir`, к конфигу только через `config_path`, к манифестам только через `_mcp_manifest`.
- `lib/mcp.sh` не имеет права зависеть от `lib/deps.sh`: `test-mcp.sh:5` и `test-profiles.sh:7` подключают `mcp.sh` без него. Доступность CLI проверять через `claude_bin` (`lib/common.sh:6`).
- URL сервера ровно `https://mcp.linear.app/mcp`, тип ровно `http`, имя сервера ровно `linear`. Никаких заголовков, `env` и API-ключей.
- Тесты: bash-скрипты `skills/tools/test-*.sh`, падение через `{ echo "FAIL <что>"; exit 1; }`, последняя строка `echo "PASS <имя>"`. Вся сьюта: `bash skills/tools/run-all-tests.sh`.
- Тесты никогда не трогают реальный `~/.claude`: только `setup_fixture_home` из `faketools.bash`, вызванный НЕ в подстановке команд (`h="$(setup_fixture_home)"` это баг).
- Ни один тест не ходит в сеть: весь `claude` в тестах это фейк из `faketools.bash`.

## Файловая структура

| Файл | Ответственность | Задача |
|---|---|---|
| `claude/mcp/build_servers.py` | сборка `{имя: конфиг}` из `secrets.json`; добавляется `linear`, ветка vanilla/g перестаёт быть early-exit | 1 |
| `skills/tools/lib/faketools.bash` | фейковый `claude`; учится `mcp get` (статус) и `mcp login` (лог + `CLAUDE_CONFIG_DIR`) | 2, 4 |
| `lib/mcp.sh` | новая `mcp_linear_login` — единственное место, где живёт знание про OAuth-гейт | 2 |
| `setup.sh` | вопрос про флаг в `config_ensure_all`; фаза логина после `verify` | 3, 4 |
| `skills/tools/test-mcp.sh` | юнит-проверки `build_servers.py` и `mcp_linear_login` | 1, 2 |
| `skills/tools/test-multiprofile.sh` | сквозной прогон `setup.sh`: фаза логина по профилям | 3, 4 |
| `skills/tools/test-setup-idempotent.sh` | фикстуры с посеянным `secrets.json` | 3 |
| `README.md`, `docs/config-schema.md`, `docs/runtime.md`, `docs/user-flow.md` | документация | 5 |

---

### Task 1: `linear` в наборе серверов

**Files:**
- Modify: `claude/mcp/build_servers.py:21-46`
- Test: `skills/tools/test-mcp.sh` (дописать в конец, перед `echo "PASS test-mcp"`)

**Interfaces:**
- Consumes: ничего от других задач.
- Produces: `build_servers.py <secrets> [profile]` печатает JSON-объект, в котором при `flags.linear: true` есть ключ `linear` со значением ровно `{"type": "http", "url": "https://mcp.linear.app/mcp"}`. Профиль `vanilla`/`g` печатает `context7` всегда; `super` (без второго аргумента) — по флагам.

- [ ] **Step 1: Написать падающие проверки**

Дописать в `skills/tools/test-mcp.sh` ПЕРЕД последней строкой `echo "PASS test-mcp"`:

```bash
# --- linear: a remote HTTP server behind a flag, no secrets ---------------------
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"context7":false,"playwright":false,"azure_mcp":false,"ado":false,"linear":true},"context7_api_key":"" }
EOF
python3 "$cf/claude/mcp/build_servers.py" "$(config_path)" vanilla | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert sorted(d)==["context7","linear"], d
assert d["linear"]=={"type":"http","url":"https://mcp.linear.app/mcp"}, d["linear"]
print("ok vanilla-linear")'
python3 "$cf/claude/mcp/build_servers.py" "$(config_path)" g | python3 -c '
import json,sys
d=json.load(sys.stdin); assert sorted(d)==["context7","linear"], d; print("ok g-linear")'
# super: every flag but linear is off -> exactly one server
python3 "$cf/claude/mcp/build_servers.py" "$(config_path)" | python3 -c '
import json,sys
d=json.load(sys.stdin); assert list(d)==["linear"], d; print("ok super-linear")'
# the context7 api key still reaches args after the refactor
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"context7":true,"playwright":false,"azure_mcp":false,"ado":false,"linear":false},"context7_api_key":"KEY1" }
EOF
python3 "$cf/claude/mcp/build_servers.py" "$(config_path)" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert list(d)==["context7"], d
assert d["context7"]["args"][-2:]==["--api-key","KEY1"], d["context7"]
print("ok super-c7-key")'
python3 "$cf/claude/mcp/build_servers.py" "$(config_path)" vanilla | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert list(d)==["context7"], d
assert d["context7"]["args"][-2:]==["--api-key","KEY1"], d["context7"]
print("ok vanilla-c7-key")'
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `bash skills/tools/test-mcp.sh`
Expected: FAIL с `AssertionError` на первой же проверке (`sorted(d)==["context7","linear"]`, реально `['context7']`).

- [ ] **Step 3: Реализовать**

Заменить в `claude/mcp/build_servers.py` весь блок со строки 21 (`servers = {}`) по строку 46 (`print(json.dumps(servers))`) на:

```python
LINEAR = {"type": "http", "url": "https://mcp.linear.app/mcp"}

def context7_cfg():
    args = ["-y", "@upstash/context7-mcp"]
    if cfg.get("context7_api_key"):
        args += ["--api-key", cfg["context7_api_key"]]
    return {"type": "stdio", "command": "npx", "args": args}

servers = {}
profile = sys.argv[2] if len(sys.argv) > 2 else "all"
if profile in ("vanilla", "g"):          # vanilla and g always ship context7, regardless of flags
    servers["context7"] = context7_cfg()
    if on("linear"):
        servers["linear"] = LINEAR
    print(json.dumps(servers))
    sys.exit(0)
if on("playwright"):
    servers["playwright"] = {"type":"stdio","command":"npx",
        "args":["-y","@playwright/mcp@latest","--executable-path", chromium_path()]}
if on("context7"):
    servers["context7"] = context7_cfg()
if on("azure_mcp"):
    servers["azure"] = {"type":"stdio","command":"npx","args":["-y","@azure/mcp@latest","server","start"]}
if on("ado"):
    ado = cfg.get("ado", {}); email = ado.get("email","")
    for org in ado.get("orgs", []):
        pat = ado.get("pat", {}).get(org, "")
        token = base64.b64encode(f"{email}:{pat}".encode()).decode()
        servers[f"azureDevOps-{org}"] = {"type":"stdio","command":"npx",
            "args":["-y","@azure-devops/mcp",org,"--authentication","pat"],
            "env":{"PERSONAL_ACCESS_TOKEN":token}}
if on("linear"):
    servers["linear"] = LINEAR
print(json.dumps(servers))
```

- [ ] **Step 4: Убедиться, что тест проходит**

Run: `bash skills/tools/test-mcp.sh`
Expected: PASS, в выводе есть `ok vanilla-linear`, `ok g-linear`, `ok super-linear`, `ok super-c7-key`, `ok vanilla-c7-key`.

- [ ] **Step 5: Прогнать соседей, которых мог задеть рефакторинг**

Run: `bash skills/tools/test-profiles.sh && bash skills/tools/test-multiprofile.sh`
Expected: обе строки `PASS ...`. Эти тесты проверяют, что vanilla и g по-прежнему получают ровно `["context7"]` без флага.

- [ ] **Step 6: Коммит**

```bash
git add claude/mcp/build_servers.py skills/tools/test-mcp.sh
git commit -m "feat(linear): сервер linear в build_servers.py по флагу"
```

---

### Task 2: `mcp_linear_login` — гейт на статусе

**Files:**
- Modify: `skills/tools/lib/faketools.bash:23-40` (тело фейкового `claude`)
- Modify: `lib/mcp.sh` (дописать функцию в конец файла)
- Test: `skills/tools/test-mcp.sh` (дописать в конец, перед `echo "PASS test-mcp"`)

**Interfaces:**
- Consumes: `claude_bin` (`lib/common.sh:6`), `config_flag` и `_has_tty` (`lib/config.sh:15-20`), `log`/`warn` (`lib/common.sh:2-3`).
- Produces: `mcp_linear_login <profile>` — всегда `return 0`. Зовёт `claude mcp login linear` тогда и только тогда, когда `flags.linear` истинный, CLI доступен, `claude mcp get linear` вышел с нулём и напечатал `Needs authentication`, и `_has_tty` истинный. Задача 4 зовёт её из `setup.sh`.
- Produces (тест-харнесс): фейковый `claude` понимает `mcp get <name>` (три исхода: `Needs authentication` по умолчанию, `Connected` при `CLAUDE_FAKE_MCP_AUTH=ok`, ненулевой код если сервера нет в состоянии фейка) и `mcp login <name>` (пишет в лог строку `mcp login <name> CLAUDE_CONFIG_DIR=<dir>`).

- [ ] **Step 1: Научить фейковый `claude` двум подкомандам**

В `skills/tools/lib/faketools.bash` заменить строку 25 (`echo "$*" >> "$CLAUDE_FAKE_LOG"`) на:

```bash
# mcp login is the only branch whose CLAUDE_CONFIG_DIR matters: the fake's state is one per
# fixture HOME, so without the dir a test cannot tell "logged in per selected profile" from
# "logged in three times into the default dir". Appending keeps every existing substring assert.
if [ "$1 $2" = "mcp login" ]; then
  echo "$* CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-}" >> "$CLAUDE_FAKE_LOG"
else
  echo "$*" >> "$CLAUDE_FAKE_LOG"
fi
```

И добавить в `case "$1 $2" in` (перед строкой `*) : ;;`) две ветки:

```bash
  "mcp get")            # the three real outcomes: needs auth, connected, no such server (non-zero)
    if grep -qxF "$3" "$S/mcp" 2>/dev/null; then
      printf '%s:\n  Scope: User config (available in all your projects)\n' "$3"
      if [ "${CLAUDE_FAKE_MCP_AUTH:-needs}" = ok ]; then printf '  Status: ✔ Connected\n'
      else printf '  Status: ! Needs authentication\n'; fi
    else
      printf 'No MCP server found with name: %s\n' "$3"; exit 1
    fi ;;
  "mcp login")          # logged above, including CLAUDE_CONFIG_DIR; nothing else to do
    : ;;
```

Формулировки статусов взяты с живого `claude mcp get` (2.1.220), а не придуманы: `Status: ✔ Connected`
на рабочем сервере, `Status: ! Needs authentication` на неавторизованном.

- [ ] **Step 2: Написать падающие проверки**

Дописать в `skills/tools/test-mcp.sh` ПЕРЕД последней строкой `echo "PASS test-mcp"`:

```bash
# --- mcp_linear_login: login exactly when the CLI said auth is needed -----------
cb="$(claude_bin)"
"$cb" mcp add-json --scope user linear '{"type":"http","url":"https://mcp.linear.app/mcp"}' >/dev/null

printf '%s' '{"flags":{"linear":false}}' > "$h/.config/claudefiles/secrets.json"
: > "$CLAUDE_FAKE_LOG"
CLAUDEFILES_ASSUME_TTY=1 mcp_linear_login vanilla
grep -q "mcp " "$CLAUDE_FAKE_LOG" && { echo FAIL login-touched-cli-with-flag-off; exit 1; }

printf '%s' '{"flags":{"linear":true}}' > "$h/.config/claudefiles/secrets.json"
: > "$CLAUDE_FAKE_LOG"
CLAUDEFILES_ASSUME_TTY=1 mcp_linear_login vanilla
grep -q "mcp login linear" "$CLAUDE_FAKE_LOG" || { echo FAIL no-login-when-needed; exit 1; }

: > "$CLAUDE_FAKE_LOG"
CLAUDE_FAKE_MCP_AUTH=ok CLAUDEFILES_ASSUME_TTY=1 mcp_linear_login vanilla
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL login-when-already-authed; exit 1; }

: > "$CLAUDE_FAKE_LOG"
CLAUDEFILES_ASSUME_TTY=0 mcp_linear_login vanilla 2> "$h/linear-notty.log"
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL login-without-tty; exit 1; }
grep -q "claude mcp login linear" "$h/linear-notty.log" || { echo FAIL no-manual-hint-without-tty; exit 1; }

# drift: manifest present, server gone from the config -> `mcp get` exits non-zero. Don't log in,
# don't die, but don't stay quiet either: silence here would report success on a broken Linear.
"$cb" mcp remove --scope user linear >/dev/null 2>&1 || true
: > "$CLAUDE_FAKE_LOG"
CLAUDEFILES_ASSUME_TTY=1 mcp_linear_login vanilla 2> "$h/linear-missing.log" \
  || { echo FAIL login-nonzero-on-missing-server; exit 1; }
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL login-on-missing-server; exit 1; }
grep -q "claude mcp login linear" "$h/linear-missing.log" || { echo FAIL no-warn-on-missing-server; exit 1; }
echo "ok linear-login-gate"
```

- [ ] **Step 3: Убедиться, что тест падает**

Run: `bash skills/tools/test-mcp.sh`
Expected: FAIL с `mcp_linear_login: command not found` (тест запущен под `set -euo pipefail`, поэтому прогон обрывается на первом вызове).

- [ ] **Step 4: Реализовать функцию**

Дописать в конец `lib/mcp.sh`:

```bash
# Linear is the only managed server that needs an interactive OAuth login: add-json puts it in the
# config, `claude mcp login` makes it usable. The browser is opened only on a POSITIVE signal, but
# no branch here is silent: an unknown status (wording changed, server failed) warns instead of
# returning quietly, or a future CLI rename would switch the login off unnoticed. A non-zero
# `mcp get` means the server is missing from this profile while its manifest still lists it, so
# mcp_apply took the unchanged early-return (mcp.sh:9-13) — report the drift, don't paper over it.
# Never fatal: setup.sh runs under set -e and a browser flow must not fail a profile.
mcp_linear_login() { # mcp_linear_login <profile>
  local profile="$1" cb status rc=0 fix="run: claude mcp login linear"
  [ "$(config_flag linear)" = true ] || return 0
  cb="$(claude_bin)"
  if [ ! -x "$cb" ] && ! command -v "$cb" >/dev/null 2>&1; then
    warn "linear ($profile): claude not available — $fix"; return 0
  fi
  status="$(timeout 30 "$cb" mcp get linear 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "linear ($profile): not in this profile's config — re-run ./setup.sh, then $fix"; return 0
  fi
  case "$status" in
    *"Needs authentication"*)
      if _has_tty; then
        log "linear ($profile): opening browser to authenticate"
        timeout 300 "$cb" mcp login linear || warn "linear ($profile): login failed — $fix"
      else
        warn "linear ($profile): not authenticated — $fix"
      fi ;;
    *Connected*) : ;;
    *) warn "linear ($profile): unexpected status from 'claude mcp get linear' — $fix" ;;
  esac
  return 0
}
```

- [ ] **Step 5: Убедиться, что тест проходит**

Run: `bash skills/tools/test-mcp.sh`
Expected: PASS, в выводе есть `ok linear-login-gate`.

- [ ] **Step 6: Прогнать всю сьюту — фейковый `claude` общий для всех тестов**

Run: `bash skills/tools/run-all-tests.sh`
Expected: `ALL TESTS PASSED`. Если что-то покраснело — почти наверняка ассерт, завязанный на формат строки лога; чинить надо тест, а не откатывать `CLAUDE_CONFIG_DIR` в логе.

- [ ] **Step 7: Коммит**

```bash
git add lib/mcp.sh skills/tools/lib/faketools.bash skills/tools/test-mcp.sh
git commit -m "feat(linear): mcp_linear_login с гейтом на статусе mcp get"
```

---

### Task 3: флаг `flags.linear` в опросе

**Files:**
- Modify: `setup.sh:49-52` (внутри `config_ensure_all`)
- Modify: `skills/tools/test-setup-idempotent.sh:41-44` и `:105-109`
- Modify: `skills/tools/test-multiprofile.sh:16-19` и `:64-67`

**Interfaces:**
- Consumes: `config_ensure_flag` (`lib/config.sh:46`).
- Produces: ключ `flags.linear` в `~/.config/claudefiles/secrets.json`. Задачи 1, 2 и 4 читают его через `config_flag linear`.

- [ ] **Step 1: Добавить вопрос**

В `setup.sh` после блока context7 (строки 49-52), последней строкой внутри `config_ensure_all`:

```bash
  config_ensure_flag linear "Enable Linear MCP (issue tracker, one-time OAuth login)? (y/N)"
```

Вопрос стоит на верхнем уровне функции, а не внутри `if [ "$(config_flag profile_super)" = true ]`: флаг кросс-профильный, ровно как `context7`.

- [ ] **Step 2: Убедиться, что фикстуры покраснели**

Run: `bash skills/tools/test-multiprofile.sh`
Expected: FAIL с `ERROR: missing required flag 'flags.linear' and no TTY to prompt`. Это и есть контракт `config_ensure_flag` без TTY, а не поломка.

- [ ] **Step 3: Засеять флаг в фикстуры, которые гоняют `setup.sh` неинтерактивно**

`skills/tools/test-setup-idempotent.sh`, строка 42 — добавить `"linear":false` в конец объекта `flags`:

```bash
{ "flags": {"profile_super":true,"profile_gstack":true,"context7":true,"playwright":true,"azure_mcp":false,"ado":false,"dotnet_skills":true,"codex_review":true,"codex_plugin":false,"linear":false},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
```

`skills/tools/test-multiprofile.sh`, строка 17:

```bash
{ "flags":{"profile_super":true,"profile_gstack":false,"context7":true,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false,"linear":false},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
```

`skills/tools/test-multiprofile.sh`, строка 65:

```bash
{ "flags":{"profile_super":false,"profile_gstack":false,"context7":false,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false,"linear":false},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
```

`skills/tools/test-profiles.sh` НЕ трогать: он подключает модули и зовёт рецепты напрямую, минуя `config_ensure_all`.

- [ ] **Step 4: Поправить строку ответов интерактивного clean-прогона**

`skills/tools/test-setup-idempotent.sh`, строки 105-108. Новый вопрос задаётся сразу после ключа context7, поэтому ответ на него вставляется одиннадцатым. Молчание не подходит: хвостовые пустые строки поглотили бы вопрос и записали `false` незаметно для читателя теста. Заменить комментарий и `printf` на:

```bash
# answers: confirm word, super y, dotnet y, codex_review y, codex_plugin n, playwright y,
# azure n, ado n, gstack y, context7 y, context7 key (empty), linear n. Trailing blanks absorb
# any dep prompt that a non-provisioned box might raise AFTER the config phase.
printf 'clean\ny\ny\ny\nn\ny\nn\nn\ny\ny\n\nn\n\n\n\n' | \
```

`linear n` держит clean-прогон согласованным с посеянным `"linear":false` из первой половины теста — только при одинаковых ответах сравнение `diff "$h/first.json"` вообще что-то значит.

- [ ] **Step 5: Убедиться, что сьюта зелёная**

Run: `bash skills/tools/run-all-tests.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 6: Проверить, что вопрос реально задаётся**

Run:
```bash
tmp="$(mktemp -d)"; HOME="$tmp" CLAUDEFILES_ASSUME_TTY=1 \
  bash -c 'source lib/common.sh; source lib/config.sh; config_ensure_flag linear "Enable Linear MCP (issue tracker, one-time OAuth login)? (y/N)"' <<< "y"
python3 -c 'import json;print(json.load(open("'"$tmp"'/.config/claudefiles/secrets.json")))'; rm -rf "$tmp"
```
Expected: печатает `{'flags': {'linear': True}}`.

- [ ] **Step 7: Коммит**

```bash
git add setup.sh skills/tools/test-setup-idempotent.sh skills/tools/test-multiprofile.sh
git commit -m "feat(linear): флаг flags.linear в опросе setup.sh"
```

---

### Task 4: фаза логина в `setup.sh`

**Files:**
- Modify: `setup.sh:95-99` (между проверкой `failed` и финальным `log "Done. ..."`)
- Modify: `skills/tools/lib/faketools.bash` (переключатель `CLAUDE_FAKE_NO_PLUGINS`)
- Test: `skills/tools/test-multiprofile.sh` (дописать в конец, перед `echo "PASS test-multiprofile"`)

**Interfaces:**
- Consumes: `mcp_linear_login <profile>` из задачи 2, `profile_dir <profile>` (`lib/profiles.sh:2`), массив `selected` и `config_flag linear`.
- Produces: ничего для следующих задач.

- [ ] **Step 1: Добавить в фейковый `claude` переключатель «плагины не ставятся»**

Без него тест на упавший профиль вакуумный: фейк с пустым catch-all не печатает `Needs authentication`, и логина не будет независимо от того, выполнилась фаза или нет. В `skills/tools/lib/faketools.bash` заменить ветку `"plugin list")`:

```bash
  "plugin list")        # CLAUDE_FAKE_NO_PLUGINS=1 -> nothing is ever reported installed, so a
                        # recipe's self-verify fails while every other branch keeps working
    [ "${CLAUDE_FAKE_NO_PLUGINS:-0}" = 1 ] || cat "$S/plugins" 2>/dev/null ;;
```

- [ ] **Step 2: Написать падающий сквозной тест**

Дописать в `skills/tools/test-multiprofile.sh` ПЕРЕД последней строкой `echo "PASS test-multiprofile"`:

```bash
# --- Linear: the login phase visits every selected profile, in that profile's dir ---
setup_fixture_home >/dev/null; h3="$HOME"
printf 'CREDS' > "$h3/.claude/.credentials.json"
mkdir -p "$h3/.config/claudefiles"
cat > "$h3/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"profile_super":true,"profile_gstack":false,"context7":true,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false,"linear":true},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
EOF
CLAUDEFILES_ASSUME_TTY=1 bash "$cf/setup.sh" < /dev/null
[ "$(grep -cxF "mcp login linear CLAUDE_CONFIG_DIR=$h3/.claude" "$CLAUDE_FAKE_LOG")" = 1 ] \
  || { echo FAIL no-linear-login-in-vanilla; exit 1; }
[ "$(grep -cxF "mcp login linear CLAUDE_CONFIG_DIR=$h3/.claude-super" "$CLAUDE_FAKE_LOG")" = 1 ] \
  || { echo FAIL no-linear-login-in-super; exit 1; }
[ "$(grep -cF "mcp login linear" "$CLAUDE_FAKE_LOG")" = 2 ] \
  || { echo FAIL linear-login-count; exit 1; }
# without this the asserts above are vacuous: the fake claude's state is one per fixture HOME, so
# `mcp get linear` answers "present" for super even if the server only landed in vanilla. The
# per-profile manifests are real separate files, and they do tell the two apart.
for m in vanilla super; do
  python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert "linear" in d,(sys.argv[1],d)' \
    "$h3/.config/claudefiles/managed-mcp.$m.json" || { echo "FAIL linear-missing-in-$m-manifest"; exit 1; }
done

# already authenticated -> no login at all: the guard against "a browser on every run"
: > "$CLAUDE_FAKE_LOG"
CLAUDE_FAKE_MCP_AUTH=ok CLAUDEFILES_ASSUME_TTY=1 bash "$cf/setup.sh" < /dev/null
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL linear-login-when-authed; exit 1; }

# flag back to false -> the server is removed from every selected profile and no login happens.
# This task is what made the vanilla/g branch in build_servers.py non-terminal, so removal is
# proven end to end, not only by mcp_apply's unit tests.
python3 "$cf/lib/py/config_io.py" setbool "$h3/.config/claudefiles/secrets.json" flags.linear false
: > "$CLAUDE_FAKE_LOG"
CLAUDEFILES_ASSUME_TTY=1 bash "$cf/setup.sh" < /dev/null
grep -q "mcp remove --scope user linear" "$CLAUDE_FAKE_LOG" || { echo FAIL linear-not-removed; exit 1; }
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL linear-login-after-disable; exit 1; }
for m in vanilla super; do
  python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert "linear" not in d,(sys.argv[1],d)' \
    "$h3/.config/claudefiles/managed-mcp.$m.json" || { echo "FAIL linear-left-in-$m-manifest"; exit 1; }
done
python3 "$cf/lib/py/config_io.py" setbool "$h3/.config/claudefiles/secrets.json" flags.linear true

# a failed profile -> setup.sh exits 1 BEFORE the login phase
: > "$CLAUDE_FAKE_LOG"
CLAUDE_FAKE_NO_PLUGINS=1 CLAUDEFILES_ASSUME_TTY=1 bash "$cf/setup.sh" < /dev/null \
  && { echo FAIL expected-exit-1-on-failed-profile; exit 1; }
grep -q "mcp login" "$CLAUDE_FAKE_LOG" && { echo FAIL linear-login-after-failed-profile; exit 1; }
echo "ok linear-login-phase"
```

- [ ] **Step 3: Убедиться, что тест падает**

Run: `bash skills/tools/test-multiprofile.sh`
Expected: `FAIL no-linear-login-in-vanilla` — сервер в конфиг попадает, но логиниться некому.

- [ ] **Step 4: Реализовать фазу**

В `setup.sh` вставить между проверкой упавших профилей (строки 95-97) и финальным `log "Done. ..."`:

```bash
# After the failed-profile gate on purpose: if a profile is broken, an OAuth browser flow is the
# last thing the user needs. Each profile in its own subshell, exactly like provision_selected —
# `claude mcp login` targets whatever CLAUDE_CONFIG_DIR points at.
if [ "$(config_flag linear)" = true ]; then
  log "linear auth"
  for p in "${selected[@]}"; do
    ( export CLAUDE_CONFIG_DIR="$(profile_dir "$p")"; mcp_linear_login "$p" )
  done
fi
```

- [ ] **Step 5: Убедиться, что тест проходит**

Run: `bash skills/tools/test-multiprofile.sh`
Expected: PASS, в выводе есть `ok linear-login-phase`.

- [ ] **Step 6: Прогнать всю сьюту**

Run: `bash skills/tools/run-all-tests.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 7: Коммит**

```bash
git add setup.sh skills/tools/lib/faketools.bash skills/tools/test-multiprofile.sh
git commit -m "feat(linear): фаза OAuth-логина после провижна"
```

---

### Task 5: документация

**Files:**
- Modify: `README.md` (строки 9, 10, 11, 20, 28, 40, 114 и новый пункт в разделе миграции рядом со строкой 167)
- Modify: `docs/config-schema.md:7`
- Modify: `docs/runtime.md:12,17,21,35`
- Modify: `docs/user-flow.md:26`

**Interfaces:**
- Consumes: поведение, реализованное задачами 1-4.
- Produces: ничего.

- [ ] **Step 1: `docs/config-schema.md`**

Строка 7 — добавить `linear` в перечисление:

```markdown
- `flags.<name>`: булевы (JSON-bool): `profile_super`, `profile_gstack`, `dotnet_skills`, `codex_review`, `codex_plugin`, `playwright`, `azure_mcp`, `ado`, `context7`, `linear`.
```

Дописать в конец раздела «Ключи»:

```markdown
- `linear` секретов не требует: сервер удалённый (`https://mcp.linear.app/mcp`), авторизация через OAuth, токен хранит Claude Code, а не claudefiles.
```

- [ ] **Step 2: `docs/runtime.md`**

Строки 12, 17, 21 в mermaid-схеме:

```
    vmcp["MCP: context7 безусловно + linear по флагу"]
```
```
    smcp["MCP по флагам: context7, playwright, azure, ADO, linear"]
```
```
    gmcp["MCP: context7 безусловно + linear по флагу"]
```

Строка 35:

```markdown
- **MCP**: vanilla и g всегда получают context7 и, по флагу `linear`, Linear (ветка `if profile in ("vanilla", "g")` в `build_servers.py`); super — флаг-гейтед набор, куда context7 входит тоже по флагу. Linear единственный не-stdio сервер: удалённый HTTP плюс разовый `claude mcp login linear`, который `setup.sh` предлагает сам.
```

Номера строк тут намеренно не проставлены: ветки в `build_servers.py` съезжают от любой правки, а сослаться на условие можно надёжно.

- [ ] **Step 3: `docs/user-flow.md`**

Строки 26-27 — вставить вопрос про Linear между `c7` и `persist`:

```
  g --> c7{"context7?"}
  c7 --> lin{"linear?"}
  lin --> persist[("ответы в secrets.json, повтор не переспрашивает")]
```

- [ ] **Step 4: `README.md` — таблица профилей**

Строка 9 (vanilla): заменить `Context7 MCP (включён безусловно), светлая тема` на `Context7 MCP (включён безусловно) и Linear MCP по флагу, светлая тема`.

Строка 10 (super): заменить `MCP по флагам` на `MCP по флагам (включая Linear)`.

Строка 11 (g): заменить `context7 MCP, личный marker-блок` на `context7 MCP и Linear MCP по флагу, личный marker-блок`.

- [ ] **Step 5: `README.md` — фазы и зависимости**

Строка 20 (фаза config): заменить `плюс общий \`context7\` (нужен и vanilla, и super, и g)` на `плюс общие \`context7\` и \`linear\` (нужны и vanilla, и super, и g)`.

Строка 28 (фаза mcp): заменить `vanilla и g всегда получают только \`context7\`` на `vanilla и g всегда получают \`context7\` плюс \`linear\` по флагу`. В конец пункта дописать:

```markdown
Linear единственный удалённый сервер в наборе: `claude mcp add-json` кладёт его в конфиг, но работать он начинает после разового `claude mcp login linear`. Отдельная фаза после провижна проверяет `claude mcp get linear` и предлагает вход только когда CLI сам сказал `Needs authentication` — на авторизованной машине она молчит, без TTY печатает команду.
```

Строка 40 (таблица зависимостей): заменить `запуск любого MCP-сервера (все на \`npx\`)` на `запуск stdio MCP-серверов (Linear не в счёт: удалённый HTTP, npx ему не нужен)`.

- [ ] **Step 6: `README.md` — секреты и миграция**

Строка 114 — добавить `linear` в список флагов:

```markdown
- **`secrets.json`** — флаги (`profile_super`, `profile_gstack`, `context7`, `linear`, `playwright`, `azure_mcp`, `ado`, `dotnet_skills`, `codex_review`, `codex_plugin`), `context7_api_key`, ADO email/orgs/PAT-ы. Заполняется prompt-once при TTY. Авторизацию Codex (`~/.codex/auth.json`) и OAuth-токен Linear claudefiles **не** трогает — это `codex login` и `claude mcp login linear`.
```

В разделе про миграцию (рядом со строкой 167, сразу после пункта про `profile_gstack`) добавить пункт. Внешний фенс здесь из четырёх бэктиков, потому что внутри вложенный трёхбэктиковый блок — в README вставлять надо только его содержимое:

````markdown
- **Миграция на существующей машине: `linear`.** Такой же обязательный флаг, как `profile_gstack`: `./setup.sh --non-interactive` (и chezmoi-триггер `run_after`) падает с `missing required flag 'flags.linear'`, пока флаг не заведён. Один раз запустить `./setup.sh` из терминала — или засеять без TTY:
  ```bash
  python3 ~/.local/share/claudefiles/lib/py/config_io.py setbool \
    ~/.config/claudefiles/secrets.json flags.linear false
  ```
````

- [ ] **Step 7: Проверить, что доки не разъехались с кодом**

Run:
```bash
grep -lF "linear" README.md docs/config-schema.md docs/runtime.md docs/user-flow.md
grep -c "flags.linear\|config_flag linear\|config_ensure_flag linear" setup.sh
```
Expected: первая команда печатает все четыре файла; вторая печатает `2` (вопрос в `config_ensure_all` плюс гейт фазы логина).

- [ ] **Step 8: Финальный прогон и коммит**

Run: `bash skills/tools/run-all-tests.sh`
Expected: `ALL TESTS PASSED`.

```bash
git add README.md docs/config-schema.md docs/runtime.md docs/user-flow.md
git commit -m "docs: Linear MCP по флагу"
```

---

## Проверка результата вручную (после всех задач)

Не часть TDD-цикла, но именно это подтверждает, что задача решена:

```bash
./setup.sh              # ответить y на вопрос про Linear
claude mcp get linear   # ожидается Status: connected
```

Первый прогон откроет браузер один раз. Второй прогон `./setup.sh` не должен открывать ничего.
