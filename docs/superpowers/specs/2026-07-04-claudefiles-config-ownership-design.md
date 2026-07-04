# Design: claudefiles as the single source of truth for Claude config

**Date:** 2026-07-04
**Status:** Rev. 3 — all §9 decisions resolved (public+https, two-copy layout, TTY prompting).
Codex findings 2–7 incorporated; finding 1's premise disputed (git-repo externals support SSH)
and resolved as public+https. Ready for implementation planning.
**Topic:** Consolidate all `~/.claude` configuration into the standalone `claudefiles`
repo; shrink chezmoi to a thin bootstrap (install `claude` + pull & trigger claudefiles);
move secret collection into claudefiles.

---

## 1. Problem

Claude Code configuration is currently scattered across three owners, which the user
wants to eliminate:

| Owner | What it manages today |
|---|---|
| **chezmoi** (`stpntkhnv/dotfiles`) | Installs the `claude` CLI; installs the `dotnet` plugin; syncs user-scope MCP servers (azure, azureDevOps-`<org>`, context7, playwright); ships the `brainstorming` skill; prompts for & stores all secrets/flags in `~/.config/chezmoi/chezmoi.toml` |
| **claudefiles** (`stpntkhnv/claudefiles`, checked out at `~/devTools`) | `dotnet-router` skill + catalog, SessionStart hook, `setup.sh` |
| **Unmanaged** | `~/.claude/settings.json` (model/effort/theme/enabledPlugins/hooks), the `context7-mcp` skill, `~/.claude/rules/` |

Additional problems with the current state:

- The local checkout folder is named `devTools` — a misleading name the user dislikes;
  the repo is actually `claudefiles`.
- `settings.json` hardcodes an absolute hook path (`/home/stsiapan/devTools/...`) — not
  portable across machines or repo locations.
- The `dotnet-router` catalog is generated with machine-absolute paths (correct by design,
  but means a committed "ready `.claude` folder" cannot be static — it must be generated).

## 2. Goal

One repository — `claudefiles` — owns the entire `~/.claude` configuration and installs it
with **one command**, standalone. chezmoi becomes a thin bootstrap that (a) installs the
`claude` CLI and (b) pulls claudefiles and runs its installer on `chezmoi apply`.

Two workflows must both work:

- **Fresh machine (one command):** `chezmoi apply` → installs `claude` → pulls claudefiles →
  runs `setup.sh` → full config in place.
- **Development (no chezmoi in the loop):** edit the claudefiles repo directly like any
  project → `./setup.sh` to apply locally → `git push`.

**Non-goals (YAGNI):**
- Secret *encryption*. chezmoi stores these secrets as plaintext today (prompt-once, no
  age/1Password). claudefiles matches that bar: prompt-once, plaintext, outside git, `chmod 600`.
  Encryption can be added later without changing this design.
- Codex MCP configuration. The chezmoi MCP template notes future Codex reuse; Codex does not
  consume it yet. Out of scope; revisit if/when Codex needs MCP.

## 3. Target architecture

Two tiers with a clean, secret-free boundary.

| Tier | Owns | Entry point |
|---|---|---|
| **chezmoi** (dotfiles) | Install `claude` CLI. `.chezmoiexternal` pull of claudefiles. One `run_onchange_after` trigger that runs `claudefiles/setup.sh`, keyed on claudefiles' HEAD commit so it re-runs only when claudefiles changes. | `chezmoi apply` |
| **claudefiles** (standalone repo) | Everything in `~/.claude`: `settings.json`, personal skills, hooks, agents, `dotnet-router` + catalog, **plugin install**, **MCP wiring**, **its own secret prompting/storage**. | `./setup.sh` |

The only thing that cannot live in a git repo is secret *values*. Because chezmoi does not
encrypt them anyway (just prompt-once), claudefiles prompts for and stores them itself —
losing nothing in security while removing chezmoi from the config-content domain entirely.

### Deployment vs development checkout

- chezmoi's `.chezmoiexternal` clones claudefiles into a **deploy copy** at
  `~/.local/share/claudefiles` (`git-repo` type, `refreshPeriod`, `pull.args=["--ff-only"]`).
  The trigger runs `setup.sh` from there.
- The **development checkout** lives separately (proposed `~/dev/claudefiles`) so chezmoi's
  `--ff-only` pulls never fight the developer's dirty/ahead working tree. During dev you run
  `./setup.sh` from the dev checkout; `chezmoi apply` runs the pushed version from the deploy
  copy. Both write to the same `~/.claude` — last run wins, which is fine because they
  converge to the same committed state once pushed.
- Rename the current `~/devTools` checkout to `~/dev/claudefiles` (or the user's chosen path).

## 4. Components

### 4.1 `setup.sh` — the complete idempotent installer

Extends today's script (which only wires `dotnet-router` + hook) to own the whole config.
Idempotent; safe to re-run; the update path after `git pull`. Ordered phases:

1. **Preflight** — require `claude` on PATH (installed by chezmoi or manually); require
   git/bash/coreutils/awk/python3. Warn (don't fail) on missing optional deps (`dotnet` SDK).
2. **Load config** — read `~/.config/claudefiles/secrets.env` if present; otherwise prompt
   (§4.3). Honor a `--non-interactive` flag that requires all values to come from env/file.
3. **settings.json** — render `~/.claude/settings.json` from a repo template. **Managed keys
   are replaced wholesale; unknown top-level keys are preserved.** Managed set fully owned by
   claudefiles: `hooks`, `enabledPlugins`, `extraKnownMarketplaces`, `model`, `effortLevel`,
   `tui`, `theme` — replacing (not merging) `hooks` is what prevents a stale hardcoded hook
   path from surviving migration. Any other top-level key in an existing file is carried over
   untouched. The SessionStart hook path is filled from *this* run's repo location,
   `$HOME`-relative. The separate `settings.local.json` (machine permissions,
   `enabledMcpjsonServers`) is **not** touched — it stays local.
4. **Skills** — install personal skills into `~/.claude/skills/`: `context7-mcp` (real dir),
   `dotnet-router` (symlink to the repo's `claude/skills/dotnet-router`). Regenerate the
   dotnet catalog with absolute paths for this machine (existing `gen-dotnet-catalog.sh`).
5. **Hooks** — the SessionStart `detect-dotnet.sh` lives in the repo; settings.json points
   at its absolute path from step 3.
6. **Plugins** — port `configure-claude-plugins` logic: `claude plugin marketplace add
   dotnet/skills` + `claude plugin install dotnet@dotnet-agent-skills`, guarded by
   idempotent `list | grep` checks (as today).
7. **MCP** — port the `mcp-servers` definition + sync logic (§4.2).
8. **Verify** — run the repo's test suite + `claude` config validation; assert skills/catalog
   reachable and `settings.json` is valid JSON.

### 4.2 MCP wiring (ported from chezmoi)

Move `.chezmoitemplates/mcp-servers` + `run_onchange_after_configure-claude-mcp` into
claudefiles as a script (no chezmoi templating). It builds the server set from the loaded
config, then reconciles against a **manifest of previously-managed names** at
`~/.config/claudefiles/managed-mcp.json`: `claude mcp remove --scope user` exactly the names
in the manifest (never a name-prefix sweep — that could delete a user's own server), then
`claude mcp add-json --scope user <name> <json>` the current set, then rewrite the manifest.
A dropped `azureDevOps-<org>` disappears cleanly; unmanaged servers are never touched. (The
current chezmoi script's comment admits the prefix approach leaks renamed ADO orgs — this
fixes that.)

Servers (enabled per flags in secrets.env):
- `playwright` — `npx @playwright/mcp@latest --executable-path /usr/bin/chromium` (host/container
  detection for the chromium path).
- `context7` — `npx @upstash/context7-mcp` (+ `--api-key` if provided).
- `azure` — `npx @azure/mcp@latest server start` (flag-gated).
- `azureDevOps-<org>` — one per org, `PERSONAL_ACCESS_TOKEN=base64("<email>:<pat>")`.

Host-vs-container detection (currently in `.chezmoi.toml.tmpl` via `stat /run/.containerenv`)
moves into `setup.sh` so container-only differences stay in one place.

### 4.3 Secret & flag handling

- **Store:** `~/.config/claudefiles/secrets.json` — JSON, outside the repo, `chmod 600`, never
  committed. **JSON, not a shell `.env`:** it is *parsed* (python, already a dependency), never
  `source`d, so it is data not executable code, and per-org PATs live in a nested map keyed by
  the raw org string — sidestepping that env-var names cannot contain `-` / `.` / case
  collisions.
- **Schema:** `{ flags: { context7, playwright, azure_mcp, ado, dotnet_skills },
  context7_api_key, ado: { email, orgs: [...], pat: { "<org>": "<token>" } } }`.
- **Invocation mode (resolves the first-run ambiguity):** `setup.sh` picks mode by TTY. With a
  TTY and missing required values → prompt once and persist. Without a TTY (CI, container,
  unattended `chezmoi apply`) → strictly non-interactive: use the existing file, and **fail
  fast** with a message listing missing keys — never hang on a prompt. chezmoi's `run_after_`
  inherits the terminal of `chezmoi apply`, so an interactive apply prompts and an unattended
  one errors rather than blocking.
- **Safety:** `.gitignore` guards the store; a test asserts `git ls-files` exposes no
  secret-bearing path.

### 4.4 chezmoi changes (the thin bootstrap)

**Keep:** `run_onchange_before_02-install-claude` (installs the CLI). Shared prompts unrelated
to Claude config (git name/email, `setup_codex`, container options).

**Add:**
- `.chezmoiexternal.toml` entry, `type = "git-repo"`,
  `url = "https://github.com/stpntkhnv/claudefiles.git"` (**public repo — decided §9.4**;
  keyless clone, simplest fresh-machine path; the design commits no secrets, §4.3),
  `refreshPeriod = "168h"`, `pull.args = ["--ff-only"]`, cloned to the deploy copy
  `~/.local/share/claudefiles` (**two-copy layout — decided §9.1**).
- A **plain `run_after_setup-claudefiles.sh.tmpl`** (not `run_onchange_`): at execution time —
  externals are already updated by then (chezmoi Application Order: "`run_after_` scripts can
  safely depend on externals") — it reads the deploy copy's current `git rev-parse HEAD`,
  compares against `~/.config/claudefiles/last-applied-head`, and runs `setup.sh` only when
  they differ (writing the new HEAD on success). This avoids the onchange-hash template being
  rendered before the external exists (first-apply failure) or reading a stale HEAD;
  `setup.sh` idempotency is the backstop.

**Remove (moved to claudefiles):** `run_onchange_after_configure-claude-plugins.sh.tmpl`,
`run_onchange_after_configure-claude-mcp.sh.tmpl`, `.chezmoitemplates/mcp-servers`,
`dot_claude/skills/brainstorming`, and the Claude-config prompts in `.chezmoi.toml.tmpl`
(`setup_playwright`, `setup_context7`, `context7_api_key`, `setup_dotnet_skills`, `setup_ado`,
`ado_orgs`, `ado_email`, `ado_pat_*`). `setup_claude` stays (gates installing the binary).
`setup_azure` stays if it also installs the Azure CLI (system tool); the azure *MCP server*
flag moves to claudefiles.

## 5. Data flow

**Fresh machine:** `chezmoi apply` → prompt shared data → install `claude` (before) → write
files → `.chezmoiexternal` clones claudefiles to `~/.local/share/claudefiles` → HEAD-keyed
trigger runs `setup.sh` → setup prompts for Claude secrets (first run) → installs plugins,
wires MCP, lays down settings/skills/hooks → verify.

**Development:** edit `~/dev/claudefiles` → `./setup.sh` (reads existing secrets.env, no
re-prompt) → validate → `git commit && git push`. Next `chezmoi apply` on any machine pulls
and applies the pushed state.

## 6. Migration (this machine, no breakage)

1. Rename `~/devTools` → `~/dev/claudefiles` (or chosen path); fix stale "claudefiles"/`ado-mcp`
   references in README + `dotnet-router` SKILL.md Maintenance section.
2. Seed `~/.config/claudefiles/secrets.env` from the values already in
   `~/.config/chezmoi/chezmoi.toml` (context7 key, ado_* if set) so nothing is lost.
3. Grow `setup.sh` to own settings.json / plugins / MCP (§4); keep it green at each step.
4. Update chezmoi: add external + trigger, remove the moved scripts/templates/prompts.
5. `chezmoi apply` on a scratch/container to prove the one-command path end to end.
6. Only then delete the old duplicated chezmoi pieces.

## 7. Portability & safety

- No hardcoded `/home/stsiapan`. Use `$HOME`; derive the hook path from the run's repo
  location; generate the catalog per machine.
- settings.json is rendered/merged, not copied verbatim, so the hook path is correct wherever
  claudefiles lives.
- Secrets never enter git. `chmod 600` on the store. A test enforces this.

## 8. Testing

Extend the existing `skills/tools/` tests:
- `setup.sh` idempotency (run twice → no diff, exit 0).
- Non-interactive install from a seeded `secrets.env`.
- MCP sync produces the expected `claude mcp` calls (dry-run/mock `claude_bin`).
- Plugin install guards are idempotent.
- settings.json render is valid JSON and the hook path resolves.
- No secret-bearing path is tracked by git.
- **`run_after` HEAD-compare** (review finding 2): simulate an external update (HEAD changes) →
  `setup.sh` runs on the *same* apply; unchanged HEAD → no-op. Guards against next-apply-lag and
  first-apply failure.
- **MCP manifest migration** (review finding 5): an `azureDevOps-<org>` present last run but
  dropped from config is removed via the manifest, while an unmanaged user server is left intact.
- (Manual/container) full `chezmoi apply` one-command smoke, appended to the existing
  smoke-results doc.

## 9. Decisions (resolved 2026-07-04)

1. **Repo layout — two copies.** chezmoi pulls the deploy copy to `~/.local/share/claudefiles`;
   development happens in a separate `~/dev/claudefiles` checkout. Folder named `claudefiles`
   (the `devTools` name is retired).
2. **`setup_azure` split.** Azure CLI install stays in chezmoi (system tool); the azure
   MCP-server flag moves to claudefiles.
3. **settings.json ownership.** claudefiles owns the file incl. `enabledPlugins`; chezmoi no
   longer touches it (`settings.local.json` stays machine-local).
4. **Repo visibility — public + https.** Clone over
   `https://github.com/stpntkhnv/claudefiles.git`, keyless. Hard requirement this imposes: a
   test MUST guarantee no secret ever lands in a tracked file (§4.3 safety) — the repo is
   world-readable.
5. **Interactivity — TTY-based.** Prompt when a TTY is present and values are missing; fail
   fast (never hang) when unattended.
