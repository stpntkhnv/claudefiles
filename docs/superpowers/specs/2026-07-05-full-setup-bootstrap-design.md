# Design: full setup from zero to a ready env (deps + superpowers)

**Date:** 2026-07-05
**Status:** Rev. 1 — approved in brainstorming. Ready for implementation planning.
**Topic:** Extend `setup.sh` so a fresh Arch machine reaches a *ready* Claude Code env in one
run: check and (offer to) install the system dependencies the enabled features need, and
install **both** plugins — `superpowers` (always) and `dotnet` (by flag) — instead of only
`dotnet`.

---

## 1. Problem

Today `./setup.sh` stops short of a working environment on a fresh machine:

- **superpowers is never installed.** `settings.template.json` lists it in `enabledPlugins`,
  but `plugins_apply` only handles the `dotnet` plugin, and the whole plugins phase is gated
  behind `dotnet_skills=true`. superpowers must be installed manually inside Claude Code.
- **System dependencies are unchecked.** All MCP servers are `npx`-based, yet `node`/`npx` is
  never verified — enabled servers get registered but silently fail to launch without node.
  `chromium` (Playwright) only has a path resolver, no install. `dotnet` SDK is a bare `warn`.

The result: after `setup.sh` a user still needs several manual steps. The goal is a genuine
"zero → ready env" in one command.

## 2. Goal

One `./setup.sh` run leaves the machine ready: every enabled feature has its system dependency
present (or the user was offered to install it), and both plugins are installed. No manual
post-steps for the happy path.

**Scope (decided in brainstorming):**
- **Arch only.** The dependency installer targets `pacman`. Non-Arch → print the manual
  command, never fail.
- **Managed deps:** `node`/`npx`, `chromium`, `.NET SDK` — all via `pacman`, each gated by the
  flag that needs it.
- **Install policy:** ask `y/N` per missing package, then `sudo pacman -S`. Consent is the
  `y/N`; `--noconfirm` avoids a redundant second prompt.
- **superpowers:** installed from the script, always. **dotnet plugin:** by `dotnet_skills`.

**Non-goals (YAGNI):**
- Installing the `claude` CLI itself — stays a `warn` (that is chezmoi's job, per the existing
  design; installing it here would duplicate that boundary).
- Cross-distro / macOS package managers (`apt`, `dnf`, `brew`). Arch-only by decision.
- A separate `doctor`/`bootstrap` command — the checks live in the one `setup.sh` run.

## 3. Decisions (resolved 2026-07-05)

1. **Platform — Arch/pacman only.** Missing `pacman` (not Arch) → warn + print the manual
   install command; never abort.
2. **Managed deps — node/npx, chromium, dotnet-sdk.** `claude` CLI excluded (stays `warn`).
3. **Install policy — ask then sudo.** Per missing package: `y/N`; on `y` run
   `sudo pacman -S --needed --noconfirm <pkg>`. On `n` / no-TTY / no-pacman: warn + manual
   command, continue.
4. **.NET SDK via pacman** (`dotnet-sdk`), gated by `dotnet_skills`. (Local `setup-local-sdk`
   path considered and rejected for automation simplicity.)
5. **superpowers always, dotnet by flag.** Marketplace `claude-plugins-official`
   (`anthropics/claude-plugins-official`) is added if missing; both confirmed present on the
   reference machine.

## 4. Target architecture — 8 phases

A new **deps** phase is inserted after `config` (it needs the resolved flags) and before
`settings`. The plugins phase stops being gated as a whole; the flag is checked inside it.

```
1 preflight     git, python3 (require); claude (warn)          — unchanged
2 config        flags + secrets, prompt-once                   — unchanged
3 deps          flag-aware check + offer-install (pacman)      — NEW  (lib/deps.sh)
4 settings.json managed keys merge                             — unchanged
5 skills        context7-mcp + dotnet-router                   — unchanged
6 plugins       superpowers ALWAYS; dotnet by flag             — MODIFIED (lib/plugins.sh)
7 mcp           reconcile user-scope servers                   — unchanged
8 verify        settings valid + catalog self-test + readiness — extended
```

All phase logs renumber to `/8`.

## 5. Components

### 5.1 `lib/deps.sh` — new module

One generic helper + a flag-aware layout. Reuses `_has_tty` / `warn` from the already-sourced
`config.sh` / `common.sh`.

```bash
dep_require() {   # dep_require <check-cmd> <pacman-pkg> <why>
  command -v "$1" >/dev/null 2>&1 && return 0            # present → silent
  warn "missing '$1' — needed for: $3"
  if ! command -v pacman >/dev/null 2>&1; then
    warn "pacman not found (not Arch?) — install manually: $2"; return 0
  fi
  if _has_tty; then
    read -r -p "Install '$2' via sudo pacman? (y/N) " a || true
    case "${a,,}" in
      y|yes) sudo pacman -S --needed --noconfirm $2 || warn "install of $2 failed" ;;
      *)     warn "skipped $2 — $3 won't work until installed" ;;
    esac
  else
    warn "no TTY — install manually: sudo pacman -S --needed $2"   # never sudo without a TTY
  fi
}

deps_apply() {   # deps_apply <ctx7> <playwright> <azure> <ado> <dotnet>
  case true in "$1"|"$2"|"$3"|"$4") dep_require npx "nodejs npm" "MCP servers (npx-based)";; esac
  [ "$2" = true ] && dep_require chromium chromium  "Playwright MCP browser"
  [ "$5" = true ] && dep_require dotnet   dotnet-sdk "C# language server / dotnet plugin"
}
```

Behavior contract:
- Package already present → zero actions (idempotent; the gate is command presence, so
  `pacman` is called only when genuinely missing).
- Missing + TTY → `y/N`; on `y`, `sudo pacman -S --needed --noconfirm` (the `y/N` is the single
  consent point; sudo prompts for a password as usual).
- Missing + no TTY → print the manual command, do **not** invoke sudo.
- Missing + no pacman → print the manual package, continue.
- No path aborts the run (`set -e` never trips — every branch ends in `|| warn` / `return 0`).
- Flag gating: `chromium` only with Playwright, `dotnet-sdk` only with `dotnet_skills`, `node`
  only if at least one MCP server is enabled.

`setup.sh` wires it as:
`log "3/8 deps"; deps_apply "$(config_flag context7)" "$(config_flag playwright)" "$(config_flag azure_mcp)" "$(config_flag ado)" "$(config_flag dotnet_skills)"`

### 5.2 `lib/plugins.sh` — superpowers always, dotnet by flag

```bash
plugins_apply() {   # plugins_apply <dotnet_enabled>
  local dotnet="${1:-false}" cb; cb="$(claude_bin)"
  _ensure_marketplace "claude-plugins-official" "anthropics/claude-plugins-official"
  _ensure_plugin      "superpowers@claude-plugins-official"          # ALWAYS
  if [ "$dotnet" = true ]; then
    command -v dotnet >/dev/null 2>&1 || warn "dotnet SDK not found; C# LSP will not start"
    _ensure_marketplace "dotnet-agent-skills" "dotnet/skills"
    _ensure_plugin      "dotnet@dotnet-agent-skills"
  fi
}
```

`_ensure_marketplace` / `_ensure_plugin` are idempotent guards factored out of today's inline
logic: `grep` the `marketplace list` / `plugin list` output and add/install only when absent.
The marketplace match tolerates both the name and the `owner/repo` source form (as the current
dotnet check does). `setup.sh` keeps the failure wrapper so a plugin error never aborts the
rest of the config:
`log "6/8 plugins"; plugins_apply "$(config_flag dotnet_skills)" || warn "plugin install failed (rest of config still applied)"`

`settings.template.json` is unchanged — superpowers is already `true` there, now consistent
with always installing it.

### 5.3 verify (phase 8) — readiness summary

After the existing `settings.json` validation + catalog self-test, print a short,
**non-fatal** readiness report so "is the env ready?" is visible at the end. One line per
enabled feature: `OK` or `MISSING → <command to fix>` — node (if any MCP), chromium (if
Playwright), dotnet (if dotnet_skills), plus the installed/enabled state of both plugins.

## 6. Data flow

`setup.sh` → config resolves flags → **deps** reads those flags and ensures each needed package
(offer-install) → settings/skills applied → **plugins** installs superpowers (+dotnet by flag)
→ mcp registers servers (now backed by a present `node`) → verify validates and prints
readiness. Re-run: all deps present + plugins installed → every phase is a no-op, no diff,
exit 0.

## 7. Error handling

- `dep_require`: missing pacman/sudo or a declined prompt → `warn` + continue, never `die`.
- pacman install non-zero → `warn`, continue (a failed optional dep must not abort config).
- `plugins_apply` wrapped in `|| warn` in `setup.sh`; a superpowers/dotnet failure is non-fatal.
- `--non-interactive` (`CLAUDEFILES_ASSUME_TTY=0`): deps phase installs nothing — prints manual
  commands and continues (graceful degradation: MCP won't launch, but the config still applies).
  The config phase keeps its existing fail-fast on missing required secrets.

## 8. Testing

Following the repo pattern (fake binaries on a temp `PATH`, fixture `$HOME`):

- **`test-deps.sh` (new):** fake `pacman` + `sudo` log their invocations. Assert — command
  present → `pacman` not called; missing + `ASSUME_TTY=0` → `sudo` not called and the manual
  command is printed; missing + piped `y` → `pacman -S --needed --noconfirm <pkg>`; `playwright=false`
  → `chromium` not required even when absent; no `pacman` on PATH → warn + manual, no abort.
- **`test-plugins.sh` (extend):** fake `claude` records `marketplace add` / `plugin install`.
  Assert — superpowers marketplace+install happen unconditionally; dotnet only when the flag is
  true; a re-run with both already listed → no add/install calls (idempotent).
- **`test-setup-idempotent.sh` (extend):** add fake `pacman`/`sudo`/`claude` so a full second
  run touches nothing → no diff, exit 0.
- `run-all-tests.sh` picks up `test-deps.sh` via its `test-*.sh` glob.

## 9. Touched files

- `setup.sh` — insert deps phase, renumber to `/8`, ungate plugins, extend verify.
- `lib/deps.sh` — **new**.
- `lib/plugins.sh` — superpowers + factored `_ensure_*` guards.
- `skills/tools/test-deps.sh` — **new**; `test-plugins.sh`, `test-setup-idempotent.sh` — extend.
- `README.md` — describe 8 phases + a dependencies section.
- `settings.template.json` — unchanged (superpowers already `true`).
