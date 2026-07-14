# Инварианты claudefiles

Гарантии, которые держит тест-сьют (`skills/tools/`). Каждая строка: гарантия и тест-источник.

- **Идемпотентность / zero-diff на повторный прогон.** Второй `setup.sh` не меняет ни settings, ни CLAUDE.md, ни MCP-манифест, ни плагины. Тесты: `test-setup-idempotent.sh`, `test-multiprofile.sh`, покомпонентно `test-mcp.sh`, `test-plugins.sh`, `test-claudemd.sh`.
- **Секреты с `chmod 600`.** `secrets.json` и `managed-mcp.*.json` создаются и переписываются в 600. Тесты: `test-config.sh`, `test-mcp.sh`.
- **Секреты не в git.** `secrets.json`, `managed-mcp.json`, `last-applied-head`, `.env` не трекаются. Тест: `test-secrets-not-tracked.sh`.
- **Изоляция профилей.** Рецепты в субшелле без утечки env в вызывающего; отдельный target-каталог; отдельные MCP-манифесты. Тесты: `test-profiles.sh`, `test-settings.sh`, `test-skills.sh`.
- **Миграция super→vanilla полная и одноразовая.** Плагины/хуки/model/effort/router/super-MCP снимаются с дефолтного каталога, пользовательский контент и неизвестные ключи сохраняются. Тесты: `test-multiprofile.sh`, `test-settings.sh`.
- **Неклоббер чужих артефактов.** Немаркированные wrapper и `.credentials.json` не трогаются. Тест: `test-profiles.sh`.
- **Whole-token матчинг.** Детект плагинов и зависимостей не срабатывает на подстроках. Тесты: `test-deps.sh`, `test-plugins.sh`.
- **Робастность statusline.** Не падает и не даёт трейсбек на битых/инъекционных полях; бейдж всегда крайний слева и санитайзится. Тест: `test-statusline.sh`.
- **Не фатально по дизайну.** deps и plugins не роняют `setup.sh` под `set -e`, печатают ручную команду и продолжают. Тесты: `test-deps.sh`, `test-plugins.sh`.
