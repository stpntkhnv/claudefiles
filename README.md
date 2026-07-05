# claudefiles

Самостоятельный репозиторий, который владеет **всей** конфигурацией `~/.claude` (Claude Code) и ставит её одной идемпотентной командой. `settings.json`, персональные скиллы, плагины, MCP-серверы и SessionStart-хук — всё раскатывает `setup.sh`. chezmoi тянет этот репозиторий как external и перезапускает `setup.sh` при изменении HEAD. Секреты спрашиваются один раз в локальное хранилище вне git — ничего секретного в репозиторий не попадает.

## Что делает `setup.sh` (7 фаз)

`lib/*.sh` — сфокусированные модули, каждый тестируется против фейкового `claude` и фикстур-`$HOME`. Оркестратор `setup.sh` гоняет их по порядку:

1. **preflight** — проверка git/python3; про `claude` предупреждает, но не падает.
2. **config** — читает/спрашивает флаги и секреты из `~/.config/claudefiles/secrets.json` (только при TTY; без TTY — падает с понятным списком, а не висит).
3. **settings.json** — заменяет управляемые ключи (`model`, `effortLevel`, `tui`, `theme`, `enabledPlugins`, `extraKnownMarketplaces`, `hooks`) из шаблона, сохраняя любые чужие ключи. Плагин dotnet попадает в `enabledPlugins` только если флаг включён.
4. **skills** — копирует `context7-mcp`, а при `dotnet_skills=true` клонирует `dotnet/skills` (если нет), регенерирует каталог с путями этой машины и ставит симлинк `dotnet-router`.
5. **plugins** — идемпотентно добавляет marketplace `dotnet/skills` и ставит плагин (гварды: повторный запуск — no-op).
6. **mcp** — сверяет user-scope MCP-серверы с манифестом `managed-mcp.json`: если набор не менялся — ноль вызовов; иначе убирает ровно ранее управляемые имена (без «подметания» по префиксу) и добавляет текущие. Чужие/неуправляемые серверы не трогает.
7. **verify** — валидирует `settings.json`, самотест каталога.

`setup.sh` запущенный дважды не даёт diff и выходит 0.

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

Требуется: git, bash, GNU coreutils/awk, python3 (только stdlib). Плагин `superpowers@claude-plugins-official` ставится внутри Claude Code (`/plugin install superpowers@claude-plugins-official`) — процессный каркас, в чьи этапы встраивается dotnet-router.

## Секреты

Живут только в `~/.config/claudefiles/` — вне репозитория, `chmod 600`:

- **`secrets.json`** — флаги (`context7`, `playwright`, `azure_mcp`, `ado`, `dotnet_skills`), `context7_api_key`, ADO email/orgs/PAT-ы. Заполняется prompt-once при TTY.
- **`managed-mcp.json`** — манифест применённых MCP-серверов (для сверки и удаления ровно своего); содержит base64-PAT для ADO, поэтому тоже `600`.

Тест гарантирует, что ни один секретный путь не трекается; репозиторий **публичный**.

## dotnet-router (одна из компонент)

Доставка ~100 [dotnet-skills](https://github.com/dotnet/skills) во все этапы [superpowers](https://github.com/anthropics/claude-plugins-official) — при постоянной цене контекста ~350 символов вместо ~18k токенов за полную установку плагинов.

- **`dotnet-router`** — единственный установленный скилл (симлинк). Его описание триггерит любую .NET-работу; тело задаёт правила для каждого этапа superpowers.
- **Двухуровневый каталог** (генерируется `setup.sh`, **не в git**): `INDEX.md` — карта «этап → домены» + имена скиллов; `CATALOG-<домен>.md` × 16 — дословные описания (USE FOR / DO NOT USE FOR) с абсолютными путями к SKILL.md для этой машины.
- **Скиллы не устанавливаются** — читаются `Read`-ом из read-only клона `skills/dotnet-skills`. К субагентам знание едет блоками `**Skills:**` / `**Service root:**` в планах.
- **SessionStart-хук** — детектирует .NET-воркспейс и напоминает про роутер.

Только `SKILL.md` роутера в git; каталог — генерируемый машинно-специфичный артефакт (абсолютные пути), поэтому в `.gitignore` — иначе каждый чекаут «пачкался» бы и ломал `git pull --ff-only` deploy-копии.

## Раскладка

```
setup.sh                      # оркестратор (7 фаз)
lib/*.sh                      # config, settings, skills, plugins, mcp, hooks, common, apply-if-changed
lib/py/                       # config_io.py, jsonmerge.py
claude/settings/              # settings.template.json (управляемые ключи)
claude/skills/context7-mcp/   # SKILL.md (копируется в ~/.claude)
claude/skills/dotnet-router/  # SKILL.md роутера (каталог генерируется, вне git)
claude/mcp/build_servers.py   # сборка MCP-конфига из secrets.json
claude/hooks/detect-dotnet.sh # SessionStart-хук
skills/tools/                 # генератор каталога + все test-*.sh + run-all-tests.sh
skills/dotnet-skills/         # read-only клон (не в git, клонирует setup.sh)
docs/superpowers/             # спека, план, смоук-протоколы
legacy/claude/                # прежнее содержимое (агенты, azure-devops-mcp) — не активируется
```

Управляемая цепочка chezmoi (в репозитории dotfiles): external `.chezmoiexternal.toml` → `run_after_setup-claudefiles.sh.tmpl` (HEAD-compare → `setup.sh`).

## Legacy

В `legacy/claude/` — прежнее содержимое: агенты (`implementer-dotnet`, `project-manager`, `code-reviewer`, `git-engineer`, `codebase-guardian`), скиллы `azure-devops-mcp` и `frontend-design-pro`, правила стиля. Вынесено из `.claude/`, чтобы не активироваться как project-конфиг; переносить в `~/.claude/` — поштучно и осознанно.
