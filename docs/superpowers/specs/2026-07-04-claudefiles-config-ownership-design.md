# Design: claudefiles as the single source of truth for Claude config

**Date:** 2026-07-04
**Status:** Draft — awaiting user review
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
3. **settings.json** — render `~/.claude/settings.json` from a template in the repo, filling
   machine-specific values (the SessionStart hook path → the deploy/dev path of *this* run,
   `$HOME`-relative). Preserve unmanaged keys via a merge (python), never blind-overwrite.
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
config and applies it with the same idempotent pattern: sweep known names with
`claude mcp remove --scope user`, then `claude mcp add-json --scope user <name> <json>`.

Servers (enabled per flags in secrets.env):
- `playwright` — `npx @playwright/mcp@latest --executable-path /usr/bin/chromium` (host/container
  detection for the chromium path).
- `context7` — `npx @upstash/context7-mcp` (+ `--api-key` if provided).
- `azure` — `npx @azure/mcp@latest server start` (flag-gated).
- `azureDevOps-<org>` — one per org, `PERSONAL_ACCESS_TOKEN=base64("<email>:<pat>")`.

Host-vs-container detection (currently in `.chezmoi.toml.tmpl` via `stat /run/.containerenv`)
moves into `setup.sh` so container-only differences stay in one place.

### 4.3 Secret & flag handling

- **Store:** `~/.config/claudefiles/secrets.env` — outside the repo, `chmod 600`, never committed.
- **Schema:** feature flags (`SETUP_CONTEXT7`, `SETUP_PLAYWRIGHT`, `SETUP_AZURE_MCP`,
  `SETUP_ADO`, `SETUP_DOTNET_SKILLS`) + secrets (`CONTEXT7_API_KEY`, `ADO_ORGS`, `ADO_EMAIL`,
  `ADO_PAT_<org>`).
- **Prompt-once:** on interactive run, prompt only for missing keys; persist answers.
- **Non-interactive:** `--non-interactive` reads everything from env/existing file; error if a
  required value is absent. Enables CI/containers and the chezmoi trigger to run unattended
  once the file exists.
- **Safety:** repo `.gitignore` already ignores clones/logs; add an explicit guard so no
  `secrets.env` or rendered secret can ever be tracked. A test asserts `git ls-files` contains
  no secret-bearing paths.

### 4.4 chezmoi changes (the thin bootstrap)

**Keep:** `run_onchange_before_02-install-claude` (installs the CLI). Shared prompts unrelated
to Claude config (git name/email, `setup_codex`, container options).

**Add:**
- `.chezmoiexternal.toml` entry: `[".local/share/claudefiles"] type="git-repo"
  url=git@github.com:stpntkhnv/claudefiles.git refreshPeriod="168h" pull.args=["--ff-only"]`.
- `run_onchange_after_setup-claudefiles.sh.tmpl` keyed on claudefiles HEAD (`{{ output "git"
  "-C" (joinPath .chezmoi.homeDir ".local/share/claudefiles") "rev-parse" "HEAD" }}`) that
  runs the deploy copy's `setup.sh`.

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
- (Manual/container) full `chezmoi apply` one-command smoke, appended to the existing
  smoke-results doc.

## 9. Open decisions (confirm during review)

1. **Repo location:** deploy `~/.local/share/claudefiles`, dev `~/dev/claudefiles` — OK, or
   prefer `~/projects/…` / a single shared path?
2. **`setup_azure` split:** keep the Azure-CLI install in chezmoi while the azure MCP-server
   flag moves to claudefiles — acceptable, or move the whole azure concern?
3. **settings.json ownership of `enabledPlugins`:** claudefiles owns the file and lists enabled
   plugins; chezmoi no longer touches it. Confirm.
