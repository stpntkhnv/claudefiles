# Runtime claudefiles

Что работает в живой сессии `claude`/`claude-super`. Явно разделено общее и super-only: ваниль не такая пустая, как кажется (звук хода есть у обоих).

```mermaid
flowchart TD
  subgraph shared["Общее для обоих профилей"]
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
  van["claude -> vanilla"] --> shared
  van --> vanillaonly
  sup["claude-super -> super"] --> shared
  sup --> superonly
```

- **statusline** (statusline.sh): бейдж профиля из аргумента настроек или из `CLAUDE_CONFIG_DIR`; cyan=vanilla, magenta=super, yellow=прочее.
- **звук** (оба шаблона, `paplay` на Stop и Notification; vanilla:11 / super:25): `ready.wav`.
- **SessionStart** (только super): `detect-dotnet.sh` ищет .NET в дереве и подсказывает `dotnet-router`.
- **MCP**: vanilla всегда только context7 (build_servers.py:23-28); super: флаг-гейтед набор, куда context7 входит тоже по флагу (build_servers.py:29-46).
