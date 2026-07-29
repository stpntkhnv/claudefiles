# Архитектура claudefiles

Тех-диаграммы деплоя: структура модулей, потоки данных, прогон `setup.sh`, разница профилей. Правятся в том же PR, что и код. Лейблы однострочные ради рендера в Linear.

## Компоненты по слоям

Слои по ответственности, стрелки вниз. `common.sh`, утилиты, доступны всем слоям (не рисуем 8 стрелок). Единственное обратное ребро-исключение помечено пунктиром: `_chromium_present`→`config` (deps.sh:58).

```mermaid
flowchart TD
  subgraph orch["Оркестрация"]
    setup["setup.sh"]
    prof["profiles.sh (provision_selected + recipes)"]
    cleanm["clean.sh (ластик чистой установки)"]
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
    gstack["gstack.sh"]
    kb["kb.sh (+ kb_settings.py: записи settings)"]
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
  setup --> cleanm
  setup --> mcp
  prof --> settings & skills & plugins & mcp & claudemd
  prof --> gstack
  prof --> kb
  prof --> cleanm
  settings --> jsonmerge
  kb --> config
  prof --> config
  mcp --> config
  config --> configio
  deps -.->|исключение| config
```

`setup --> mcp` — единственный appliers-модуль, вызываемый оркестратором в обход `prof`: фаза `linear auth` зовёт `mcp_linear_login` напрямую (`setup.sh`, после verify), а не через рецепт профиля. Отсюда же `mcp --> config`: `mcp_linear_login` читает `config_flag` и `_has_tty` (mcp.sh:41,66).

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
  gstack["gstack.sh"] --> gclone[("skills/gstack + .gstack-setup-head")]
  kb["kb.sh"] --> vault[("волт: projects/, global/INDEX.md")]
  kb --> rules[("rules/kb.md + rules/kb-index.md")]
  kb -->|kb_settings.py| setjson
  kb --> kbman[("managed-kb.<profile>.json")]
```

`kb --> setjson` идёт мимо `settings.sh` намеренно: `jsonmerge.py` заменяет управляемый ключ целиком, а под `env` и `permissions` живут записи пользователя, поэтому kb владеет своими записями через манифест, как `mcp.sh` владеет серверами.

## Прогон setup.sh

Один деплой сверху вниз. По фичам deps не фатальны (warn и продолжает). Отсутствие `claude` на preflight тоже только warn, но провижн затем упадёт: `mcp_apply` зовёт `claude` CLI без guard (mcp.sh:23), профиль уходит в fail. Фатально также: нет `git`/`python3` (`require_cmd`), нет обязательного конфига без TTY (config.sh:30); exit 1 при упавших профилях (setup.sh:95-96). После verify и этого exit 1 — отдельная фаза `linear auth` (только при `flags.linear=true`): `mcp_linear_login` за раз на каждый выбранный профиль, в его собственном `CLAUDE_CONFIG_DIR`; она никогда не роняет прогон, только warn.

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
  Note over U: clean (опционально): подтверждение, preflight, бэкап, снос ответов и манифестов
  U->>C: config_ensure_all (опрос флагов и секретов)
  C-->>U: secrets.json
  U->>D: deps_apply (pacman по флагам)
  opt зависимость недоступна
    D-->>U: warn + ручная команда, continue
  end
  U->>P: provision_selected(vanilla, super, g)
  loop каждый профиль (субшелл: TARGET, CONFIG_DIR)
    opt чистая установка
      P->>P: clean_profile (снос конфиг-поверхности, g без bun = отказ)
    end
    P->>R: recipe_vanilla / recipe_super / recipe_g
    R->>M: settings, skills, claudemd, [kb], [plugins], [gstack], mcp
    M-->>R: settings.json, CLAUDE.md, managed-mcp
    Note over R: recipe_g падает, если упал gstack_apply
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
  opt flags.linear == true (и не было exit 1 выше)
    loop каждый выбранный профиль (субшелл: CONFIG_DIR)
      U->>M: mcp_linear_login(profile)
      M-->>U: warn (дрейф манифеста / таймаут проверки / needs-auth без TTY / неопознанный статус) ИЛИ browser-логин (needs-auth + TTY) ИЛИ тихо (Connected) — никогда не роняет прогон
    end
  end
```

## Рецепты: vanilla vs super vs g

Ключевые отличия: vanilla не зовёт `plugins_apply` и self-verify, передаёт `_mcp_legacy` для consume, personal-блок `CLAUDE.md` включён (у super - выключен). g тоже не зовёт `plugins_apply` и self-verify, но вместо них зовёт `gstack_apply` и пишет vision-блок в роли producer; personal-блок у g включён, как у vanilla.

```mermaid
flowchart LR
  subgraph V["recipe_vanilla (~/.claude)"]
    direction TB
    v1["settings_apply (vanilla tmpl, dotnet=f, codex=f)"]
    v2["skills_apply (f, f)"]
    v3["claudemd_apply false"]
    v4["claudemd_personal_apply true"]
    v5["kb_apply vanilla (по флагу)"]
    v6["mcp_apply (+ legacy consume)"]
    v1 --> v2 --> v3 --> v4 --> v5 --> v6
  end
  subgraph S["recipe_super (~/.claude-super)"]
    direction TB
    s1["settings_apply (super tmpl, dotnet, cpe)"]
    s2["skills_apply (dotnet, cr)"]
    s3["claudemd_apply cr"]
    s4["claudemd_personal_apply false"]
    s45["kb_apply super (по флагу)"]
    s5["plugins_apply (dotnet, cpe)"]
    s6["mcp_apply"]
    s7["self-verify superpowers, только если claude на PATH -> fail if missing"]
    s1 --> s2 --> s3 --> s4 --> s45 --> s5 --> s6 --> s7
  end
  subgraph G["recipe_g (~/.claude-g)"]
    direction TB
    g1["settings_apply (g tmpl)"]
    g2["skills_apply (f, f)"]
    g3["claudemd_apply false"]
    g4["claudemd_personal_apply true"]
    g5["claudemd_vision_apply producer"]
    g55["kb_apply g (по флагу)"]
    g6["gstack_apply"]
    g7["mcp_apply"]
    g1 --> g2 --> g3 --> g4 --> g5 --> g55 --> g6 --> g7
  end
```

## Слои коротко

- Оркестрация (`setup.sh`, `profiles.sh`) знает фазы и рецепты; провижн каждого профиля идёт в субшелле с экспортом `CLAUDEFILES_TARGET` и `CLAUDE_CONFIG_DIR` (profiles.sh:92).
- Модули-appliers идемпотентны и владеют своим артефактом; `jsonmerge.py`: только логика мёрджа settings, `config_io.py`: только хранилище секретов.
- Все стора секретов пишутся с `chmod 600` (`config_io.py:42-44`, `mcp.sh:26`).
