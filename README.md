# claudefiles

Доставка ~100 [dotnet-skills](https://github.com/dotnet/skills) во все этапы процесса [superpowers](https://github.com/anthropics/claude-plugins-official) для Claude Code — при постоянной цене контекста ~350 символов вместо ~18k токенов за полную установку плагинов.

## Как это работает

- **`dotnet-router`** — единственный установленный скилл (симлинк в `~/.claude/skills/`). Его описание триггерит любую .NET-работу; тело задаёт правила для каждого этапа superpowers.
- **Двухуровневый каталог** (генерируется, в git): `INDEX.md` — карта «этап → домены» + все имена скиллов; `CATALOG-<домен>.md` × 16 — полные дословные описания (USE FOR / DO NOT USE FOR) с абсолютными путями к SKILL.md.
- **Скиллы не устанавливаются** — читаются `Read`-ом по пути из read-only клона `skills/dotnet-skills`. К субагентам знание едет блоками `**Skills:**` и `**Service root:**`, вшитыми в планы.
- **SessionStart-хук** — детектирует .NET-воркспейс (`*.sln`/`*.csproj`/`global.json`, глубина 6, prune тяжёлых папок) и напоминает про роутер.

Дизайн: `docs/superpowers/specs/`, план: `docs/superpowers/plans/`, протокол смоука: `docs/superpowers/smoke-results-dotnet-delivery.md`.

## Установка на новой машине

```bash
git clone https://github.com/stpntkhnv/claudefiles.git ~/dev/claudefiles && cd ~/dev/claudefiles && ./setup.sh
```

Требуется: git, bash, GNU coreutils/awk, python3. `setup.sh` идемпотентен: клонирует/обновляет dotnet-skills, генерирует каталог с путями этой машины, ставит симлинк, вписывает хук в `settings.json` (с бэкапом), гоняет тесты.

Отдельно, изнутри Claude Code (setup.sh напомнит, если не найдёт): `/plugin install superpowers@claude-plugins-official` — процессный каркас, в чьи этапы встраивается роутер. Роутер работает и без него, но доставка знания через планы и субагентов опирается на его процесс.

## Обновление dotnet-skills

```bash
./setup.sh   # pull + регенерация + тесты
```

## Раскладка

```
claude/skills/dotnet-router/  # SKILL.md роутера + генерируемый каталог
claude/hooks/detect-dotnet.sh # SessionStart-хук
skills/tools/                 # генератор каталога + тесты
skills/dotnet-skills/         # read-only клон (не в git, тянет setup.sh)
docs/superpowers/             # спека, план, смоук-протокол
legacy/claude/                # старое содержимое репо (агенты, azure-devops-mcp) — не активируется
```

## Legacy

В `legacy/claude/` — прежнее содержимое репозитория: агенты (`implementer-dotnet`, `project-manager`, `code-reviewer`, `git-engineer`, `codebase-guardian`), скиллы `azure-devops-mcp` и `frontend-design-pro`, правила стиля. Сознательно вынесено из `.claude/`, чтобы не активироваться как project-конфиг; переносить в `~/.claude/` — поштучно и осознанно.
