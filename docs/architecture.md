# Архитектура claudefiles

Тех-диаграммы деплоя: структура модулей, потоки данных, прогон `setup.sh`, разница профилей. Правятся в том же PR, что и код. Лейблы однострочные ради рендера в Linear.

## Компоненты по слоям

Слои по ответственности, стрелки вниз. `common.sh`, утилиты, доступны всем слоям (не рисуем 8 стрелок). Единственное обратное ребро-исключение помечено пунктиром: `_chromium_present`→`config` (deps.sh:58).

```mermaid
flowchart TD
  subgraph orch["Оркестрация"]
    setup["setup.sh"]
    prof["profiles.sh (provision_selected + recipes)"]
  end
  subgraph sysdeps["Системные deps"]
    deps["deps.sh"]
  end
  subgraph appliers["Модули-appliers"]
    settings["settings.sh"]
    jsonmerge["jsonmerge.py (мёрдж settings)"]
    skills["skills.sh"]
    plugins["plugins.sh"]
    mcp["mcp.sh"]
    claudemd["claudemd.sh"]
  end
  subgraph cfg["Хранилище конфига"]
    config["config.sh"]
    configio["config_io.py (secrets.json)"]
  end
  subgraph util["Утилиты (доступны всем слоям)"]
    common["common.sh: log / warn / die / require_cmd"]
  end

  setup --> prof
  setup --> deps
  setup --> config
  prof --> settings & skills & plugins & mcp & claudemd
  settings --> jsonmerge
  prof --> config
  config --> configio
  deps -.->|исключение| config
```

## Потоки данных

Что откуда читается и куда пишется при деплое. Цилиндры - персистентные стора.

```mermaid
flowchart LR
  tmpl["settings/*.template.json"] --> settings["settings.sh"] --> setjson[("settings.json")]
  secrets[("secrets.json")] -->|build_servers.py| mcp["mcp.sh"] --> mcpman[("managed-mcp.*.json")]
  claudemd["claudemd.sh"] --> cmd[("CLAUDE.md")]
  skills["skills.sh"] --> skdir[("skills/*")]
  prof["profiles.sh"] --> wrap["~/.local/bin/claude-<name>"]
  prof --> creds[(".credentials.json симлинк")]
```
