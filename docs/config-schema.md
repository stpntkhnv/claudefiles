# Схема secrets.json

`~/.config/claudefiles/secrets.json`: единственный persist пользовательских ответов. Владеет им `config_io.py` (пишет с `chmod 600` на создании и на каждой записи, config_io.py:42-44).

## Ключи

- `flags.<name>`: булевы (JSON-bool): `profile_super`, `dotnet_skills`, `codex_review`, `codex_plugin`, `playwright`, `azure_mcp`, `ado`, `context7`.
- `ado.email`, `ado.orgs` (массив), `ado.pat.<org>` (секрет per-org).
- `context7_api_key` (секрет, пусто = free tier).
- `playwright.chromium_path` (override пути к chromium).

## Семантика записи

- **Prompt-once для флагов** (config.sh:48): раз спросили, больше не переспрашиваем.
- **Optional пишет пусто** (config.sh:42): пустой ответ сохраняется, `config_has` в следующий прогон вернёт true, повтора нет.
- **present-empty vs absent**: ключ с пустым значением != отсутствующий ключ; на этом стоит prompt-once.
- **Булевы** эмитятся lowercase (`true`/`false`), чтобы shell-сравнение работало.
- **Легаси-строка `"true"`** терпится наравне с JSON-bool в MCP-конфиге (build_servers.py:8-10).

Обоснование: config.sh, config_io.py, build_servers.py.
