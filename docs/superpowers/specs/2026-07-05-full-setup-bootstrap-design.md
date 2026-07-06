# Design: full setup from zero to a ready env (deps + superpowers)

**Date:** 2026-07-05
**Status:** Rev. 2 — Codex review incorporated: `set -e` gate on `deps_apply` (findings via
`if`+`return 0`), `_pacman_install` handling root/sudo-absent, array-based package API (no
word-splitting), check `node` **and** `npx`, chromium check mirrors the resolver override,
whitespace-anchored plugin/marketplace matching that tolerates a failing `claude … list`,
readiness summary includes `claude`. Goal narrowed to "claude already provisioned". The
"rewrite POSIX" note rejected — bash is already required (`setup.sh` shebang; `config.sh`
uses `${x,,}`/`read -p`). Ready for implementation planning.
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

One `./setup.sh` run leaves the machine ready **given `claude` is already provisioned** (by
chezmoi or a manual install — see non-goals): every enabled feature has its system dependency
present (or the user was offered to install it), and both plugins are installed. No manual
post-steps for the happy path. The truly-from-nothing path (installing `claude` itself) is the
chezmoi bootstrap; if `claude` is absent, preflight already warns, the readiness summary
reports it, and the plugin phase degrades gracefully (warn) instead of failing.

**Scope (decided in brainstorming):**
- **Arch only.** The dependency installer targets `pacman`. Non-Arch → print the manual
  command, never fail.
- **Managed deps:** `node`/`npx`, `chromium`, `.NET SDK` — all via `pacman`, each gated by the
  flag that needs it.
- **Install policy:** ask `y/N` per missing dependency, then install via `pacman`. Consent is
  the `y/N`; `--noconfirm` avoids a redundant second prompt.
- **superpowers:** installed from the script, always. **dotnet plugin:** by `dotnet_skills`.

**Non-goals (YAGNI):**
- Installing the `claude` CLI itself — stays a `warn` (that is chezmoi's job, per the existing
  config-ownership design; installing it here would duplicate that boundary). Consequently the
  Goal is conditioned on `claude` being present.
- Cross-distro / macOS package managers (`apt`, `dnf`, `brew`). Arch-only by decision.
- A separate `doctor`/`bootstrap` command — the checks live in the one `setup.sh` run.

## 3. Decisions (resolved 2026-07-05)

1. **Platform — Arch/pacman only.** Missing `pacman` (not Arch) → warn + print the manual
   install command; never abort.
2. **Managed deps — node+npx, chromium, dotnet-sdk.** `claude` CLI excluded (stays `warn`).
3. **Install policy — ask then install.** Per missing dependency: `y/N`; on `y` run
   `pacman -S --needed --noconfirm <pkgs>` (as root directly, else via `sudo`). On
   `n` / no-TTY / no-pacman / no-sudo: warn + manual command, continue.
4. **.NET SDK via pacman** (`dotnet-sdk`), gated by `dotnet_skills`. (Local `setup-local-sdk`
   path considered and rejected for automation simplicity.)
5. **superpowers always, dotnet by flag.** Marketplace `claude-plugins-official`
   (`anthropics/claude-plugins-official`) is added if missing; both confirmed present on the
   reference machine.
6. **bash is required.** `setup.sh` is `#!/usr/bin/env bash`; `lib/config.sh` already uses
   `${x,,}` and `read -p`. The deps helper stays consistent — no POSIX rewrite (Codex §8
   rejected: the premise that bash may be absent does not hold for this repo).

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

Three small helpers. Every path ends non-fatally; `deps_apply` returns 0 explicitly so a
disabled feature never trips `set -e` (Codex finding 1). Package lists are arrays, never
word-split strings (finding 3). Reuses `_has_tty` / `warn` from the already-sourced
`config.sh` / `common.sh`.

```bash
_pacman_install() {   # _pacman_install <pkg...> — root: direct; else sudo; else manual. Never abort.
  if ! command -v pacman >/dev/null 2>&1; then
    warn "pacman not found (not Arch?) — install manually: pacman -S --needed $*"; return 0
  fi
  if [ "$(id -u)" -eq 0 ]; then
    pacman -S --needed --noconfirm "$@" || warn "install of '$*' failed"
  elif command -v sudo >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm "$@" || warn "install of '$*' failed"
  else
    warn "sudo not found — install manually: sudo pacman -S --needed $*"   # finding 2
  fi
  return 0
}

_offer_install() {    # _offer_install <why> <pkg...> — prompt (TTY) then install; else print manual
  local why="$1"; shift
  warn "missing dependency — needed for: $why"
  if _has_tty; then
    local a; read -r -p "Install '$*' via pacman? (y/N) " a || true
    case "${a,,}" in y|yes) _pacman_install "$@" ;;
                     *)      warn "skipped $* — $why won't work until installed" ;; esac
  else
    warn "no TTY — install manually: sudo pacman -S --needed $*"            # never sudo without a TTY
  fi
  return 0
}

# dep_require <why> <check-cmd...> -- <pacman-pkg...> : satisfied iff EVERY check-cmd resolves
# (node AND npx, not just npx — finding 4). Missing any → offer to install ALL pkgs together.
dep_require() {
  local why="$1"; shift
  local cmds=() pkgs=() inpkg=0
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--" ]; then inpkg=1; shift; continue; fi
    if [ "$inpkg" -eq 0 ]; then cmds+=("$1"); else pkgs+=("$1"); fi
    shift
  done
  local c; for c in "${cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || { _offer_install "$why" "${pkgs[@]}"; return 0; }
  done
  return 0
}

_chromium_present() {  # mirror build_servers.py chromium_path(): honor override, then PATH/well-known
  local override; override="$(config_get playwright.chromium_path 2>/dev/null || true)"
  [ -n "$override" ] && [ -x "$override" ] && return 0
  command -v chromium >/dev/null 2>&1 && return 0
  command -v chromium-browser >/dev/null 2>&1 && return 0
  [ -x /usr/bin/chromium ] && return 0
  [ -x /usr/bin/chromium-browser ] && return 0
  return 1
}

deps_apply() {   # deps_apply <ctx7> <playwright> <azure> <ado> <dotnet>
  local ctx7="${1:-false}" pw="${2:-false}" azure="${3:-false}" ado="${4:-false}" dotnet="${5:-false}"
  if [ "$ctx7" = true ] || [ "$pw" = true ] || [ "$azure" = true ] || [ "$ado" = true ]; then
    dep_require "MCP servers (npx-based)" node npx -- nodejs npm
  fi
  if [ "$pw" = true ]; then
    _chromium_present || _offer_install "Playwright MCP browser" chromium   # finding 11: match resolver
  fi
  if [ "$dotnet" = true ]; then
    dep_require "C# language server / dotnet plugin" dotnet -- dotnet-sdk
  fi
  return 0     # finding 1: explicit — a disabled feature must not make this non-zero under set -e
}
```

Behavior contract:
- Every check-cmd present → zero actions (idempotent; `pacman` runs only when genuinely missing).
- Missing + TTY → `y/N`; on `y`, install via `pacman` (root: direct; else `sudo`; else manual).
- Missing + no TTY → print the manual command, never invoke sudo.
- Missing + no pacman / no sudo → print the manual command, continue.
- No branch aborts the run; `deps_apply` and each helper `return 0`.
- Flag gating: `chromium` only with Playwright (and only if the resolver isn't already
  satisfied), `dotnet-sdk` only with `dotnet_skills`, `node`/`npx` only if ≥1 MCP server is on.

`setup.sh` wires it as:
`log "3/8 deps"; deps_apply "$(config_flag context7)" "$(config_flag playwright)" "$(config_flag azure_mcp)" "$(config_flag ado)" "$(config_flag dotnet_skills)"`

### 5.2 `lib/plugins.sh` — superpowers always, dotnet by flag

Idempotent guards factored out of today's inline logic, in the repo's existing
`if ! … | grep -qE` style so `set -e` never trips. The match is **whitespace-anchored on both
sides** so a substring can't be mistaken for an installed plugin (Codex finding 9), and a
failing `claude … list` yields empty output → treated as "absent" → the add/install runs (its
own failure is caught by `|| warn`). All CLI calls go through `"$cb"` (finding 10).

```bash
_ensure_marketplace() {   # <name> <source> — add if absent; tolerate a failing `claude … list`
  local cb; cb="$(claude_bin)"
  if ! "$cb" plugin marketplace list 2>/dev/null | grep -qE "(^|[[:space:]])$1([[:space:]]|\$)"; then
    log "adding marketplace $1"; "$cb" plugin marketplace add "$2" || warn "marketplace add '$1' failed"
  fi
}
_ensure_plugin() {        # <plugin@marketplace> — install if absent (anchored both sides)
  local cb; cb="$(claude_bin)"
  if ! "$cb" plugin list 2>/dev/null | grep -qE "(^|[[:space:]])$1([[:space:]]|\$)"; then
    log "installing $1"; "$cb" plugin install "$1" || warn "install '$1' failed"
  fi
}
plugins_apply() {         # plugins_apply <dotnet_enabled>
  local dotnet="${1:-false}"
  _ensure_marketplace "claude-plugins-official" "anthropics/claude-plugins-official"
  _ensure_plugin      "superpowers@claude-plugins-official"          # ALWAYS
  if [ "$dotnet" = true ]; then
    command -v dotnet >/dev/null 2>&1 || warn "dotnet SDK not found; C# LSP will not start"
    _ensure_marketplace "dotnet-agent-skills" "dotnet/skills"
    _ensure_plugin      "dotnet@dotnet-agent-skills"
  fi
  return 0
}
```

`setup.sh` keeps the failure wrapper so a plugin error never aborts the rest of the config:
`log "6/8 plugins"; plugins_apply "$(config_flag dotnet_skills)" || warn "plugin install failed (rest of config still applied)"`

`settings.template.json` is unchanged — superpowers is already `true` there, now consistent
with always installing it. (`$1`/`$2` in the grep contain `@` and `-`, which are literals in
ERE, so no escaping is needed for these fixed names.)

### 5.3 verify (phase 8) — readiness summary

After the existing `settings.json` validation + catalog self-test, print a short,
**non-fatal** readiness report so "is the env ready?" is visible at the end. One line per
concern, `OK` or `MISSING → <fix>`:

- `claude` CLI — `MISSING → provision via chezmoi (or install manually) before plugins install`
  (finding 5).
- MCP runtime — `OK` only if **both** `node` and `npx` resolve (finding 4); else
  `MISSING → sudo pacman -S nodejs npm`.
- chromium (if Playwright) — via `_chromium_present`; else `MISSING → sudo pacman -S chromium`.
- dotnet (if `dotnet_skills`) — `command -v dotnet`; else `MISSING → sudo pacman -S dotnet-sdk`.
- superpowers / dotnet plugins — installed/enabled state from `claude plugin list`.

## 6. Data flow

`setup.sh` → config resolves flags → **deps** reads those flags and ensures each needed
dependency (offer-install) → settings/skills applied → **plugins** installs superpowers
(+dotnet by flag) → mcp registers servers (now backed by a present `node`/`npx`) → verify
validates and prints readiness. Re-run: all deps present + plugins installed → every phase is a
no-op, no diff, exit 0.

## 7. Error handling

- `_pacman_install`: no pacman → manual + `return 0`; root → `pacman` direct; sudo present →
  `sudo pacman`; neither root nor sudo → manual + `return 0`. Install non-zero → `warn`,
  continue.
- `_offer_install` / `dep_require` / `deps_apply`: every branch ends in `warn`/`return 0`;
  nothing aborts. A declined prompt is a warn, not a failure.
- `plugins_apply`: each add/install is `|| warn`; the whole call is wrapped in `|| warn` in
  `setup.sh`. A superpowers/dotnet failure — or a missing `claude` — is non-fatal.
- **Non-interactive** (`CLAUDEFILES_ASSUME_TTY=0`, e.g. `--non-interactive`): the deps phase
  installs nothing — it prints manual commands and continues (graceful degradation: MCP won't
  launch, but the config still applies). The config phase keeps its existing fail-fast on
  missing required secrets. (One variable name everywhere: `CLAUDEFILES_ASSUME_TTY` — finding 7.)

## 8. Testing

Following the repo pattern (fake binaries on a temp `PATH`, fixture `$HOME`):

- **`test-deps.sh` (new):** fake `pacman` + `sudo` that log their argv to a file. Assert:
  - all check-cmds present → `pacman` never called;
  - `dotnet_skills=false` (and other flags false) → `deps_apply` returns 0 under `set -e`,
    no `pacman` call (finding 1);
  - missing + `CLAUDEFILES_ASSUME_TTY=1` + piped `y` → `pacman -S --needed --noconfirm nodejs npm`
    with **two** package args (findings 3, 6 — force the TTY branch via the env var, not a pipe);
  - missing + `CLAUDEFILES_ASSUME_TTY=0` → `sudo`/`pacman` **not** called, manual command printed;
  - `sudo` absent (and non-root) → warn + manual, no abort (finding 2);
  - `node` present but `npx` absent → treated as missing (finding 4);
  - `playwright=false` → chromium not required even when absent; `playwright=true` +
    `playwright.chromium_path` override pointing at an existing exec → chromium **not** offered
    (finding 11).
- **`test-plugins.sh` (extend):** fake `claude` records `marketplace add` / `plugin install`.
  Assert — superpowers marketplace+install happen unconditionally; dotnet only when the flag is
  true; a re-run with both already listed → no add/install (idempotent); a **substring**
  collision in `plugin list` (e.g. `superpowers@claude-plugins-official-x`) is **not** counted
  as installed (finding 9); a failing `claude … list` (non-zero) → the add/install still runs
  and its own failure is a warn, not an abort.
- **`test-setup-idempotent.sh` (extend):** add fake `pacman`/`sudo`/`claude` so a full second
  run touches nothing → no diff, exit 0.
- `run-all-tests.sh` picks up `test-deps.sh` via its `test-*.sh` glob.

## 9. Touched files

- `setup.sh` — insert deps phase, renumber to `/8`, ungate plugins, extend verify.
- `lib/deps.sh` — **new**.
- `lib/plugins.sh` — superpowers + factored `_ensure_*` guards (anchored match).
- `skills/tools/test-deps.sh` — **new**; `test-plugins.sh`, `test-setup-idempotent.sh` — extend.
- `README.md` — describe 8 phases + a dependencies section.
- `settings.template.json` — unchanged (superpowers already `true`).

## 10. Review refinements (Rev. 2, from Codex review 2026-07-05)

Verified against the actual repo (Codex reviewed the spec without the tree). Incorporated:
findings 1 (`set -e` gate → `if`+`return 0`), 2 (`_pacman_install` root/sudo/manual), 3
(array package API), 4 (check `node` **and** `npx`), 5 (Goal narrowed + readiness reports
`claude`), 6 (TTY test via `CLAUDEFILES_ASSUME_TTY=1`), 7 (single env-var name), 9 (anchored
match + tolerate `claude … list` failure), 10 (`"$cb"` everywhere), 11 (chromium mirrors the
resolver override). **Rejected:** finding 8 ("rewrite POSIX") — bash is already required and
used (`setup.sh` shebang; `config.sh` `${x,,}`/`read -p`); recorded as decision §3.6.
