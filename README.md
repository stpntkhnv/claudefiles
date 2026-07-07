# claudefiles

Самостоятельный репозиторий, который ставит конфигурацию Claude Code одной идемпотентной командой — в виде нескольких независимых **профилей**, каждый в своём каталоге. `setup.sh` всегда раскатывает лёгкий профиль **vanilla** (`~/.claude`, обычный `claude`): статуслайн, личный `CLAUDE.md`, Context7 MCP, светлая тема — без плагинов и хуков. По выбору добавляется **super** (`~/.claude-super`, команда `claude-super`) — сегодняшний полный superpowers-стек, байт-в-байт. Каждый профиль — рецепт (`lib/profiles.sh`) над общими модулями `lib/*.sh`; при первом запуске существующий super-стек в `~/.claude` конвертируется в vanilla (секреты сохраняются). chezmoi тянет этот репозиторий как external и перезапускает `setup.sh` при изменении HEAD. Секреты спрашиваются один раз в локальное хранилище вне git — ничего секретного в репозиторий не попадает.

## Профили

| Профиль | Каталог | Вызов | Содержимое |
|---------|---------|-------|------------|
| **vanilla** | `~/.claude` (дефолт, ставится всегда) | `claude` | статуслайн (`claude/statusline/statusline.sh`) с бейджем профиля (`[vanilla]`/`[super]`) слева, личный marker-блок в `CLAUDE.md`, Context7 MCP (включён безусловно), светлая тема, `tui: fullscreen`; без плагинов, без хуков. `model`/`effortLevel` не управляются `setup.sh` — их выставляет сам пользователь. |
| **super** | `~/.claude-super` (по флагу `profile_super`) | `claude-super` | сегодняшний полный superpowers-стек: плагин `superpowers@claude-plugins-official` и detect-dotnet хук (всегда для super), опционально `dotnet@dotnet-agent-skills`/`codex@openai-codex`, codex-наж в `CLAUDE.md`, MCP по флагам, `model: opus[1m]`, `effortLevel: xhigh`, тёмная тема, статуслайн (тот же `claude/statusline/statusline.sh`) с бейджем профиля (`[vanilla]`/`[super]`) слева. |

Для каждого не-дефолтного профиля `setup.sh` генерирует исполняемый wrapper `~/.local/bin/claude-<profile>` (например `~/.local/bin/claude-super`): `exec env CLAUDE_CONFIG_DIR=<каталог профиля> claude "$@"`. Wrapper работает в скриптах и свежих шеллах (не только как интерактивный alias); генерация идемпотентна и не перезаписывает файл, который уже существует и не управляется claudefiles. Обёртка видна, только если `~/.local/bin` есть в `$PATH`; если каталога там нет (например, нестандартный `$HOME`, чей `$PATH` указывает на другой `.local/bin`), `setup.sh` не падает и не правит rc-файлы, а печатает `WARN` с точной строкой `export PATH="$HOME/.local/bin:$PATH"`. Авторизация общая: в каждый не-дефолтный каталог `setup.sh` кладёт `.credentials.json` — симлинк на `~/.claude/.credentials.json` (там лежит реальный файл, который пишет `claude login`), так что `claude-super` не требует повторного логина. История сессий (`history.jsonl`) при этом раздельная на каждый каталог. Новый профиль добавляется одной записью в `lib/profiles.sh` (функция `recipe_<name>` + каталог `~/.claude-<name>`), без переписывания оркестратора.

## Что делает `setup.sh`

`lib/*.sh` — сфокусированные модули, каждый тестируется против фейкового `claude` и фикстур-`$HOME`; `lib/profiles.sh` компонует их в рецепты профилей (`recipe_vanilla`, `recipe_super`). Оркестратор `setup.sh` гоняет по порядку:

1. **preflight** — проверка git/python3; про `claude` предупреждает, но не падает.
2. **config** — спрашивает (только при TTY; без TTY — падает с понятным списком, а не висит), какие профили ставить (`vanilla` — всегда; `super` — по флагу `profile_super`), при выбранном `super` — его флаги (`dotnet_skills`, `codex_review`, `codex_plugin`, `playwright`, `azure_mcp`, `ado` и ADO-секреты), плюс общий `context7` (нужен и vanilla, и super) — всё читается/пишется в `~/.config/claudefiles/secrets.json`.
3. **deps** — по флагам выбранных профилей проверяет системные зависимости и предлагает поставить недостающие через `pacman` (Arch-only, `y/N` → `sudo pacman`): `node`/`npx` — всегда (vanilla безусловно поднимает Context7), `chromium` для Playwright и `dotnet-sdk` для .NET-плагина — только если выбран `super` с соответствующим флагом. Любая ветка не фатальна — нет TTY/`pacman`/`sudo` печатает ручную команду и продолжает.
4. **профили** — для каждого выбранного профиля (`vanilla`, затем `super`, если выбран) в **subshell** с `CLAUDEFILES_TARGET`/`CLAUDE_CONFIG_DIR`, указывающими на его каталог, гонится рецепт:
   - `settings.json` — заменяет управляемые ключи профиля из его шаблона (`settings.vanilla.template.json`: `theme`, `tui`, `statusLine`; `settings.super.template.json`: `theme`, `tui`, `statusLine` (тот же скрипт, что у vanilla) плюс `model`, `effortLevel`, `enabledPlugins`, `extraKnownMarketplaces`, `hooks`), сохраняя чужие ключи. Управляемый ключ, отсутствующий в шаблоне профиля, удаляется из target — этим первый прогон на дефолтном каталоге снимает весь super-стейт (миграция «был super → стал vanilla»); `model`/`effortLevel` при этом чистятся только one-time (если раньше был включён super), дальше не трогаются.
   - `skills` — копирует `context7-mcp` всегда; `codex-review` и `dotnet-router` — только в рецепте super, по его флагам. Выключенный флаг убирает свой скилл (не оставляет следов).
   - `claude.md` — рецепт super при `codex_review=true` вписывает codex-наж marker-блоком; рецепт vanilla вместо него вписывает личный marker-блок со стилем письма. Оба идемпотентны и сохраняют остальное содержимое файла.
   - `plugins` (только рецепт super) — идемпотентно ставит `superpowers@claude-plugins-official` (всегда для super), при `dotnet_skills=true` — `dotnet@dotnet-agent-skills`, при эффективном `codex_review && codex_plugin` — `codex@openai-codex`; добавляет их marketplace при отсутствии (гварды: повторный запуск — no-op).
   - `mcp` — сверяет user-scope MCP-серверы каталога профиля с его собственным манифестом (`managed-mcp.<profile>.json`): vanilla всегда получает только `context7`, super — набор по своим флагам; чужие/неуправляемые серверы не трогает. На дефолтном каталоге первый прогон подхватывает legacy `managed-mcp.json` как «прошлый манифест» и снимает старые super-серверы.
   - после успешного рецепта — симлинк `.credentials.json` и wrapper `~/.local/bin/claude-<profile>` (оба — только для не-дефолтных каталогов).
5. **verify** — валидирует `settings.json` каждого выбранного профиля и печатает readiness-сводку (`claude`, node+npx, chromium, dotnet, плагины, а при `codex_review` — версия `codex` и статус `codex login`) — не фатально.

Провал раскатки одного профиля не рушит остальные, но агрегируется в non-zero выход `setup.sh`. Запущенный дважды `setup.sh` не даёт diff ни в одном каталоге и выходит 0.

## Системные зависимости

Фаза **deps** (Arch-only) проверяет только то, что нужно под выбранные профили и их флаги (vanilla всегда тянет `node`/`npx`), и предлагает поставить недостающее через `pacman` (`y/N` → `sudo pacman -S --needed`; под root — напрямую). Любая ветка не фатальна: нет TTY / `pacman` / `sudo` — печатает ручную команду и продолжает.

| Зависимость | Пакет | Нужна для | Флаг |
|-------------|-------|-----------|------|
| `node` + `npx` | `nodejs npm` | запуск любого MCP-сервера (все на `npx`) | всегда (vanilla безусловно ставит Context7); дополнительно любой из `context7`/`playwright`/`azure_mcp`/`ado` в super |
| `chromium` | `chromium` | браузер Playwright MCP | `playwright` |
| `.NET SDK` (`dotnet`) | `dotnet-sdk` | C# language server / dotnet-плагин | `dotnet_skills` |
| `codex` CLI (≥0.142.5) | `npm i -g @openai/codex` | Codex cross-review спек/планов/диффов | `codex_review` |

`claude` CLI фаза не ставит — это задача chezmoi-бутстрапа; preflight предупреждает, а readiness в конце сообщает статус. Проверка `chromium` согласована с резолвером `build_servers.py` (учитывает тот же override `playwright.chromium_path`). Не-Arch (нет `pacman`) — печатается ручная команда, прогон не падает.

## Установка

### Свежая машина — одной командой (через chezmoi)

```bash
chezmoi init --apply stpntkhnv/dotfiles
```

chezmoi ставит `claude` CLI, тянет claudefiles как `git-repo` external в `~/.local/share/claudefiles` и через `run_after`-триггер запускает `setup.sh` (сравнивая HEAD, чтобы не гонять зря).

### Напрямую (разработка)

```bash
git clone https://github.com/stpntkhnv/claudefiles.git ~/dev/claudefiles && cd ~/dev/claudefiles && ./setup.sh
```

Требуется: git, bash, GNU coreutils/awk, python3 (только stdlib). Системные зависимости (`node`/`npx`, `chromium`, `.NET SDK`) фаза **deps** предложит поставить через `pacman` — под флаги выбранных профилей (см. «Системные зависимости»). Плагины ставит сам `setup.sh`, но только в профиль `super`, если он выбран: `superpowers@claude-plugins-official` (всегда для `super`) — процессный каркас, в чьи этапы встраивается dotnet-router — и `dotnet@dotnet-agent-skills` при `dotnet_skills=true`.

## Секреты

Живут только в `~/.config/claudefiles/` — вне репозитория, `chmod 600`:

- **`secrets.json`** — флаги (`profile_super`, `context7`, `playwright`, `azure_mcp`, `ado`, `dotnet_skills`, `codex_review`, `codex_plugin`), `context7_api_key`, ADO email/orgs/PAT-ы. Заполняется prompt-once при TTY. Авторизацию Codex (`~/.codex/auth.json`) claudefiles **не** трогает — это `codex login`.
- **`managed-mcp.<profile>.json`** — манифест применённых MCP-серверов профиля (для сверки и удаления ровно своего); содержит base64-PAT для ADO (в профиле super), поэтому тоже `600`. Legacy `managed-mcp.json` (из до-профильной раскладки) потребляется один раз при миграции дефолтного каталога и затем удаляется.

Тест гарантирует, что ни один секретный путь не трекается; репозиторий **публичный**.

## dotnet-router (одна из компонент)

Доставка ~100 [dotnet-skills](https://github.com/dotnet/skills) во все этапы [superpowers](https://github.com/anthropics/claude-plugins-official) — при постоянной цене контекста ~350 символов вместо ~18k токенов за полную установку плагинов.

- **`dotnet-router`** — единственный установленный скилл (симлинк). Его описание триггерит любую .NET-работу; тело задаёт правила для каждого этапа superpowers.
- **Двухуровневый каталог** (генерируется `setup.sh`, **не в git**): `INDEX.md` — карта «этап → домены» + имена скиллов; `CATALOG-<домен>.md` × 16 — дословные описания (USE FOR / DO NOT USE FOR) с абсолютными путями к SKILL.md для этой машины.
- **Скиллы не устанавливаются** — читаются `Read`-ом из read-only клона `skills/dotnet-skills`. К субагентам знание едет блоками `**Skills:**` / `**Service root:**` в планах.
- **SessionStart-хук** — детектирует .NET-воркспейс и напоминает про роутер.

Только `SKILL.md` роутера в git; каталог — генерируемый машинно-специфичный артефакт (абсолютные пути), поэтому в `.gitignore` — иначе каждый чекаут «пачкался» бы и ломал `git pull --ff-only` deploy-копии.

## Codex-ревью (кросс-провайдерная проверка)

Опциональный флаг **`codex_review`** добавляет второго, максимально непохожего ревьюера — [Codex](https://github.com/openai/codex) (GPT-5.5, high reasoning) — поверх самопроверки superpowers. На трёх чекпоинтах (спека, план, дифф кода) артефакт уходит в Codex, а провалидированные замечания вплетаются в то, что показывается пользователю. Ревью **совещательное и однопроходное**: Codex советует, но не блокирует; findings триажатся дисциплиной `receiving-code-review`.

- **Скилл `codex-review`** — «мозг» фичи: роутинг по типу артефакта (`codex exec` для `.md`-спек/планов в read-only sandbox репозитория, `codex review --base` для диффа), пиннинг модели inline (`-c model=…`), мягкая деградация при отсутствии/неавторизованности `codex`. Флаг `codex_review` спрашивается только при выбранном профиле `super`; скилл ставится копией в `~/.claude-super/skills`.
- **Наж в `CLAUDE.md` профиля super** (`~/.claude-super/CLAUDE.md`) — marker-блок (безусловное правило, всегда в контексте), напоминающий прогнать скилл на чекпоинтах. Управляется идемпотентно; выключение флага убирает блок, сохраняя пользовательское содержимое.
- **Предусловие — `codex login`.** claudefiles владеет только скиллом и нажем; авторизация Codex живёт в `~/.codex/auth.json` и остаётся за пользователем. readiness-фаза сообщает версию `codex` и статус логина; глобальный `~/.codex/config.toml` не трогается (модель/effort передаются inline на каждом вызове).
- **Опциональный `codex_plugin`** (по умолчанию off, эффективно `codex_review && codex_plugin`) — доставляет плагин `codex@openai-codex` для adversarial-режима. Никогда не включён, пока выключен `codex_review`.

## Раскладка

```
setup.sh                      # оркестратор: preflight → config → deps → профили (vanilla + super) → verify
lib/*.sh                      # config, deps, settings, skills, plugins, mcp, hooks, claudemd, profiles, common, apply-if-changed
lib/py/                       # config_io.py, jsonmerge.py
claude/settings/              # settings.vanilla.template.json + settings.super.template.json (управляемые ключи профиля)
claude/statusline/statusline.sh   # статуслайн (vanilla и super)
claude/skills/context7-mcp/   # SKILL.md (копируется в каждый профиль)
claude/skills/codex-review/   # SKILL.md кросс-ревьюера (копируется в super при codex_review)
claude/skills/dotnet-router/  # SKILL.md роутера (каталог генерируется, вне git; только для super при dotnet_skills)
claude/mcp/build_servers.py   # сборка MCP-конфига из secrets.json, per-профиль
claude/hooks/detect-dotnet.sh # SessionStart-хук (только профиль super)
skills/tools/                 # генератор каталога + все test-*.sh + run-all-tests.sh
skills/dotnet-skills/         # read-only клон (не в git, клонирует setup.sh)
docs/superpowers/             # спека, план, смоук-протоколы
legacy/claude/                # прежнее содержимое (агенты, azure-devops-mcp) — не активируется
```

Управляемая цепочка chezmoi (в репозитории dotfiles): external `.chezmoiexternal.toml` → `run_after_setup-claudefiles.sh.tmpl` (HEAD-compare → `setup.sh`).

## Legacy

В `legacy/claude/` — прежнее содержимое: агенты (`implementer-dotnet`, `project-manager`, `code-reviewer`, `git-engineer`, `codebase-guardian`), скиллы `azure-devops-mcp` и `frontend-design-pro`, правила стиля. Вынесено из `.claude/`, чтобы не активироваться как project-конфиг; переносить в `~/.claude/` — поштучно и осознанно.
