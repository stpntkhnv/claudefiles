# Схема secrets.json

`~/.config/claudefiles/secrets.json`: единственный `persist` пользовательских ответов. Владеет им `config_io.py` (пишет с `chmod 600` на создании и на каждой записи, `config_io.py:42-44`).

## Ключи

- `flags.<name>`: булевы (JSON-bool): `profile_super`, `profile_gstack`, `dotnet_skills`, `codex_review`, `codex_plugin`, `playwright`, `azure_mcp`, `ado`, `context7`, `linear`, `kb`.
- `ado.email`, `ado.orgs` (массив), `ado.pat.<org>` (секрет per-org).
- `context7_api_key` (секрет, пусто = free tier).
- `playwright.chromium_path` (override пути к chromium).
- `kb.vault_path` (optional, пусто = `~/Documents/Notes/kb`): каталог волта базы знаний. Абсолютный путь или `~/`; относительный и любой путь с `..` отвергаются в `kb_vault_path` (`lib/kb.sh`) до провижна, в фазе config. Внутри контейнера (`/run/.containerenv`/`/.dockerenv`) пустое значение тоже отвергается: `$HOME` там — дом контейнера, и умолчание завело бы одноразовый волт, умирающий вместе с ним; путь к хостовому волту обязателен.
- `linear` секретов не требует: сервер удалённый (`https://mcp.linear.app/mcp`), авторизация через OAuth, токен хранит Claude Code, а не claudefiles.

## Манифест managed-kb.&lt;profile&gt;.json

Рядом с `secrets.json`, `chmod 600`, владеет им `lib/py/kb_settings.py`. Не конфиг, а запись о том, что claudefiles положил в `settings.json` профиля:

- `env`: имена ключей в `env`, которые мы поставили (сейчас всегда `CLAUDE_CODE_REMOTE_MEMORY_DIR`).
- `env_prev`: значение, которое было у ключа до нас; при выключении оно возвращается на место, а не удаляется.
- `permissions_allow`: строки, которые мы добавили в `permissions.allow`. Правило, которое пользователь написал сам, сюда не попадает и потому при выключении не снимается.

Смысл манифеста тот же, что у `managed-mcp.<profile>.json`: снять ровно своё. `jsonmerge.py` для этих двух ключей не годится — он заменяет управляемый ключ целиком (`lib/py/jsonmerge.py:41-47`), а под `env` и `permissions` живут записи пользователя.

## Семантика записи

- **Prompt-once для флагов** (config.sh:48): раз спросили, больше не переспрашиваем.
- **Optional пишет пусто** (config.sh:42): пустой ответ сохраняется, `config_has` в следующий прогон вернёт true, повтора нет.
- **present-empty vs absent**: ключ с пустым значением != отсутствующий ключ; на этом стоит prompt-once.
- **Булевы** эмитятся lowercase (`true`/`false`), чтобы shell-сравнение работало.
- **Легаси-строка `"true"`** терпится наравне с JSON-bool в MCP-конфиге (build_servers.py:8-10).

Обоснование: `config.sh`, `config_io.py`, `build_servers.py`.
