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

## Прогон setup.sh

Один деплой сверху вниз. По фичам не фатально (deps, отсутствие `claude`). Фатально: нет `git`/`python3` на preflight (`require_cmd`), нет обязательного конфига без TTY (config.sh:30), exit 1 при упавших профилях (setup.sh:79).

```mermaid
sequenceDiagram
  autonumber
  participant U as setup.sh
  participant C as config
  participant D as deps
  participant P as provision_selected
  participant R as recipe_*
  participant M as модули *_apply
  Note over U: preflight: git/python3 обязательны (die), нет claude = warn
  U->>C: config_ensure_all (опрос флагов и секретов)
  C-->>U: secrets.json
  U->>D: deps_apply (pacman по флагам)
  opt зависимость недоступна
    D-->>U: warn + ручная команда, continue
  end
  U->>P: provision_selected(vanilla, super)
  loop каждый профиль (субшелл: TARGET, CONFIG_DIR)
    P->>R: recipe_vanilla / recipe_super
    R->>M: settings, skills, claudemd, [plugins], mcp
    M-->>R: settings.json, CLAUDE.md, managed-mcp
    alt рецепт упал
      R-->>P: fail -> PROVISION_FAILED += профиль
    else успех
      R-->>P: ok (+ creds симлинк, wrapper)
    end
  end
  U->>U: verify (json.tool каждого settings.json)
  opt есть упавшие профили
    U-->>U: warn список + exit 1
  end
```

## Рецепты: vanilla vs super

Ключевые отличия: vanilla не зовёт `plugins_apply` и self-verify, передаёт `_mcp_legacy` для consume, personal-блок `CLAUDE.md` включён (у super - выключен).

```mermaid
flowchart LR
  subgraph V["recipe_vanilla (~/.claude)"]
    direction TB
    v1["settings_apply (vanilla tmpl, dotnet=f, codex=f)"]
    v2["skills_apply (f, f)"]
    v3["claudemd_apply false"]
    v4["claudemd_personal_apply true"]
    v6["mcp_apply (+ legacy consume)"]
    v1 --> v2 --> v3 --> v4 --> v6
  end
  subgraph S["recipe_super (~/.claude-super)"]
    direction TB
    s1["settings_apply (super tmpl, dotnet, cpe)"]
    s2["skills_apply (dotnet, cr)"]
    s3["claudemd_apply cr"]
    s4["claudemd_personal_apply false"]
    s5["plugins_apply (dotnet, cpe)"]
    s6["mcp_apply"]
    s7["self-verify superpowers, только если claude на PATH -> fail if missing"]
    s1 --> s2 --> s3 --> s4 --> s5 --> s6 --> s7
  end
```

## Слои коротко

- Оркестрация (`setup.sh`, `profiles.sh`) знает фазы и рецепты; провижн каждого профиля идёт в субшелле с экспортом `CLAUDEFILES_TARGET` и `CLAUDE_CONFIG_DIR` (profiles.sh:73).
- Модули-appliers идемпотентны и владеют своим артефактом; `jsonmerge.py`: только логика мёрджа settings, `config_io.py`: только хранилище секретов.
- Все стора секретов пишутся с `chmod 600` (`config_io.py:42-44`, `mcp.sh:26`).
