# Дизайн: `codex-review` — кросс-провайдерное ревью артефактов поверх superpowers

**Дата:** 2026-07-06
**Статус:** утверждён (brainstorming), готов к написанию плана
**Автор:** Claude (Opus 4.8) + Stsiapan

## Проблема

Качество спек, планов и кода заметно растёт, когда их проверяет **второй, максимально
непохожий агент** — Codex с моделью GPT-5.5 на high reasoning. Сейчас это делается
вручную: скопировать план → вставить в Codex → прочитать ревью. Хочется автоматизировать
копипаст, оставив саму связку в стиле репозитория: чисто, идемпотентно, протестировано.

Самопроверка superpowers остаётся; Codex — **дополнительный** независимый ревьюер.

## Цель

На трёх естественных чекпоинтах superpowers артефакт уходит в Codex на ревью, а
провалидированные замечания вплетаются в то, что показывается пользователю — **без единой
правки файлов superpowers** (они тестируются и обновляются извне, ломать их нельзя).

## Ограничения

- **Не трогать файлы superpowers.** Интеграция — только слой сверху (личный скилл + наж + конфиг).
- **Идемпотентность.** Повторный `setup.sh` не даёт diff и выходит 0 (инвариант репозитория).
- **Флаг-гейтинг.** Фича включается флагом, как `dotnet_skills`; выключенная — не оставляет следов в `~/.claude`.
- **Публичный репозиторий.** Никаких секретов в git. Codex-авторизация живёт в `~/.codex/auth.json` (управляет `codex login`), claudefiles её не касается.
- **Тестируемость.** Логика скилла тестируется против фейкового `codex`, как всё в репо — против фейкового `claude`.

## Не-цели (осознанный YAGNI)

- Авто-цикл «ревью → правка → ре-ревью до APPROVED». Модель — **один проход, совет**.
- Stop-хук-гейт, блокирующий ответы. Нет — триггер мягкий, я триажу.
- Pipeline-оркестратор / собственный сабагент.
- Установка плагина `codex@openai-codex` в MVP (см. «Плагин — опционально»).

## Три чекпоинта superpowers

| Чекпоинт | Артефакт | Путь / момент | Движок Codex |
|----------|----------|---------------|--------------|
| после brainstorming | спека | `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`, перед «User reviews spec» gate | `codex exec` (design-критик) |
| после writing-plans | план | `docs/superpowers/plans/YYYY-MM-DD-<feature>.md` | `codex exec` (plan-критик) |
| requesting-code-review | дифф кода | момент запроса ревью, есть `BASE_SHA`/`HEAD_SHA` | `codex review --base <BASE_SHA>` |

## Архитектура

### Компонент A — скилл `codex-review`

Живёт в `claude/skills/codex-review/SKILL.md`, ставится `skills_apply` **копией** в
`~/.claude/skills/codex-review/` (как `context7-mcp`). Это «мозг» фичи. Тело задаёт:

**Роутинг по типу артефакта:**

- **Спека/план (`.md`)** — `codex exec` в **read-only sandbox, запущенный в корне репо**
  (`--cd <repo_root>`), путь артефакта передаётся **в промпте** (не stdin), чтобы Codex мог
  подтянуть контекст — соседние спеки, `setup.sh`, существующие паттерны — и не плодить false
  positives. Промпт — **design/plan-критик** (не «код-ревью»-линза): необъявленные допущения,
  пропущенные edge-кейсы, scope creep, внутренние противоречия, тестируемость, более простые
  альтернативы. Финал вывода: `VERDICT: SOLID | REVISE` + одна строка обоснования.
- **Дифф кода** — `codex review --base <BASE_SHA>` (встроенное код-ревью Codex над тем же
  диапазоном коммитов, что смотрит ревьюер superpowers). Кросс-провайдерное покрытие той же
  работы. `codex review` **есть** в CLI (проверено на v0.142.5: флаги `--base`/`--commit`/
  `--uncommitted`); принимает `-c`, но **не** `-m` (модель — только через `-c model=`).
  **Fallback**, если `codex review` недоступен на машине: `codex exec` с `git diff "$BASE_SHA"...HEAD`.

**Batch-safe вызов (обязателен для скриптового запуска):** каждый вызов —
`--sandbox read-only --skip-git-repo-check --ephemeral -o <tmpfile>` (детерминированный захват
вывода, без rollout/session-файлов), обёрнут в `timeout`. Ошибка авторизации / ненулевой exit /
таймаут ⇒ скилл **сообщает и пропускает** ревью (мягкая деградация), никогда не висит и не блокирует.

**Пиннинг модели — inline, без глобальных side-effects:** на каждом вызове
`-c model="<gpt-5.5>" -c model_reasoning_effort="high"`. `~/.codex/config.toml` **не трогаем** —
это меняло бы модель/стоимость/latency в обычных интерактивных сессиях пользователя (тот же
принцип «владей только своим», что claudefiles применяет к `settings.json`/MCP). Точная строка
`model` — константа в теле скилла (одно место, легко поменять), сверяется после `codex login`.
Если позже включат `codex_plugin` (`/codex:*` читает конфиг), для плагина заводим **Codex-профиль**
`-p claudefiles-codex-review`, а не правим базовый конфиг.

**Триаж (дисциплина `receiving-code-review`):** каждый finding проверяется против реального
артефакта/кода; валидное — вплетается/выносится пользователю, сомнительное или неверное —
аргументированно отклоняется (без слепого подчинения). **Один проход, без авто-цикла.**

### Компонент B — наж в `~/.claude/CLAUDE.md`

Новый управляемый артефакт (claudefiles владеет `~/.claude/CLAUDE.md`; ранее не управлялся).
Содержит **marker-блок**:

```
# >>> claudefiles:codex-review >>>
<standing-правило>
# <<< claudefiles:codex-review <<<
```

Правило: «На чекпоинтах spec-review / plan-review / code-review superpowers сперва прогони
скилл `codex-review` над артефактом и вплети провалидированные findings в то, что показываешь
пользователю». Правило **безусловное** (применимо ко всей superpowers-работе), поэтому дом —
`CLAUDE.md` (всегда в контексте), а не conditional SessionStart-хук как у dotnet-router. Это
делает мягкий триггер максимально надёжным.

### Поток данных

```
superpowers пишет спеку
  → упирается в свой user-review gate
  → правило из CLAUDE.md срабатывает
  → Claude зовёт codex-review
  → codex exec ревьюит (read-only, GPT-5.5/high)
  → Claude триажит findings (receiving-code-review)
  → показывает пользователю спеку ВМЕСТЕ с провалидированными замечаниями Codex
  → решает пользователь
```

Файлы superpowers не тронуты.

## Доставка через `setup.sh`

Новый флаг **`codex_review`** (спрашивается один раз в фазе `config`, как `dotnet_skills`)
гейтит фичу целиком. Затронутые фазы:

- **config** — `config_ensure_flag codex_review "Enable Codex cross-review? (y/N)"`.
- **deps** — проверка не только наличия на PATH, но и **запускаемости**: `codex --version`
  возвращает 0 и версия `>= 0.142.5` (min-version — контракт для `codex review` и batch-флагов;
  ловит битые stub-бинари вроде WindowsApps). Если нет/старая — печатает `npm install -g @openai/codex`
  (codex ставится npm-global, зависит от уже проверяемого `node`/`npx`). Не фатально.
- **skills** — `skills_apply` копирует `codex-review/SKILL.md` в `~/.claude/skills` при `codex_review=true`.
- **claude.md** (новая мелкая забота, напр. `lib/claudemd.sh`) — вписывает marker-блок с нажем
  в `~/.claude/CLAUDE.md`, сохраняя любое пользовательское содержимое; идемпотентно (replace
  блока по маркерам). При `codex_review=false` — блок удаляется, если был.
- **codex config** — **не управляем** (см. P1b ниже): модель/effort передаются inline через `-c`
  на каждом вызове, `~/.codex/config.toml` не трогаем. Никакого `lib/codexcfg.sh`.
- **verify** — `readiness_report` добавляет строку `codex`: запускается (`codex --version`, версия),
  **авторизован?** — парсит `codex doctor --json` (`overallStatus`, машиночитаемо).

## Конфиг модели и авторизация

- **`model_reasoning_effort = "high"`** — definite, передаётся inline: `-c model_reasoning_effort="high"`.
- **`model`** — вариант GPT-5.5, константа в теле скилла, inline: `-c model="<gpt-5.5>"`. Точная
  строка привязана к авторизованному аккаунту (модель account-gated), сверяется после `codex login`.
- **Глобальный `~/.codex/config.toml` не пишем** (P1b): inline-`-c` не меняет поведение обычных
  Codex-сессий пользователя. Принимают `-c` обе команды — `codex exec` и `codex review`.
- **Авторизация Codex** — предусловие фичи. На момент дизайна `codex doctor` показывает
  `no Codex credentials found` (нет `~/.codex/auth.json`). claudefiles **не управляет** авторизацией
  (это `codex login` / API-ключ пользователя), но `readiness`-фаза явно сообщает статус, а
  скилл при неавторизованном `codex` деградирует мягко (сообщает и пропускает ревью, не падает).

## Плагин — опционально, не в MVP

Поскольку `codex review` покрывает дифы сам, официальный плагин `codex@openai-codex`
(`openai/codex-plugin-cc`) выносится в **отдельный флаг `codex_plugin`, по умолчанию off**.
Включённый — `plugins_apply` доставляет marketplace `openai/codex-plugin-cc` + `enabledPlugins`,
а скилл начинает использовать `/codex:adversarial-review` для «челленджа» дизайна. Его Stop-хук
держим **выключенным**. Так MVP остаётся чистым, а дверь к adversarial-режиму и фоновым задачам
открыта позже без баласта в базовой поставке.

## Тестирование

- **`skills/tools/test-codex-review.sh`** против **фейкового `codex`** (echo канонического вывода),
  проверяет: форму команды (`--sandbox read-only --skip-git-repo-check --ephemeral -o`, inline
  `-c model=`/`-c model_reasoning_effort=`, `--cd`), роутинг (`exec` для `.md`, `review` для диффа),
  graceful-деградацию при отсутствующем/неавторизованном/таймаутящем `codex`, отсутствие утечки секретов.
- **`skills/tools/smoke-codex-review.sh`** (P2d) — **опциональный**, гоняется только если на машине
  есть реальный запускаемый `codex`: `codex --version` (min-version), `codex review --help` и
  `codex exec --help` экспонируют нужные флаги, `codex doctor --json` парсится. **Без сетевого
  model-run.** Ловит расхождение fake-контракта с реальным CLI (главный класс, который fake-тест пропускает).
- **`skills/tools/test-claudemd.sh`** — идемпотентность marker-merge (двойной apply = тот же файл;
  выключение флага убирает блок; пользовательское содержимое сохранено).
- **`skills/tools/test-deps.sh`** / **`test-settings.sh`** — дополняются веткой `codex_review`.
- Подключение новых тестов в `skills/tools/run-all-tests.sh` (smoke — как necessarily-skip при отсутствии codex).
- **Инвариант:** `setup.sh` дважды — ноль diff, exit 0 (включая новые артефакты).

## Раскладка новых/изменённых файлов

```
claude/skills/codex-review/SKILL.md        # новый — тело скилла
lib/claudemd.sh                            # новый — marker-merge ~/.claude/CLAUDE.md
lib/config.sh                              # +флаги codex_review, codex_plugin
lib/deps.sh                                # +ветка codex CLI
lib/skills.sh                              # +копирование codex-review
lib/plugins.sh                             # +опциональный codex@openai-codex (флаг codex_plugin)
setup.sh                                    # +claude.md фаза/шаг, readiness строка codex
skills/tools/test-codex-review.sh          # новый — fake-codex, форма/роутинг/деградация
skills/tools/smoke-codex-review.sh         # новый — опциональный smoke на реальном codex
skills/tools/test-claudemd.sh              # новый
skills/tools/run-all-tests.sh              # +подключение
docs/superpowers/specs/2026-07-06-codex-review-integration-design.md  # этот файл
```

## Открытые вопросы для фазы плана

1. Точная строка id модели GPT-5.5 (сверить после `codex login`; живёт константой в теле скилла).
2. Куда девать `claude.md`-шаг в порядке `setup.sh` — вероятно рядом с `skills`/`settings`; уточнить в плане.
3. Значение `timeout` для batch-вызова Codex (high reasoning медленный — не ставить слишком мало).

## Приложение: раунд 1 внешнего ревью (Codex)

Спека прогнана через Codex (GPT-5.5) до плана — валидация самой связки, которую строим.
Вердикт: **REVISE**, 6 findings. Триаж (дисциплина `receiving-code-review`):

- **P1a** (`codex review` якобы нет / заменить) — **премисса отклонена**: команда есть в v0.142.5
  (`--base`/`--commit`/`--uncommitted`, проверено локально; Codex судил по отстающим веб-докам).
  Hardening **принят**: pin `codex ≥ 0.142.5` + smoke-контракт + документированный `codex exec`-fallback.
- **P1b** (глобальный конфиг — side-effects на все сессии) — **принято**: убран `lib/codexcfg.sh` и
  запись `~/.codex/config.toml`; модель/effort inline через `-c`. Упрощение + нет побочек.
- **P2a** (только PATH мало) — **принято**: `codex --version` + `codex doctor --json` в deps/readiness.
- **P2b** (stdin лишает repo-контекста) — **принято**: `codex exec --cd <repo>` + путь в промпте.
- **P2c** (не batch-safe) — **принято**: `--skip-git-repo-check --ephemeral -o <file>` + `timeout` + auth-fail policy.
- **P2d** (fake-only тесты) — **принято**: добавлен опциональный smoke на реальном codex.
