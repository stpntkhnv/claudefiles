# Дизайн: профиль `g` — gstack как этап видения

**Дата:** 2026-07-27
**Статус:** утверждён (brainstorming), готов к написанию плана
**Автор:** Claude (Opus 5) + Stsiapan

## Проблема

Разные инструменты хороши для разного. Сегодня в репозитории два профиля: `vanilla`
(лёгкая база) и `super` (полный superpowers-стек). Superpowers силён от спецификации и ниже:
спека, план, TDD, ревью. Но этап **до** спецификации — спор о видении, «какие фичи вообще
нужны», «как это должно выглядеть и ощущаться», «от чего отказываемся» — он покрывает слабо,
потому что заточен на технический маршрут.

[gstack](https://github.com/garrytan/gstack) закрывает ровно этот пробел: 23 скилла-роли
(CEO, дизайнер, eng-manager, release-manager, QA), из которых для видения нужны
`/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`,
`/design-consultation`, `/design-shotgun`, `/cso`, `/investigate`.

## Цель

Третий профиль **`g`** (`~/.claude-g`, команда `claude-g`) — выделенная комната для этапа
видения. Раскатывается той же одной командой `./setup.sh`, идемпотентно, снимаемо, без
секретов в git.

**Граница ответственности между профилями:**

- `claude-g` отвечает за **видение**: какие фичи нужны, какие решения приняты, от чего
  отказались, как это должно выглядеть и ощущаться. Артефакт — документ видения.
- `claude-super` отвечает за **спецификацию и ниже**: как положить видение на технологию,
  затем план реализации, код, ревью.

Спецификация — это мост между идеей и планом реализации, и он остаётся за superpowers.
gstack до спецификации не доходит.

## Почему отдельный профиль, а не добавка в super

gstack раскладывает около 50 скиллов, и описание каждого грузится в контекст **каждой**
сессии. Это ровно та цена, от которой в этом репозитории уходил `dotnet-router` (постоянные
~350 символов вместо ~18k токенов за полную установку). В выделенном каталоге эта цена
платится только на этапе видения и не течёт в `vanilla` и `super`.

Второй довод: два процессных каркаса в одном профиле конкурировали бы за одни и те же этапы
(brainstorming, plan, review), и выбор между ними стал бы недетерминированным.

## Ключевые проверенные факты (обоснование архитектуры)

Проверено чтением инсталлятора `garrytan/gstack` (VERSION 1.60.1.0):

- **`CLAUDE_CONFIG_DIR` инсталлятор не понимает.** `hosts/claude.ts:10` жёстко задаёт
  `globalRoot: '.claude/skills/gstack'`; переменная участвует только в собственных тестах
  gstack. Это открытый апстрим-issue (`TODOS.md:44`, #349).
- **Но целевой каталог выводится из места клона.** `setup:19` считает
  `INSTALL_SKILLS_DIR="$(dirname "$INSTALL_GSTACK_DIR")"`, а `setup:984` при
  `basename == "skills"` уходит в ветку установки **на месте**. Клон в
  `~/.claude-g/skills/gstack` ставит всё в `~/.claude-g/skills` и `~/.claude` не трогает.
  Ветка с хардкодом `$HOME/.claude/skills` (`setup:1021`) срабатывает только при клоне вне
  каталога `skills`.
- **Установка сводима к неинтерактивной.** `--host claude` — дефолт (`setup:79`), и
  `setup:213` поднимает только `INSTALL_CLAUDE=1`; чужие хосты (`~/.codex/skills` и прочие)
  затрагиваются лишь при `--host auto` (`setup:204-208`). `--no-team` не трогает проектные
  репозитории. `--no-plan-tune-hooks` снимает интерактивный вопрос `setup:1476`.
  `GSTACK_SKIP_FONTS=1` снимает установку шрифтов через `sudo pacman` (`setup:312`).
- **`bun` обязателен.** `setup:6` выходит с ошибкой без него. Пакет `bun` есть в Arch `extra`.
- **Клон после установки всегда грязный.** `setup:993` запускает `bin/gstack-patch-names`,
  который правит поле `name:` внутри SKILL.md клона, `setup:999` досогласовывает через
  `gstack-relink`. Привычный по этому репозиторию `git pull --ff-only` на таком дереве упадёт.
- **`model-overlays/` — промпт-оверлеи под семейство модели**, а не выбор модели. Конфликта с
  ключом `model` в `settings.json` нет.
- **`skills_apply` не чистит каталог целиком** (`lib/skills.sh:4-7`), только свои подкаталоги.
  Символлинки gstack в `~/.claude-g/skills/` с `context7-mcp` уживаются.

## Ограничения

- **Идемпотентность.** Повторный `setup.sh` не даёт diff ни в одном каталоге и выходит 0.
- **Профили независимы.** Провал `g` не рушит `vanilla` и `super`.
- **Публичный репозиторий.** Клон gstack и каталоги профилей — вне git.
- **Не трогать файлы gstack.** claudefiles владеет клоном и вызовом его инсталлятора,
  но не патчит его содержимое.
- **Тестируемость.** Всё новое — против фикстур, фейкового `claude` и фейкового `bun`,
  как принято в репозитории.

## Не-цели (осознанный YAGNI)

- **Не изолируем `~/.gstack`.** `GSTACK_HOME` это умеет, но там состояние самого инструмента
  (`config.yaml`, аналитика, `projects/`), а не конфиг Claude. Изоляция сломала бы
  `gstack-config`, `gstack-analytics` и `gstack-uninstall`, которые пользователь запускает
  руками из шелла без переменной. Фиксируем в доках: claudefiles этим каталогом не владеет.
- **Не удаляем `~/.claude-g` при выключении флага.** Это совпадает с существующим поведением:
  выключение `profile_super` не удаляет `~/.claude-super`. Каталог просто перестаёт
  обновляться. Ручная чистка: `gstack-uninstall`, затем `rm -rf ~/.claude-g` и
  `rm -f ~/.local/bin/claude-g`.
- **Не ставим плагин-обёртку `Ahacad/gstack`.** Она экспонирует 8 скиллов из 23, и среди
  недостающих ровно те, что нужны для видения (`/office-hours`, `/design-consultation`,
  `/design-shotgun`, `/cso`).
- **Не чиним апстримный issue про `CLAUDE_CONFIG_DIR`.** Обходим раскладкой клона.
- **Не используем `--team` режим gstack** и не трогаем `.claude/` рабочих репозиториев.
- **Не тащим gstack в `vanilla` или `super`.**

## Профили после изменения

| Профиль | Каталог | Вызов | Роль |
|---------|---------|-------|------|
| **vanilla** | `~/.claude` | `claude` | лёгкая база на каждый день |
| **super** | `~/.claude-super` | `claude-super` | спека, план, код, ревью (superpowers) |
| **g** | `~/.claude-g` | `claude-g` | видение (gstack) |

## Архитектура

### Рецепт `recipe_g`

Каталог достаётся бесплатно: `profile_dir` (`lib/profiles.sh:3`) уже отдаёт `~/.claude-g`
для любого не-vanilla имени. Wrapper `~/.local/bin/claude-g` и симлинк `.credentials.json`
тоже бесплатны из `provision_selected` (`lib/profiles.sh:73-75`). Оркестратор ради третьего
профиля не переписывается — это и было заявленным свойством раскладки.

```
recipe_g() {
  settings_apply  "$root/claude/settings/settings.g.template.json" false false
  skills_apply    "$root" false false            # только context7-mcp
  claudemd_apply  false                          # без codex-нажа
  claudemd_personal_apply true                   # личный стиль письма
  claudemd_vision_apply producer                 # НОВОЕ
  gstack_apply || return 1                       # НОВОЕ, провал роняет профиль
  local servers; servers="$(python3 "$root/claude/mcp/build_servers.py" "$(config_path)" g)"
  mcp_apply "$servers" "$(_mcp_manifest g)"
}
```

Порядок в `selected`: `vanilla`, затем `super`, затем `g` — `vanilla` первым, как сейчас.
`gstack_apply` аргументов не принимает: целевой каталог берётся из `CLAUDEFILES_TARGET`,
источник — из константы модуля.

### `claude/settings/settings.g.template.json`

Управляемые ключи: `theme: auto`, `tui: fullscreen`, `statusLine` → `<STATUSLINE_PATH> g`,
`hooks` со звуком на `Stop` и `Notification`, плюс `model: opus[1m]` и `effortLevel: xhigh`.

Обоснование модели: спор о видении — самая рассуждательная работа из трёх профилей.
`enabledPlugins`, `extraKnownMarketplaces` и `SessionStart` профиль не декларирует, поэтому
`jsonmerge.py` их из target удалит, если они там окажутся.

### `lib/gstack.sh` — новый модуль

Одна публичная функция `gstack_apply`, по контракту остальных appliers: владеет своим
артефактом и идемпотентна.

Константа с URL апстрима и override для тестов:
`GSTACK_REPO="${CLAUDEFILES_GSTACK_REPO:-https://github.com/garrytan/gstack.git}"`.

Целевой путь: `dst="${CLAUDEFILES_TARGET}/skills/gstack"`.

Шаги:

1. **Проверка `bun`.** Нет — `warn` с командой установки и `return 1`. Тихо отдавать пустой
   профиль нельзя.
2. **Клон, если нет.** `git clone --single-branch --depth 1 "$GSTACK_REPO" "$dst"`.
3. **Обновление, если есть.** `git fetch --depth 1 origin` затем `git reset --hard FETCH_HEAD`.
   Именно `reset --hard`, а не `pull --ff-only`: рабочее дерево после первой установки всегда
   грязное (`setup:993`, `setup:999` правят `name:` в SKILL.md клона).
4. **Гейт по SHA.** Прогонять инсталлятор только если `HEAD` отличается от записанного в
   маркере `${CLAUDEFILES_TARGET}/.gstack-setup-head` (по образцу `lib/apply-if-changed.sh`).
   Без гейта каждый `setup.sh` пересобирал бы `browse` через bun, и свойство «повторный прогон
   ничего не делает» перестало бы выполняться.
5. **Прогон инсталлятора:**
   ```
   ( cd "$dst" && GSTACK_SKIP_FONTS=1 ./setup --host claude --no-team --no-plan-tune-hooks -q )
   ```
   `--host claude` уже дефолт, но пишется явно: если апстрим сменит дефолт на `auto`,
   `setup:204-208` подхватит установленный `codex` и полезет в `~/.codex/skills`, мимо профиля.
6. **Запись маркера** только после успешного прогона. Провал инсталлятора — `warn` и
   `return 1` с несохранённым маркером, чтобы следующий прогон попробовал снова.

**Автообновление.** Шаг 3 выполняется на каждом прогоне `setup.sh`, поэтому gstack всегда
свежий. Гейт по SHA — не «ручное обновление», а защита от лишней пересборки: если апстрим не
двигался, инсталлятор не запускается.

**Чистка стейл-символлинков** при переименовании скиллов в апстриме — забота самого gstack
(`cleanup_old_claude_symlinks`, `gstack-relink`, `setup:988-1001`).

### Стык профилей: `docs/vision/`

Договорённость закрепляется marker-блоками с обеих сторон, чтобы передача работала без
ручного напоминания.

**`claudemd.sh` — сначала убрать дублирование.** `claudemd_apply` (`lib/claudemd.sh:13-34`) и
`claudemd_personal_apply` (`:41-60`) уже почти идентичны; третья копия того же awk сделала бы
файл нечитаемым. Выделяется приватный `_claudemd_block_apply <begin> <end> <rule> <enabled>`,
все три публичные функции становятся тонкими обёртками. Поведение не меняется, существующие
тесты `test-claudemd.sh` остаются зелёными.

**Новая `claudemd_vision_apply <role>`**, роль `producer|consumer|off`, один маркер
`claudefiles:vision`:

- **producer** (профиль `g`): итог обсуждения ложится в `docs/vision/YYYY-MM-DD-<тема>.md` —
  какие фичи нужны, какие решения приняты, от чего отказались, как это должно выглядеть и
  ощущаться. Спецификацию и план реализации не писать, это этап superpowers.
- **consumer** (профиль `super`, только при `profile_gstack=true`): перед
  `superpowers:brainstorming` проверить `docs/vision/`; если по теме есть документ видения,
  прочитать его и взять как вход, не переоткрывая вопросы видения заново.
- **off**: блок снимается, остальное содержимое `CLAUDE.md` сохраняется.

Выключение `profile_gstack` переводит `super` в `off` на следующем прогоне — симметрично тому,
как ведёт себя `codex_review`.

### Точечные правки существующих файлов

| Файл | Правка |
|------|--------|
| `setup.sh:12` | `config_ensure_flag profile_gstack "Install the 'g' profile (gstack, vision stage)? (y/N)"` |
| `setup.sh:47-56` | `gstack_dep` и седьмой аргумент `deps_apply` |
| `setup.sh:66-67` | `[ "$(config_flag profile_gstack)" = true ] && selected+=(g)` |
| `setup.sh:82` | итоговая строка упоминает `claude-g` |
| `lib/profiles.sh` | `recipe_g` |
| `lib/deps.sh:67` | седьмой параметр `gstack`; `dep_require "gstack installer" bun -- bun` |
| `lib/deps.sh:110` | `readiness_report` — строка про `bun` |
| `lib/claudemd.sh` | `_claudemd_block_apply` + `claudemd_vision_apply` |
| `claude/mcp/build_servers.py:23` | `if profile in ("vanilla", "g")` |
| `claude/statusline/statusline.sh:52-56` | `g)` со своим цветом (сейчас падает в жёлтый `*)`, который означает «незнакомый профиль») |

`recipe_super` дополняется вызовом `claudemd_vision_apply` с ролью `consumer` при
`profile_gstack=true`, иначе `off`.

## Обработка ошибок

Контракт отличается от `deps` и `plugins`, которые по `docs/invariants.md:13` не роняют
прогон. Профиль `g` без gstack — пустая оболочка, ровно как `super` без superpowers, поэтому
берётся контракт super (`lib/profiles.sh:30-35`):

- `gstack_apply` при любом провале (нет `bun`, не склонировалось, инсталлятор упал) возвращает
  1 и печатает `warn` с причиной.
- `recipe_g` возвращает 1, профиль попадает в `PROVISION_FAILED`, `vanilla` и `super`
  раскатываются полностью, `setup.sh` выходит 1 со списком упавших профилей.
- Маркер SHA не пишется при провале, поэтому следующий прогон повторит попытку.
- Отсутствие `bun` не превращается в тихий успех: `deps_apply` его предлагает поставить, отказ
  это осознанный выбор пользователя, но профиль тогда честно помечается упавшим.

## Тестирование

Новый `skills/tools/test-gstack.sh` против **фикстурного bare-репозитория** (через
`CLAUDEFILES_GSTACK_REPO`), в котором лежит фейковый `setup`, пишущий маркер вызова, и
**фейкового `bun`** на PATH — по образцу фейкового `claude` в существующих тестах. Сети в
тестах нет.

- Свежая машина: клон появляется в `<target>/skills/gstack`, фейковый инсталлятор вызван один
  раз, маркер SHA записан.
- Повторный прогон без движения апстрима: инсталлятор **не** вызван, нулевой diff.
- Апстрим двинулся: `fetch` + `reset --hard` подтянули, инсталлятор вызван снова, маркер обновлён.
- Грязное рабочее дерево (эмулируется правкой файла в клоне): обновление проходит, то есть
  используется `reset --hard`, а не `pull --ff-only`.
- Нет `bun`: `gstack_apply` возвращает 1 и печатает `warn`.
- Инсталлятор упал: `gstack_apply` возвращает 1, маркер SHA не записан.
- Аргументы вызова: фейковый `setup` фиксирует, что получил `--host claude`, `--no-team`,
  `--no-plan-tune-hooks` и `GSTACK_SKIP_FONTS=1`.
- Изоляция: после прогона `$HOME/.claude/skills/gstack` не существует.

Расширения существующих тестов:

- `test-profiles.sh` — `recipe_g` пишет в `~/.claude-g`, а не в `~/.claude`; провал `g` даёт
  `PROVISION_FAILED=(g)` при живых `vanilla` и `super`.
- `test-settings.sh` — шаблон `g` даёт `model`, `effortLevel`, `statusLine … g`, и не даёт
  `enabledPlugins` и `hooks.SessionStart`.
- `test-claudemd.sh` — три блока сосуществуют и идемпотентны; `producer`/`consumer`/`off`;
  снятие одного блока сохраняет два других и пользовательский текст.
- `test-statusline.sh` — бейдж `[g]` со своим цветом, санитайзинг как у остальных.
- `test-mcp.sh` — профиль `g` получает только `context7`, манифест `managed-mcp.g.json`.
- `test-deps.sh` — `gstack_dep=true` требует `bun`, `false` не требует; ветка не фатальна.
- `test-setup-idempotent.sh`, `test-multiprofile.sh` — расширить на три профиля.

`test-secrets-not-tracked.sh` не меняется: клон gstack лежит в каталоге профиля, вне
репозитория, поэтому записи в `.gitignore` не требует.

## Что в git / вне git

- **В git:** `lib/gstack.sh`, `claude/settings/settings.g.template.json`, правки
  `lib/profiles.sh`, `lib/deps.sh`, `lib/claudemd.sh`, `setup.sh`, `build_servers.py`,
  `statusline.sh`, тексты marker-блоков, тесты, документация.
- **Вне git:** клон gstack (`~/.claude-g/skills/gstack`), маркер `.gstack-setup-head`,
  каталог профиля, `managed-mcp.g.json`, wrapper, состояние `~/.gstack`.

## Документация к обновлению

`README.md` (таблица профилей, раскладка, таблица системных зависимостей),
`docs/architecture.md` (три диаграммы: компоненты, прогон, различие рецептов),
`docs/runtime.md` (что живёт в сессии `claude-g`), `docs/user-flow.md` (третья ветка опроса),
`docs/invariants.md` (контракт фатальности `gstack_apply`),
`docs/config-schema.md` (флаг `profile_gstack`).

## Раскладка (дельта)

```
lib/gstack.sh                              # НОВОЕ: клон, обновление, гейт по SHA, прогон инсталлятора
lib/profiles.sh                            # правка: recipe_g + vision-блок в recipe_super
lib/claudemd.sh                            # правка: _claudemd_block_apply + claudemd_vision_apply
lib/deps.sh                                # правка: седьмой флаг, зависимость bun
setup.sh                                   # правка: флаг profile_gstack, deps, selected, итоговая строка
claude/settings/settings.g.template.json   # НОВОЕ
claude/mcp/build_servers.py                # правка: ветка профиля g
claude/statusline/statusline.sh            # правка: цвет бейджа g
skills/tools/test-gstack.sh                # НОВОЕ
skills/tools/test-*.sh                     # расширения
```
