# Runtime claudefiles

Что работает в живой сессии `claude`/`claude-super`/`claude-g`. Явно разделено общее и профиль-only: ваниль не такая пустая, как кажется (звук хода есть у всех трёх).

```mermaid
flowchart TD
  subgraph shared["Общее для всех профилей"]
    sl["statusline.sh (бейдж по arg / CLAUDE_CONFIG_DIR)"]
    snd["звук: Stop и Notification -> paplay ready.wav"]
  end
  subgraph vanillaonly["Только vanilla"]
    vmcp["MCP: только context7, безусловно"]
  end
  subgraph superonly["Только super"]
    hook["SessionStart: detect-dotnet.sh (.NET nudge)"]
    plug["плагины: superpowers, dotnet, codex"]
    smcp["MCP по флагам: context7, playwright, azure, ADO"]
  end
  subgraph gonly["Только g"]
    gskills["gstack-скиллы (23 роли, ~50 файлов)"]
    gmcp["MCP: только context7, безусловно"]
    gnohook["без SessionStart-хука"]
  end
  van["claude -> vanilla"] --> shared
  van --> vanillaonly
  sup["claude-super -> super"] --> shared
  sup --> superonly
  g["claude-g -> g"] --> shared
  g --> gonly
```

- **statusline** (statusline.sh): бейдж профиля из аргумента настроек или из `CLAUDE_CONFIG_DIR`; cyan=vanilla, magenta=super, green=g, yellow=прочее.
- **звук** (все три шаблона, `paplay` на Stop и Notification; vanilla:11 / super:25 / g:13): `ready.wav`.
- **SessionStart** (только super): `detect-dotnet.sh` ищет .NET в дереве и подсказывает `dotnet-router`; у g этого хука нет.
- **MCP**: vanilla и g всегда только context7 (build_servers.py:23-28); super: флаг-гейтед набор, куда context7 входит тоже по флагу (build_servers.py:29-46).
