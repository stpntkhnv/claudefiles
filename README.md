# claudefiles

Самостоятельный репозиторий, который ставит конфигурацию Claude Code одной идемпотентной командой — в виде нескольких независимых **профилей**, каждый в своём каталоге. `setup.sh` всегда раскатывает лёгкий профиль **vanilla** (`~/.claude`, обычный `claude`): статуслайн, личный `CLAUDE.md`, Context7 MCP, светлая тема — без плагинов и хуков. По выбору добавляется **super** (`~/.claude-super`, команда `claude-super`) — сегодняшний полный superpowers-стек, байт-в-байт. По выбору же добавляется **g** (`~/.claude-g`, команда `claude-g`) — этап видения поверх стороннего инструмента [gstack](https://github.com/garrytan/gstack). Каждый профиль — рецепт (`lib/profiles.sh`) над общими модулями `lib/*.sh`; при первом запуске существующий super-стек в `~/.claude` конвертируется в vanilla (секреты сохраняются). chezmoi тянет этот репозиторий как external; `setup.sh` запускается руками — чеклист chezmoi подсказывает, когда HEAD клона сдвинулся. Секреты спрашиваются один раз в локальное хранилище вне git — ничего секретного в репозиторий не попадает.

## Профили

| Профиль | Каталог | Вызов | Содержимое |
|---------|---------|-------|------------|
| **vanilla** | `~/.claude` (дефолт, ставится всегда) | `claude` | статуслайн (`claude/statusline/statusline.sh`) с бейджем профиля (`[vanilla]`/`[super]`/`[g]`) слева, личный marker-блок в `CLAUDE.md`, Context7 MCP (включён безусловно) и Linear MCP по флагу, светлая тема, `tui: fullscreen`; без плагинов, без хуков. `model`/`effortLevel` не управляются `setup.sh` — их выставляет сам пользователь. |
| **super** | `~/.claude-super` (по флагу `profile_super`) | `claude-super` | сегодняшний полный superpowers-стек: плагин `superpowers@claude-plugins-official` и detect-dotnet хук (всегда для super), опционально `dotnet@dotnet-agent-skills`/`codex@openai-codex`, codex-наж в `CLAUDE.md`, MCP по флагам (включая Linear), `model: opus[1m]`, `effortLevel: xhigh`, тёмная тема, статуслайн (тот же `claude/statusline/statusline.sh`) с бейджем профиля (`[vanilla]`/`[super]`/`[g]`) слева. |
| **g** | `~/.claude-g` (по флагу `profile_gstack`) | `claude-g` | gstack (23 скилла-роли, около 50 скиллов всего), та же ванильная база (статуслайн с бейджем, звук, context7 MCP и Linear MCP по флагу, личный marker-блок), плюс marker-блок про `docs/vision`; `model: opus[1m]`, `effortLevel: xhigh`; без плагинов и без SessionStart-хука. |

Для каждого профиля `setup.sh` генерирует исполняемый wrapper `~/.local/bin/claude-<profile>` (`claude-vanilla`, `claude-super`, `claude-g`), который задаёт `CLAUDE_CONFIG_DIR` и вызывает общий запускатель памяти. Генерация идемпотентна; чужие команды не перезаписываются. Установщик сам добавляет помеченный блок PATH в настройки Bash и поддерживаемые настройки zsh; после установки нужен новый терминал. Обычный `claude` также проходит через запускатель, upstream-бинарник не заменяется. Авторизация общая: в каждый не-дефолтный каталог `setup.sh` кладёт `.credentials.json` — симлинк на `~/.claude/.credentials.json` (там лежит реальный файл, который пишет `claude login`), так что `claude-super` не требует повторного логина. История сессий (`history.jsonl`) при этом раздельная на каждый каталог. Новый профиль добавляется одной записью в `lib/profiles.sh` (функция `recipe_<name>` + каталог `~/.claude-<name>`), без переписывания оркестратора.

## Что делает `setup.sh`

`lib/*.sh` — сфокусированные модули, каждый тестируется против фейкового `claude` и фикстур-`$HOME`; `lib/profiles.sh` компонует их в рецепты профилей (`recipe_vanilla`, `recipe_super`, `recipe_g`). Оркестратор `setup.sh` гоняет по порядку:

1. **preflight** — проверка git/python3; про `claude` предупреждает, но не падает.
2. **config** — спрашивает (только при TTY; без TTY — падает с понятным списком, а не висит), какие профили ставить (`vanilla` — всегда; `super` — по флагу `profile_super`; `g` — по флагу `profile_gstack`), при выбранном `super` — его флаги (`dotnet_skills`, `codex_review`, `codex_plugin`, `playwright`, `azure_mcp`, `ado` и ADO-секреты), плюс общие `context7`, `linear` и `kb` (нужны и vanilla, и super, и g; у `kb` спрашивается ещё путь волта) — всё читается/пишется в `~/.config/claudefiles/secrets.json`.
3. **deps** — по флагам выбранных профилей проверяет системные зависимости и предлагает поставить недостающие через `pacman` (Arch-only, `y/N` → `sudo pacman`): `node`/`npx` — всегда (vanilla безусловно поднимает Context7), `chromium` для Playwright и `dotnet-sdk` для .NET-плагина — только если выбран `super` с соответствующим флагом, `bun` — только если выбран `g` (без него инсталлятор gstack не стартует). Любая ветка не фатальна — нет TTY/`pacman`/`sudo` печатает ручную команду и продолжает.
4. **профили** — для каждого выбранного профиля (`vanilla`, затем `super`, затем `g`, если выбраны) в **subshell** с `CLAUDEFILES_TARGET`/`CLAUDE_CONFIG_DIR`, указывающими на его каталог, гонится рецепт:
   - `settings.json` — заменяет управляемые ключи профиля из его шаблона (`settings.vanilla.template.json`: `theme`, `tui`, `statusLine`; `settings.super.template.json`: `theme`, `tui`, `statusLine` (тот же скрипт, что у vanilla) плюс `model`, `effortLevel`, `enabledPlugins`, `extraKnownMarketplaces`, `hooks`; `settings.g.template.json`: `theme`, `tui`, `statusLine`, `model`, `effortLevel`, `hooks` (Stop/Notification, без SessionStart) — без `enabledPlugins`), сохраняя чужие ключи. Управляемый ключ, отсутствующий в шаблоне профиля, удаляется из target — этим первый прогон на дефолтном каталоге снимает весь super-стейт (миграция «был super → стал vanilla»); `model`/`effortLevel` при этом чистятся только one-time (если раньше был включён super), дальше не трогаются.
   - `skills` — копирует `context7-mcp` всегда; `codex-review` и `dotnet-router` — только в рецепте super, по его флагам. Выключенный флаг убирает свой скилл (не оставляет следов). Рецепт `g` использует ту же ветку, что vanilla (только `context7-mcp`) — скиллы gstack ставит отдельно свой рецепт (см. `gstack` ниже).
   - `claude.md` — рецепт super при `codex_review=true` вписывает codex-наж marker-блоком; рецепт vanilla вместо него вписывает личный marker-блок со стилем письма. Рецепт `g` пишет и личный marker-блок, и marker-блок про видение (`docs/vision/`) в роли producer; рецепт super пишет тот же блок в роли consumer, если выбран `profile_gstack`, иначе снимает его. Все идемпотентны и сохраняют остальное содержимое файла.
   - `plugins` (только рецепт super) — идемпотентно ставит `superpowers@claude-plugins-official` (всегда для super), при `dotnet_skills=true` — `dotnet@dotnet-agent-skills`, при эффективном `codex_review && codex_plugin` — `codex@openai-codex`; добавляет их marketplace при отсутствии (гварды: повторный запуск — no-op).
   - `kb` (по флагу, во всех трёх рецептах) — создаёт скелет волта базы знаний, переносит стор auto memory туда через `env.CLAUDE_CODE_REMOTE_MEMORY_DIR`, кладёт политику `rules/kb.md` и симлинк `rules/kb-index.md` на общий индекс. Выключенный флаг снимает записи и файлы, но не заметки (см. «База знаний» ниже).
   - `gstack` (только рецепт `g`) — клонирует/обновляет апстрим gstack в `skills/gstack` и гоняет его инсталлятор, когда HEAD сдвинулся (подробности — в разделе «Профиль g (этап видения)» ниже); провал роняет только профиль `g`.
   - `mcp` — сверяет user-scope MCP-серверы каталога профиля с его собственным манифестом (`managed-mcp.<profile>.json`): vanilla и g всегда получают `context7` плюс `linear` по флагу, super — набор по своим флагам; чужие/неуправляемые серверы не трогает. На дефолтном каталоге первый прогон подхватывает legacy `managed-mcp.json` как «прошлый манифест» и снимает старые super-серверы. Linear единственный удалённый сервер в наборе — `claude mcp add-json` кладёт его в конфиг, но включается он отдельной фазой ниже, после того как все профили провижнуты.
   - после успешного рецепта — симлинк `.credentials.json` и wrapper `~/.local/bin/claude-<profile>` (оба — только для не-дефолтных каталогов).
5. **verify** — валидирует `settings.json` каждого выбранного профиля через `python3 -m json.tool`; не фатально.

Провал раскатки одного профиля не рушит остальные, но агрегируется: если хоть один профиль упал, `setup.sh` печатает список и выходит `exit 1` — **до** следующего шага, потому что упавший профиль не место для браузерного OAuth-логина.

6. **linear auth** — только при `flags.linear=true` и только если предыдущий шаг не остановил прогон: для каждого выбранного профиля, в своей подоболочке с `CLAUDE_CONFIG_DIR`, указывающим на его каталог, `mcp_linear_login` смотрит на `claude mcp get linear` и решает по статусу — сервер найден, нужна авторизация, есть TTY → открывает браузер (`claude mcp login linear`); сервер найден и уже авторизован → молчит; сервер найден, нужна авторизация, TTY нет (например, SSH-сессия без иксов) → печатает ручную команду; сервер отсутствует в конфиге профиля (дрейф манифеста), проверка статуса не уложилась в таймаут, или статус не распознан → предупреждает и продолжает. Ни одна ветка не роняет `setup.sh`. По SSH `_has_tty` истинна, а браузера нет — в такой сессии логиньтесь вручную командой `claude mcp login linear --no-browser`.

Запущенный дважды `setup.sh` не даёт diff ни в одном каталоге и выходит 0.

## Системные зависимости

Фаза **deps** (Arch-only) проверяет только то, что нужно под выбранные профили и их флаги (vanilla всегда тянет `node`/`npx`), и предлагает поставить недостающее через `pacman` (`y/N` → `sudo pacman -S --needed`; под root — напрямую). Любая ветка не фатальна: нет TTY / `pacman` / `sudo` — печатает ручную команду и продолжает.

| Зависимость | Пакет | Нужна для | Флаг |
|-------------|-------|-----------|------|
| `node` + `npx` | `nodejs npm` | запуск stdio MCP-серверов (Linear не в счёт: удалённый HTTP, npx ему не нужен) | всегда (vanilla безусловно ставит Context7); дополнительно любой из `context7`/`playwright`/`azure_mcp`/`ado` в super |
| `chromium` | `chromium` | браузер Playwright MCP | `playwright` |
| `.NET SDK` (`dotnet`) | `dotnet-sdk` | C# language server / dotnet-плагин | `dotnet_skills` |
| `codex` CLI (≥0.142.5) | `npm i -g @openai/codex` | Codex cross-review спек/планов/диффов | `codex_review` |
| `bun` | `bun` | инсталлятор gstack (его `setup` выходит без bun) | `profile_gstack` |

`claude` CLI фаза не ставит — это задача chezmoi-бутстрапа; preflight про это предупреждает, но не падает. Проверка `chromium` согласована с резолвером `build_servers.py` (учитывает тот же override `playwright.chromium_path`). Не-Arch (нет `pacman`) — печатается ручная команда, прогон не падает.

## Установка

### Свежая машина — одной командой (через chezmoi)

```bash
chezmoi init --apply stpntkhnv/dotfiles
```

chezmoi ставит `claude` CLI и тянет claudefiles как `git-repo` external в `~/.local/share/claudefiles`. `setup.sh` он с 2026-08-01 НЕ запускает: финальный чеклист apply сравнивает HEAD клона с `~/.config/claudefiles/last-applied-head` и, пока они расходятся, печатает команду ручного запуска; маркер пишет сам `setup.sh` в конце успешного прогона.

### Напрямую (разработка)

```bash
git clone https://github.com/stpntkhnv/claudefiles.git ~/dev/claudefiles && cd ~/dev/claudefiles && ./setup.sh
```

Требуется: git, bash, GNU coreutils/awk, python3 (только stdlib). Системные зависимости (`node`/`npx`, `chromium`, `.NET SDK`) фаза **deps** предложит поставить через `pacman` — под флаги выбранных профилей (см. «Системные зависимости»). Плагины ставит сам `setup.sh`, но только в профиль `super`, если он выбран: `superpowers@claude-plugins-official` (всегда для `super`) — процессный каркас, в чьи этапы встраивается dotnet-router — и `dotnet@dotnet-agent-skills` при `dotnet_skills=true`.

## Чистая установка

Обычный прогон аддитивен: он владеет только своими ключами и своими артефактами, всё остальное
переживает установку. Чистая установка снимает и это: сторонние скиллы, `rules/`, MCP-серверы,
добавленные руками, чужие ключи в `settings.json`, ручные правки `CLAUDE.md`, установленные
плагины.

```bash
./setup.sh
# Clean install? Wipes the selected profiles' config and every stored answer. (y/N) y
# Type 'clean' to confirm: clean
```

Вопрос задаётся в каждом прогоне, по умолчанию нет. Подтверждение словом обязательно: случайный
`y` не должен стоить вам ADO PAT-ов.

Что сносится: `settings.json` (переписывается ровно из шаблона), `settings.local.json`,
`settings.json.bak*`, `CLAUDE.md`, `skills/`, `plugins/`, `rules/`, `agents/`, `commands/`,
`output-styles/`, маркер gstack, все user-scope MCP-серверы, `secrets.json` и MCP-манифесты.

Что сохраняется: `.credentials.json` (вы не разлогинитесь), `projects/` с транскриптами,
`history.jsonl`, `sessions/`, кеши, `.claude.json` кроме ключа `mcpServers`.

Чистятся только те профили, что выбраны в этом прогоне. Оставшийся на диске каталог невыбранного
профиля не трогается, о нём печатается предупреждение.

Перед первым удалением всё удаляемое копируется в `~/.config/claudefiles/clean-backups/<время>/`
(права 700), кроме клона gstack на 1.5G. Любая ошибка бэкапа отменяет прогон до удаления. Путь
бэкапа печатается дважды: сразу при создании каталога (до первого удаления) и повторно в конце
полностью успешного прогона.

Восстановить профиль из бэкапа можно обычным копированием обратно, руками:

```
cp -a ~/.config/claudefiles/clean-backups/<время>/<профиль>/. ~/.claude-<профиль>/
```

Для `vanilla` цель: `~/.claude`, а не `~/.claude-vanilla`.

Требования: TTY (ответы сносятся, вводить их заново придётся руками), `claude` на PATH и
доступный github. Профиль `g` дополнительно требует `bun` и разрешающийся репозиторий gstack:
без них он не чистится вовсе, клон и маркер остаются, профиль уходит в `PROVISION_FAILED`.
Чистая установка профиля `g` заново клонирует gstack и прогоняет его инсталлятор: это долго.

## Секреты

Живут только в `~/.config/claudefiles/` — вне репозитория, `chmod 600`:

- **`secrets.json`** — флаги (`profile_super`, `profile_gstack`, `context7`, `linear`, `playwright`, `azure_mcp`, `ado`, `dotnet_skills`, `codex_review`, `codex_plugin`), `context7_api_key`, ADO email/orgs/PAT-ы. Заполняется prompt-once при TTY. Авторизацию Codex (`~/.codex/auth.json`) и OAuth-токен Linear claudefiles **не** трогает — это `codex login` и `claude mcp login linear`.
- **`managed-mcp.<profile>.json`** — манифест применённых MCP-серверов профиля (для сверки и удаления ровно своего); содержит base64-PAT для ADO (в профиле super), поэтому тоже `600`. Legacy `managed-mcp.json` (из до-профильной раскладки) потребляется один раз при миграции дефолтного каталога и затем удаляется.

Миграция на существующей машине: `linear` — такой же обязательный флаг, как `profile_gstack`: `./setup.sh --non-interactive` падает с `missing required flag 'flags.linear'`, пока флаг не заведён. Один раз запустить `./setup.sh` из терминала — или засеять без TTY:
```bash
python3 ~/.local/share/claudefiles/lib/py/config_io.py setbool \
  ~/.config/claudefiles/secrets.json flags.linear false
```

Тест гарантирует, что ни один секретный путь не трекается; репозиторий **публичный**.

## База знаний (флаг `kb`)

Штатная auto memory Claude Code держит каталог памяти внутри `CLAUDE_CONFIG_DIR`, поэтому у каждого профиля своя база на один и тот же репозиторий: `claude` и `claude-super` в одном проекте видят разные половины знания. Флаг `kb` переносит стор в один каталог вне репозиториев и профилей — волт Obsidian:

```
<волт>/                          # по умолчанию ~/Documents/Notes/kb, переопределяется kb.vault_path
                                 # (в контейнере умолчания нет: путь к хостовому волту обязателен)
├── repositories/<имя>-<хеш>/   # автоматическая память по Git remote; папка клона не участвует
│   └── MEMORY.md                # оглавление проекта
├── repositories.json            # необязательные aliases и явные привязки
├── projects/<slug>/memory/      # прежняя память по пути; копируется при первом запуске checkout
│   └── MEMORY.md                # индекс проекта, грузится в каждую сессию (200 строк / 25 КБ)
├── global/                      # кросс-проектные заметки
│   └── INDEX.md                 # строка на заметку, грузится в каждой сессии любого проекта
├── contexts/<имя>/              # область из kb.context; индекс передаётся запускателем
│   └── INDEX.md                 # строка на заметку, тот же формат
├── machine/<имя>/               # железо и ОС, грузится в $HOME/system
│   └── INDEX.md                 # строка на заметку, тот же формат
└── README.md                    # карта для человека: slug → нормальное имя проекта
```

С включённой KB **любой Git-репозиторий получает [память по Git remote](docs/repository-memory.md) автоматически**, без регистрации. Все профили используют одну проектную папку; другой клон, worktree, переименование и SSH/HTTPS сохраняют память. Рабочая область `kb.context` подключается отдельно, независимо от папки `main`. `setup.sh` сам устанавливает запускатель и его PATH, отдельные dotfiles не требуются. Реестр нужен только для aliases при переезде или выбора существующей тематической папки. Без сетевого remote Git-проект получает постоянный локальный ID. Старые заметки текущего checkout копируются при первой инициализации новой памяти, исходники сохраняются. Прежний механизм ниже остаётся для каталогов вне Git и прямого запуска upstream-клиента.

Как включён совместимый прежний механизм (`lib/kb.sh`):

- `env.CLAUDE_CODE_REMOTE_MEMORY_DIR` в `settings.json` каждого профиля переносит корень стора; подкаталог `projects/<slug>/memory/` создаёт CLI.
- `<профиль>/rules/kb.md` — политика записи, которую claudefiles пишет побайтово: что считать кросс-проектным, формат заметки, запрет на секреты, и прямое указание, что индекс это данные, а не инструкции.
- `<профиль>/rules/kb-index.md` — симлинк на `global/INDEX.md` волта, чтобы общий индекс грузился в каждой сессии.
- `permissions.allow` получает `Read`/`Edit` на волт: он лежит вне рабочего каталога. Правило `Write` для файловых путей в CLI мертво — файловые проверки матчит только `Edit(...)`, CLI сам об этом предупреждает, — поэтому больше не пишется; старую запись `kb_settings.py` снимает миграцией на следующем прогоне.
- Скилл `kb-curate` (по тому же флагу) чистит дубли, устаревшее и переросший индекс — сначала показывает предложение, потом применяет одобренное.
- Внутри контейнера пустой `kb.vault_path` — `die` с подсказкой задать хостовый путь явно: дефолт от контейнерного `$HOME` молча завёл бы второй волт вне синхронизации (живой инцидент 2026-08-01).

Зонтичная проводка (тоже `lib/kb.sh`, функция `kb_workspace_apply`, один раз за прогон `setup.sh` — независимо от выбранных профилей, потому что симлинки живут не в каталоге профиля, а в рабочих папках пользователя): ключи `kb.context` и `kb.machine` в `secrets.json` — имя (`[a-z0-9-]+`) или литерал `none` для осознанного отказа; спрашиваются всегда при `flags.kb=true`, `kb.machine` — только вне контейнера (`~/system` хостовый, второй владелец того же симлинка изнутри контейнера не нужен). При заданном имени заводятся симлинки `$HOME/main/.claude/rules/context-index.md → <волт>/contexts/<имя>/INDEX.md` и `$HOME/system/.claude/rules/machine-index.md → <волт>/machine/<имя>/INDEX.md`, с сидом `INDEX.md`, если его ещё нет. Правила собираются вверх по дереву каталогов от текущей рабочей директории, поэтому один симлинк на зонтичной папке покрывает все репозитории под ней. Зонтичную папку (`$HOME/main` или `$HOME/system`) claudefiles не создаёт: нет папки — `WARN` и пропуск слоя. Обычный файл или чужой симлинк на месте `context-index.md`/`machine-index.md` не перезаписывается, только предупреждение. Снятие (флаг выключен или значение `none`) убирает только симлинк, чья цель указывает в текущий волт; ссылку на чужой волт не трогает.

`env` и `permissions` пишет не `jsonmerge.py` (он заменяет управляемый ключ целиком), а `lib/py/kb_settings.py` по манифесту `managed-kb.<profile>.json`: снимается ровно то, что положили мы, чужие переменные и правила остаются. Выключение флага снимает записи, правило и симлинк; **заметки в волте не трогаются никогда** — ни выключением, ни чистой установкой.

Переменная `CLAUDE_CODE_REMOTE_MEMORY_DIR` в публичных доках Claude Code не описана (там только `autoMemoryDirectory`, который подменяет путь целиком, без `projects/<slug>`). Проверена живым прогоном на CLI **2.1.220**. Поэтому есть смоук, который спрашивает настоящий CLI, где его память и загрузилось ли правило профиля:

```bash
CLAUDEFILES_KB_SMOKE=1 bash skills/tools/smoke-kb.sh
```

Синхронизация волта между машинами (Syncthing, Obsidian Sync) — отдельная задача, claudefiles её не настраивает. Если волт синкается, помните: приватная проектная память покидает машину, поэтому политика в `rules/kb.md` запрещает писать туда секреты, а синк лучше включать списком того, что синкается, а не списком исключений.

Миграция на существующей машине: `kb`, как `linear` и `profile_gstack`, обязательный флаг — `./setup.sh --non-interactive` падает с `missing required flag 'flags.kb'`, пока он не заведён. Один раз запустить `./setup.sh` из терминала — или засеять без TTY:
```bash
python3 ~/.local/share/claudefiles/lib/py/config_io.py setbool \
  ~/.config/claudefiles/secrets.json flags.kb false
```

Та же логика для `kb.context`/`kb.machine`, если `kb` на машине уже включён: оба тоже обязательные (`config_ensure`, не `config_ensure_optional`), и `--non-interactive` упадёт с `missing required config 'kb.context'`, пока ключ не заведён. Явный отказ от слоя — литерал `none`:
```bash
python3 ~/.local/share/claudefiles/lib/py/config_io.py set \
  ~/.config/claudefiles/secrets.json kb.context none
python3 ~/.local/share/claudefiles/lib/py/config_io.py set \
  ~/.config/claudefiles/secrets.json kb.machine none
```

Существующая память в старых каталогах не переезжает сама. Перенос делается руками один раз, `cp -n` (не перезаписывать) в `<волт>/projects/<slug>/memory/` для проектной части и в `<волт>/global/` для машинной, затем индексы сводятся вручную, и только после проверки живой сессией старые каталоги (`~/.claude/projects/<slug>/memory`, `~/.claude-super/projects/<slug>/memory`) удаляются.

## dotnet-router (одна из компонент)

Доставка ~100 [dotnet-skills](https://github.com/dotnet/skills) во все этапы [superpowers](https://github.com/anthropics/claude-plugins-official) — при постоянной цене контекста ~350 символов вместо ~18k токенов за полную установку плагинов.

- **`dotnet-router`** — единственный установленный скилл (симлинк). Его описание триггерит любую .NET-работу; тело задаёт правила для каждого этапа superpowers.
- **Двухуровневый каталог** (генерируется `setup.sh`, **не в git**): `INDEX.md` — карта «этап → домены» + имена скиллов; `CATALOG-<домен>.md` × 16 — дословные описания (USE FOR / DO NOT USE FOR) с абсолютными путями к SKILL.md для этой машины.
- **Скиллы не устанавливаются** — читаются `Read`-ом из read-only клона `skills/dotnet-skills`. К субагентам знание едет блоками `**Skills:**` / `**Service root:**` в планах.
- **SessionStart-хук** — детектирует .NET-воркспейс и напоминает про роутер.

Только `SKILL.md` роутера в git; каталог — генерируемый машинно-специфичный артефакт (абсолютные пути), поэтому в `.gitignore` — иначе каждый чекаут «пачкался» бы и ломал `git pull --ff-only` deploy-копии.

## Codex-ревью (кросс-провайдерная проверка)

Опциональный флаг **`codex_review`** добавляет второго, максимально непохожего ревьюера — [Codex](https://github.com/openai/codex) (по умолчанию gpt-6-astra, модель и усилие выбираются под задачу) — поверх самопроверки superpowers. На трёх чекпоинтах (спека, план, дифф кода) артефакт уходит в Codex, а провалидированные замечания вплетаются в то, что показывается пользователю. Ревью **совещательное и однопроходное**: Codex советует, но не блокирует; findings триажатся дисциплиной `receiving-code-review`.

- **Скилл `codex-review`** — «мозг» фичи: роутинг по типу артефакта (`codex exec` для `.md`-спек/планов в read-only sandbox репозитория, `codex review --base` для диффа), пиннинг модели inline (`-c model=…`), мягкая деградация при отсутствии/неавторизованности `codex`. Флаг `codex_review` спрашивается только при выбранном профиле `super`; скилл ставится копией в `~/.claude-super/skills`.
- **Наж в `CLAUDE.md` профиля super** (`~/.claude-super/CLAUDE.md`) — marker-блок (безусловное правило, всегда в контексте), напоминающий прогнать скилл на чекпоинтах. Управляется идемпотентно; выключение флага убирает блок, сохраняя пользовательское содержимое.
- **Предусловие — `codex login`.** claudefiles владеет только скиллом и нажем; авторизация Codex живёт в `~/.codex/auth.json` и остаётся за пользователем. readiness-фаза сообщает версию `codex` и статус логина; глобальный `~/.codex/config.toml` не трогается (модель/effort передаются inline на каждом вызове).
- **Опциональный `codex_plugin`** (по умолчанию off, эффективно `codex_review && codex_plugin`) — доставляет плагин `codex@openai-codex` для adversarial-режима. Никогда не включён, пока выключен `codex_review`.

## Профиль g (этап видения)

Третий профиль **`g`** (`~/.claude-g`, команда `claude-g`, флаг `profile_gstack`) — комната для этапа **видения**: какие фичи нужны, что решено, от чего отказались, как это должно выглядеть и ощущаться (`recipe_g`, `lib/profiles.sh:40-52`). Граница ответственности с `super` жёсткая: `claude-g` до спецификации не доходит, `claude-super` спецификацию не изобретает заново, а читает готовое видение.

- **Передача — через `docs/vision/`.** Профиль `g` пишет в свой `CLAUDE.md` marker-блок `claudefiles:vision` в роли producer (`lib/claudemd.sh:69-72`): по итогам обсуждения — файл `docs/vision/YYYY-MM-DD-<topic>.md` с решениями. Профиль `super`, если выбран `profile_gstack`, получает тот же блок в роли consumer (`lib/claudemd.sh:73-75`, `lib/profiles.sh:25`): перед `superpowers:brainstorming` заглянуть в `docs/vision/` и не переоткрывать закрытые вопросы. Если `g` не выбран, `super` этот блок не пишет — `claudemd_vision_apply off` снимает его, сохраняя остальной `CLAUDE.md`.
- **Клон** апстрима [gstack](https://github.com/garrytan/gstack) лежит внутри каталога профиля, `~/.claude-g/skills/gstack` (`lib/gstack.sh:27`) — как и остальные артефакты `g`, вне git.
- **Граница доверия.** claudefiles управляет тем, **куда** ставится gstack (каталог профиля, набор флагов, отсутствие sudo и вопросов), но не тем, **что** этот инсталлятор делает. По умолчанию клон едет за апстримным HEAD, и на каждом `./setup.sh` чужой код исполняется под полными правами пользователя без ревью. Пять флагов (`--host claude`, `--no-team`, `--no-plan-tune-hooks`, `-q`, `GSTACK_SKIP_FONTS=1`) закрывают известное поведение сегодняшней версии, а не произвольное поведение будущей.
- **Цена профиля и побочные записи (замерено на живом прогоне, не выведено из исходников).** Инсталлятор ставит зависимости через bun и тянет браузер (`bunx playwright install chromium`). Каталог профиля разрастается до **~1.5 ГБ**, а браузер уходит в общий кэш `~/.cache/ms-playwright` — то есть **за пределы профиля**; там же появляется состояние самого инструмента `~/.gstack`. Ни то, ни другое claudefiles не удаляет: снятие профиля — `gstack-uninstall`, затем `rm -rf ~/.claude-g ~/.local/bin/claude-g`. Поэтому проверка против настоящего апстрима (`skills/tools/smoke-gstack.sh`) вынесена из обычного прогона тестов и запускается явно:
  ```bash
  CLAUDEFILES_GSTACK_SMOKE=1 bash skills/tools/smoke-gstack.sh
  ```
- **Обновление по умолчанию автоматическое; маркер SHA — детектор изменений, а не пин.** Каждый прогон `gstack_apply` (`lib/gstack.sh:20`) обновляет клон (`git fetch --depth 1` + `git reset --hard FETCH_HEAD`, не `pull --ff-only` — инсталлятор правит `name:` внутри клона, поэтому worktree всегда «грязный») и запускает инсталлятор gstack заново, только если HEAD клона разошёлся с маркером `~/.claude-g/.gstack-setup-head`; иначе — no-op (`lib/gstack.sh:76-77`). То есть маркер экономит лишние прогоны инсталлятора, но не фиксирует ревизию: сдвинулся апстрим — обновились и вы.
- **Пин ревизии — `CLAUDEFILES_GSTACK_REF`** (`lib/gstack.sh:25`). Переменная окружения с тегом, веткой или SHA — клон едет за ней вместо апстримного HEAD. **Замораживают ревизию только тег и SHA**: обновление происходит, лишь когда вы сами меняете значение. Ветка не замораживает: пин на ветку намеренно следует за её верхушкой (`lib/gstack.sh:43-45`), то есть это выбор другого канала обновлений, а не пин. Не задана (умолчание) — поведение прежнее. Пин можно поставить и на уже установленный профиль: shallow-клон при этом углубляется. Неразрешимая ревизия — не тихий откат на HEAD, а провал профиля с явным сообщением.
  ```bash
  CLAUDEFILES_GSTACK_REF=9f2c1ab ./setup.sh      # тег, ветка или SHA просмотренной ревизии
  ```
  Пин живёт в окружении, а не в `secrets.json`: для постоянного пина переменную надо экспортировать там, откуда запускается `setup.sh` (обычно shell rc — с 2026-08-01 `setup.sh` запускают руками, не из chezmoi).
- **Провал профиля `g` изолирован.** Провал любого шага (fetch/reset/clone/rm/mkdir/запись маркера/сам инсталлятор) возвращает 1, и `recipe_g` роняет ровно профиль `g` (`lib/profiles.sh:49`), не трогая `vanilla` и `super`. Исключение — недоступный апстрим при уже установленной и совпадающей с маркером ревизии: обновление пропускается с `WARN`, профиль остаётся зелёным (`lib/gstack.sh:53-54`), иначе оффлайн-прогон ронял бы корректный профиль. Инсталлятор всегда получает `< /dev/null`: новый вопрос в апстриме должен ронять прогон, а не подвешивать его. Отдельно от stdin инсталлятор обёрнут в `timeout` (по умолчанию 1800 с, переопределяется `CLAUDEFILES_GSTACK_TIMEOUT`): на живом прогоне загрузка Chromium внутри gstack сорвалась и провисела 12 часов без единого байта прогресса — `< /dev/null` там не помогает, процесс ждёт не нас. По таймауту профиль `g` падает с явным сообщением, маркер не пишется, следующий прогон повторяет попытку.
- **Известная проблема апстрима: `playwright install` не завершается.** На этой машине команда делает свою работу и после этого висит вечно — даже когда скачивать нечего (0.5 с CPU, дальше бесконечное ожидание); в distrobox-контейнерах распаковщик детерминированно виснет посреди архива, который системный `unzip` разбирает за секунды. Сеть ни при чём: те же архивы качаются напрямую на 29 МБ/с. gstack вызывает её (`setup:479`) только если не смог запустить браузер. Поэтому с 2026-08-01 браузеры кладутся в кэш ДО инсталлятора: `_gstack_playwright_preinstall` (`lib/gstack.sh`) спрашивает у playwright план (`bunx playwright install chromium --dry-run`), качает архивы `curl`, распаковывает системным `unzip` и ставит маркеры `INSTALLATION_COMPLETE` — проверка `chromium.launch()` апстрима проходит, и его распаковщик не запускается вовсе. Любой сбой преинсталла — только `WARN`, дальше апстримный путь как раньше; отключается `CLAUDEFILES_GSTACK_PREINSTALL=0`. Тот же обход руками, если преинсталл почему-то не смог (ревизия `1208` и версия `145.0.7632.6` — из `playwright` в `package.json` апстрима, при обновлении поменяются):
  ```bash
  V=145.0.7632.6; R=1208; C="$HOME/.cache/ms-playwright"
  for n in chrome-linux64:chromium-$R chrome-headless-shell-linux64:chromium_headless_shell-$R; do
    z="${n%%:*}"; d="$C/${n##*:}"
    curl -sSL -o /tmp/pw.zip "https://cdn.playwright.dev/builds/cft/$V/linux64/$z.zip"
    mkdir -p "$d" && unzip -q -o /tmp/pw.zip -d "$d" && touch "$d/INSTALLATION_COMPLETE"
  done; rm -f /tmp/pw.zip
  ```
  После этого `CLAUDEFILES_GSTACK_SMOKE=1 bash skills/tools/smoke-gstack.sh` проходит целиком: установка, скиллы в профиле, второй прогон no-op, `~/.claude` не тронут.
- **Миграция на существующей машине.** `profile_gstack` — обязательный флаг: `./setup.sh --non-interactive` падает с `missing required flag 'flags.profile_gstack'`, пока флаг не заведён. Один раз запустить `./setup.sh` из терминала (спросит) — или засеять без TTY:
  ```bash
  python3 ~/.local/share/claudefiles/lib/py/config_io.py setbool \
    ~/.config/claudefiles/secrets.json flags.profile_gstack false
  ```
- **`~/.gstack` не под управлением claudefiles.** Это домашний каталог самого инструмента gstack (`config.yaml`, аналитика, `projects/`), а не Claude Code; `gstack-config`, `gstack-analytics`, `gstack-uninstall` пользователь запускает сам, без переменных окружения claudefiles.
- Выключение `profile_gstack` не удаляет `~/.claude-g` — симметрично с `profile_super`/`~/.claude-super`; каталог просто перестаёт обновляться. Ручная чистка: `gstack-uninstall`, затем `rm -rf ~/.claude-g && rm -f ~/.local/bin/claude-g`.

## Раскладка

```
setup.sh                      # оркестратор: preflight → config → deps → профили (vanilla + super + g) → verify → linear auth
lib/*.sh                      # config, deps, settings, skills, plugins, mcp, hooks, claudemd, gstack, kb, profiles, common, apply-if-changed
lib/py/                       # config_io.py, jsonmerge.py, kb_settings.py, repo_memory.py, launcher_path.py
claude/settings/              # settings.vanilla.template.json + settings.super.template.json + settings.g.template.json (управляемые ключи профиля)
claude/statusline/statusline.sh   # статуслайн (vanilla, super и g)
claude/skills/context7-mcp/   # SKILL.md (копируется в каждый профиль)
claude/skills/codex-review/   # SKILL.md кросс-ревьюера (копируется в super при codex_review)
claude/skills/kb-curate/      # SKILL.md курирования базы знаний (копируется в профиль при kb)
claude/skills/dotnet-router/  # SKILL.md роутера (каталог генерируется, вне git; только для super при dotnet_skills)
claude/mcp/build_servers.py   # сборка MCP-конфига из secrets.json, per-профиль
claude/hooks/detect-dotnet.sh # SessionStart-хук (только профиль super)
skills/tools/                 # генератор каталога + все test-*.sh + run-all-tests.sh
skills/dotnet-skills/         # read-only клон (не в git, клонирует setup.sh)
docs/superpowers/             # спека, план, смоук-протоколы
legacy/claude/                # прежнее содержимое (агенты, azure-devops-mcp) — не активируется
```

Документация:

- [docs/architecture.md](docs/architecture.md): структура, потоки, прогон, рецепты
- [docs/runtime.md](docs/runtime.md): поведение живой сессии
- [docs/user-flow.md](docs/user-flow.md): что запускает пользователь
- [docs/invariants.md](docs/invariants.md): гарантии тест-сьюта
- [docs/config-schema.md](docs/config-schema.md): схема secrets.json

### Карта контекста агентов

[Единый редактируемый канвас TLDraw](docs/context-map/agent-context.tldraw) — одна страница со сквозным примером: контейнер `digi3`, профиль `claude-super`, репозиторий `1ANV` в папке `main`. Сначала раскрыты деревья профиля и базы знаний, затем подключение рабочей области, загрузка сессии и чтение заметок. У каждого файла есть отдельный блок с назначением и настоящим именем; короткие примеры содержимого стоят рядом. Симлинки показаны синим пунктиром. Снимок конфигурации от 11 октября 2026.

На том же канвасе объяснены папки KB, история разговоров в профиле, auto memory и тематические заметки проектов, остальные источники контекста и синхронизация между устройствами. Оранжевые карточки содержат примеры; зелёный раздел показывает **предложение**, как выбирать память по идентификатору репозитория вместо пути клона. Канвас — снимок от 11 октября, до реализации. С 12 октября механизм работает автоматически для любого Git-репозитория без регистрации; актуальное описание и команды — [Память по репозиторию](docs/repository-memory.md).

[Правила оформления диаграмм](docs/context-map/diagram-rules.md) встроены в скилл `tldraw-offline`, исходник которого хранится в `dotfiles`: понятные названия, реальные примеры и различимые связи. Для алгоритмов предпочтительны блок-схемы, для сценариев и багов — раскадровки со снимками состояния. Правила включают выбор других форматов, сравнение текущего поведения и предложений на одинаковых данных и проверку понимания; несколько страниц допустимы, если улучшают объяснение. Документ также объясняет подключение и доставку правил в другие окружения. [Пользовательские наброски](docs/context-map/review-input.tldraw) сохранены отдельно перед перерисовкой.

Открыть в локальном приложении TLDraw из корня репозитория:

```bash
tldraw docs/context-map/agent-context.tldraw
```

Без TLDraw можно открыть [SVG с увеличением без потери качества](docs/context-map/agent-context.svg) или [превью JPG](docs/context-map/agent-context.jpg). Это статические экспорты того же единственного канваса; после его правок их нужно обновить.

[Подробное текстовое объяснение](docs/context-map/context-explained.md) сохранено отдельно: определения механизмов, конкретные пути, примеры записей и детали настройки.

Управляемая цепочка chezmoi (в репозитории dotfiles): external `.chezmoiexternal.toml` тянет клон; финальный чеклист apply (`run_after_zz-next-steps.sh.tmpl`) сравнивает HEAD с `last-applied-head` и подсказывает запустить `setup.sh` руками.

## Legacy

В `legacy/claude/` — прежнее содержимое: агенты (`implementer-dotnet`, `project-manager`, `code-reviewer`, `git-engineer`, `codebase-guardian`), скиллы `azure-devops-mcp` и `frontend-design-pro`, правила стиля. Вынесено из `.claude/`, чтобы не активироваться как project-конфиг; переносить в `~/.claude/` — поштучно и осознанно.
