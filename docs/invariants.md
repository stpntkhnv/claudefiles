# Инварианты claudefiles

Гарантии, которые держит тест-сьют (`skills/tools/`). Каждая строка: гарантия и тест-источник.

- **Идемпотентность / `zero-diff` на повторный прогон.** Второй `setup.sh` не меняет ни `settings`, ни CLAUDE.md — включая профили с несколькими одновременно включёнными marker-блоками (первый такой случай — профиль `g`: personal + vision) — ни MCP-манифест, ни плагины. Тесты: `test-setup-idempotent.sh`, `test-multiprofile.sh`, покомпонентно `test-mcp.sh`, `test-plugins.sh`, `test-claudemd.sh`.
- **Секреты с `chmod 600`.** `secrets.json` и MCP-манифесты создаются с правами 600. Тесты: `test-config.sh`, `test-mcp.sh`.
- **Секреты не в `git`.** `secrets.json`, `managed-mcp.json`, `last-applied-head`, `.env` не трекаются. Тест: `test-secrets-not-tracked.sh`.
- **Изоляция профилей.** Рецепты в субшелле без утечки `env` в вызывающего; отдельный target-каталог. Тесты: `test-profiles.sh`, `test-settings.sh`, `test-skills.sh`.
- **Миграция super→vanilla полная и одноразовая.** Плагины/хуки/`model`/`effortLevel`/`router`/super-MCP снимаются с дефолтного каталога, пользовательский контент и неизвестные ключи сохраняются. Тесты: `test-multiprofile.sh`, `test-settings.sh`, `test-mcp.sh`.
- **Неклоббер чужих артефактов.** Немаркированный (не claudefiles) `wrapper` не перезаписывается; символлинк `.credentials.json` идемпотентен: уже существующий остаётся нетронутым. Тест: `test-profiles.sh`.
- **`Whole-token` матчинг.** Детект плагинов и зависимостей не срабатывает на подстроках. Тесты: `test-deps.sh`, `test-plugins.sh`.
- **Устойчивость statusline.** Не падает и не даёт трейсбек на битых/инъекционных полях; бейдж всегда крайний слева и санитайзится. Тест: `test-statusline.sh`.
- **Не фатально по дизайну.** `deps` и `plugins` не роняют `setup.sh` под `set -e` и продолжают; `deps` дополнительно печатает ручную команду установки. Тесты: `test-deps.sh`, `test-plugins.sh`.
- **Контракт фатальности `gstack_apply`.** Провал `gstack_apply` роняет ровно профиль `g` (`PROVISION_FAILED`), но не `vanilla` и не `super`. Недоступный апстрим при клоне, уже стоящем на записанной в маркер ревизии, провалом не считается: обновление пропускается с `WARN`, профиль зелёный. Тесты: `test-gstack.sh`, `test-profiles.sh`.
- **Инсталлятор gstack неинтерактивен структурно.** Чужой `./setup` получает `< /dev/null`, поэтому новый вопрос в апстриме роняет прогон, а не подвешивает его; набор флагов проверяется целой строкой, не подстроками. Тест: `test-gstack.sh`.
- **Ревизия gstack пинуется.** `CLAUDEFILES_GSTACK_REF` (тег/ветка/SHA) удерживает клон на заданной ревизии вместо апстримного HEAD; неразрешимая ревизия роняет профиль, а не откатывается на HEAD. Тест: `test-gstack.sh`.
- **Профиль `g` проходит сквозной `setup.sh`.** Два прогона против фикстурного апстрима не дают diff в `~/.claude-g`; роли vision-блока закреплены за текстами (producer у `g`, consumer у `super`), а не за общим маркером. Тесты: `test-setup-idempotent.sh`, `test-profiles.sh`, `test-claudemd.sh`.
