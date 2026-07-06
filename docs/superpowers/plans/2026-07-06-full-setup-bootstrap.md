# Full Setup Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `setup.sh` so one run on a fresh Arch machine reaches a *ready* Claude Code env: check (and offer to install) the system dependencies enabled features need, and install **both** plugins — `superpowers` always, `dotnet` by flag.

**Architecture:** A new flag-aware `lib/deps.sh` module (offer-install via `pacman`, every path non-fatal) runs as phase 3, after `config` resolves the flags and before `settings`. `lib/plugins.sh` is rewritten so `plugins_apply <dotnet_enabled>` installs `superpowers` unconditionally and `dotnet` by flag, with idempotent add/install guards. `setup.sh` renumbers to 8 phases, ungates plugins, and ends with a non-fatal readiness summary (`readiness_report`, living in `deps.sh`).

**Tech Stack:** Bash 4+ (`set -euo pipefail`), `pacman`, `python3` (stdlib only), the Claude Code plugin CLI. Tests: fake binaries on an isolated `PATH` + fixture `$HOME`, matching the repo's existing `skills/tools/test-*.sh` pattern.

## Global Constraints

Every task's requirements implicitly include this section. Values copied verbatim from the spec (`docs/superpowers/specs/2026-07-05-full-setup-bootstrap-design.md`).

- **Arch/pacman only.** No `pacman` (not Arch) → `warn` + print the manual command; never abort.
- **Every deps path is non-fatal.** A disabled feature, a declined prompt, a missing `pacman`/`sudo` must not abort `setup.sh` (runs under `set -euo pipefail`). `deps_apply` and each helper end with an explicit `return 0`.
- **Package lists are arrays**, never word-split strings.
- **Install policy:** per missing dependency ask `y/N`, then `pacman -S --needed --noconfirm <pkgs>` — as root directly, else via `sudo`, else print manual. Never `sudo` without a TTY.
- **One env-var name everywhere:** `CLAUDEFILES_ASSUME_TTY` (`=1` force TTY, `=0` force no-TTY).
- **superpowers always, dotnet by flag.** Marketplace `claude-plugins-official` = `anthropics/claude-plugins-official`; `dotnet` = `dotnet/skills`.
- **`claude` CLI is not installed here** — stays a `warn` (chezmoi's job). Goal is conditioned on `claude` already present.
- **All plugin-CLI calls go through `"$cb"` (`claude_bin`).**
- **bash is required** — no POSIX rewrite (`setup.sh` shebang; `config.sh` already uses `${x,,}`/`read -p`).
- **Public repo:** no secret ever in a tracked file; secrets live only in `~/.config/claudefiles/` (`chmod 600`), outside git. The generated `dotnet-router` catalog stays gitignored.
- **Commit trailer** (every commit): `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `lib/deps.sh` | **create** | Flag-aware dependency check + offer-install (`_pacman_install`, `_offer_install`, `dep_require`, `_chromium_present`, `deps_apply`) and the non-fatal `readiness_report` (+ `_have_node_npx`, `_rdy`). |
| `lib/plugins.sh` | **rewrite** | `plugins_apply <dotnet_enabled>` — superpowers always, dotnet by flag; factored `_ensure_marketplace` / `_ensure_plugin` guards. |
| `setup.sh` | **modify** | Source `deps`; insert phase 3 `deps`; renumber `/7`→`/8`; ungate plugins (pass flag); call `readiness_report` in verify. |
| `skills/tools/test-deps.sh` | **create** | Unit-tests `lib/deps.sh` on an isolated `PATH` with fake `pacman`/`sudo`/dep binaries. |
| `skills/tools/test-plugins.sh` | **rewrite** | Assert superpowers-always / dotnet-by-flag / idempotent / substring-collision-safe / failing-`list`-tolerant. |
| `skills/tools/test-setup-idempotent.sh` | **modify** | Add fake `pacman`/`sudo`; assert a full second run touches nothing (no install, no `pacman`). |
| `README.md` | **modify** | Document 8 phases + a Dependencies section. |
| `claude/settings/settings.template.json` | unchanged | `superpowers` already `true` — now consistent with always installing it. |

**Task order:** 1 → 2 → 3 → 4. Each task keeps the whole `skills/tools/` suite green (no task leaves a red test). Tasks 1 and 2 are module-level and tested in isolation; Task 2 rewrites `plugins.sh` and its test together — `setup.sh` is rewired to the new `plugins_apply` signature in Task 3 (transiently, between Tasks 2 and 3, `setup.sh` still calls the old gated form; this breaks no test and is corrected in Task 3).

---

### Task 1: `lib/deps.sh` — dependency check + offer-install + readiness

**Files:**
- Create: `lib/deps.sh`
- Test: `skills/tools/test-deps.sh`

**Interfaces:**
- Consumes (from already-sourced modules): `log`, `warn` (`lib/common.sh`); `_has_tty`, `config_get`, `claude_bin` (`lib/config.sh` / `lib/common.sh`).
- Produces (used by Task 3 in `setup.sh`):
  - `deps_apply <ctx7> <playwright> <azure> <ado> <dotnet>` — all args `true|false`; offer-installs each needed dep; always returns 0.
  - `readiness_report <ctx7> <playwright> <azure> <ado> <dotnet>` — prints a non-fatal env summary; always returns 0.
  - Helpers (module-internal, exercised by the test): `_pacman_install <pkg...>`, `_offer_install <why> <pkg...>`, `dep_require <why> <check-cmd...> -- <pkg...>`, `_chromium_present`, `_have_node_npx`, `_rdy <label> <fix> <check-cmd...>`.

- [ ] **Step 1: Write the failing test** — `skills/tools/test-deps.sh`

The dev box has real `node`/`npx`/`dotnet`/`chromium`/`sudo`/`pacman` in `/usr/bin`, so "absent" cases are only reliable on an **isolated `PATH`** containing nothing but symlinked coreutils + our fakes. `mk_sandbox` builds that per case.

```bash
#!/usr/bin/env bash
# test-deps.sh — unit tests for lib/deps.sh on an ISOLATED PATH.
# node/npx/dotnet/chromium/sudo/pacman all exist in /usr/bin on the dev box, so the
# "absent" cases only hold if PATH contains just our fakes + the handful of coreutils
# the code and harness need. We symlink those into a fresh sandbox per case.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"

# resolve the real coreutils ONCE, while the real PATH is still active
declare -A REAL
for c in bash env python3 id mktemp mkdir grep chmod cat rm ln dirname; do REAL[$c]="$(command -v "$c")"; done

fails=0
chk() { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }
isempty() { [ ! -s "$1" ]; }
haspac()  { grep -qF -- "$1" "$2"; }
nogrep_i(){ ! grep -qiF -- "$1" "$2"; }

mk_sandbox() {   # sets SB, HOME, isolated PATH, PACLOG; wipes any leaked config-dir override
  SB="$(mktemp -d)"
  export HOME="$SB/home"; mkdir -p "$HOME/.config/claudefiles"
  BIN="$SB/bin"; mkdir -p "$BIN"
  local c; for c in "${!REAL[@]}"; do ln -s "${REAL[$c]}" "$BIN/$c"; done
  export PATH="$BIN"
  export PACLOG="$SB/pac.log"; : > "$PACLOG"
  unset CLAUDEFILES_ASSUME_TTY CLAUDEFILES_CONFIG_DIR   # config.sh recomputes CONFIG_DIR from HOME
}
present()    { printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$1"; chmod +x "$BIN/$1"; }
fake_pacman(){ cat > "$BIN/pacman" <<'EOF'
#!/usr/bin/env bash
printf 'pacman %s\n' "$*" >> "$PACLOG"
exit 0
EOF
chmod +x "$BIN/pacman"; }
fake_sudo()  { cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$PACLOG"
exec "$@"
EOF
chmod +x "$BIN/sudo"; }
load() { source "$cf/lib/common.sh"; source "$cf/lib/config.sh"; source "$cf/lib/deps.sh"; }

# A: everything present -> pacman never called
mk_sandbox; fake_pacman; fake_sudo; present node; present npx; present chromium; present dotnet
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply true true true true true <<< ""
chk "all deps present -> pacman not called" isempty "$PACLOG"

# B: all flags false -> deps_apply returns 0 under set -e, no pacman (finding 1)
mk_sandbox; fake_pacman; fake_sudo
load; export CLAUDEFILES_ASSUME_TTY=0
( set -e; deps_apply false false false false false ); rc=$?
chk "all-flags-false returns 0 under set -e" [ "$rc" -eq 0 ]
chk "all-flags-false -> no pacman"           isempty "$PACLOG"

# C: node/npx missing + TTY + piped y -> pacman installs BOTH packages (findings 3, 6)
mk_sandbox; fake_pacman; fake_sudo
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply true false false false false <<< "y"
chk "missing node/npx -> pacman installs nodejs npm" haspac "pacman -S --needed --noconfirm nodejs npm" "$PACLOG"

# D: missing + no TTY -> sudo/pacman NOT called, manual only
mk_sandbox; fake_pacman; fake_sudo
load; export CLAUDEFILES_ASSUME_TTY=0
deps_apply true false false false false <<< "y"
chk "no TTY -> pacman not called" isempty "$PACLOG"

# E: sudo absent + non-root -> warn + manual, no pacman (finding 2)
mk_sandbox; fake_pacman           # NO fake_sudo; real sudo not on the isolated PATH
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply true false false false false <<< "y"
chk "sudo absent -> pacman not run (manual only)" isempty "$PACLOG"

# F: node present but npx absent -> still treated as missing (finding 4)
mk_sandbox; fake_pacman; fake_sudo; present node   # npx absent
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply true false false false false <<< "y"
chk "node present, npx absent -> still offers install" haspac "pacman -S --needed --noconfirm nodejs npm" "$PACLOG"

# G: playwright off -> chromium not required even when absent
mk_sandbox; fake_pacman; fake_sudo; present node; present npx   # chromium absent, playwright off
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply true false false false false <<< "y"
chk "playwright off -> chromium not offered" nogrep_i "chromium" "$PACLOG"

# H: playwright on + chromium_path override -> chromium NOT offered (finding 11)
mk_sandbox; fake_pacman; fake_sudo; present node; present npx
mkdir -p "$SB/opt"; dummy="$SB/opt/mychrome"; printf '#!/usr/bin/env bash\nexit 0\n' > "$dummy"; chmod +x "$dummy"
python3 "$cf/lib/py/config_io.py" set "$HOME/.config/claudefiles/secrets.json" playwright.chromium_path "$dummy"
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply true true false false false <<< "y"
chk "chromium_path override honored -> chromium not offered" nogrep_i "chromium" "$PACLOG"

# I: dotnet flag + dotnet absent -> installs dotnet-sdk (single-package array)
mk_sandbox; fake_pacman; fake_sudo; present node; present npx   # dotnet absent
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply false false false false true <<< "y"
chk "dotnet flag + dotnet absent -> installs dotnet-sdk" haspac "pacman -S --needed --noconfirm dotnet-sdk" "$PACLOG"

[ "$fails" -eq 0 ] && echo "PASS test-deps" || { echo "SOME test-deps CASES FAILED"; exit 1; }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash /home/stsiapan/dev/claudefiles/skills/tools/test-deps.sh`
Expected: FAIL — `lib/deps.sh` does not exist yet, so `source .../lib/deps.sh` errors (`No such file or directory`) and the run aborts before any `PASS`.

- [ ] **Step 3: Create the module** — `lib/deps.sh`

```bash
# deps.sh — flag-aware system-dependency check + offer-install (Arch/pacman).
# Every path is non-fatal: a disabled feature, a declined prompt, a missing pacman
# or sudo must NOT abort setup.sh (which runs under `set -euo pipefail`). Package
# lists are passed as arrays, never word-split strings. Source, don't execute.

_pacman_install() {   # <pkg...> — root: direct pacman; else sudo; else print manual. Never aborts.
  if ! command -v pacman >/dev/null 2>&1; then
    warn "pacman not found (not Arch?) — install manually: pacman -S --needed $*"; return 0
  fi
  if [ "$(id -u)" -eq 0 ]; then
    pacman -S --needed --noconfirm "$@" || warn "install of '$*' failed"
  elif command -v sudo >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm "$@" || warn "install of '$*' failed"
  else
    warn "sudo not found — install manually: sudo pacman -S --needed $*"
  fi
  return 0
}

_offer_install() {    # <why> <pkg...> — prompt on a TTY then install; otherwise print the manual command
  local why="$1"; shift
  warn "missing dependency — needed for: $why"
  if _has_tty; then
    local a; read -r -p "Install '$*' via pacman? (y/N) " a || true
    case "${a,,}" in
      y|yes) _pacman_install "$@" ;;
      *)     warn "skipped $* — $why won't work until installed" ;;
    esac
  else
    warn "no TTY — install manually: sudo pacman -S --needed $*"
  fi
  return 0
}

# dep_require <why> <check-cmd...> -- <pacman-pkg...> : satisfied iff EVERY check-cmd resolves.
# Missing any one -> offer to install ALL packages together. Never aborts.
dep_require() {
  local why="$1"; shift
  local cmds=() pkgs=() inpkg=0
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--" ]; then inpkg=1; shift; continue; fi
    if [ "$inpkg" -eq 0 ]; then cmds+=("$1"); else pkgs+=("$1"); fi
    shift
  done
  local c
  for c in "${cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || { _offer_install "$why" "${pkgs[@]}"; return 0; }
  done
  return 0
}

_chromium_present() {  # mirror build_servers.py chromium_path(): override first, then PATH/well-known
  local override; override="$(config_get playwright.chromium_path 2>/dev/null || true)"
  [ -n "$override" ] && [ -x "$override" ] && return 0
  command -v chromium         >/dev/null 2>&1 && return 0
  command -v chromium-browser >/dev/null 2>&1 && return 0
  [ -x /usr/bin/chromium ]         && return 0
  [ -x /usr/bin/chromium-browser ] && return 0
  return 1
}

deps_apply() {   # <ctx7> <playwright> <azure> <ado> <dotnet> — offer-install each needed dep; always 0
  local ctx7="${1:-false}" pw="${2:-false}" azure="${3:-false}" ado="${4:-false}" dotnet="${5:-false}"
  if [ "$ctx7" = true ] || [ "$pw" = true ] || [ "$azure" = true ] || [ "$ado" = true ]; then
    dep_require "MCP servers (npx-based)" node npx -- nodejs npm
  fi
  if [ "$pw" = true ]; then
    _chromium_present || _offer_install "Playwright MCP browser" chromium
  fi
  if [ "$dotnet" = true ]; then
    dep_require "C# language server / dotnet plugin" dotnet -- dotnet-sdk
  fi
  return 0     # explicit — a disabled feature must not make this non-zero under set -e (finding 1)
}

_have_node_npx() { command -v node >/dev/null 2>&1 && command -v npx >/dev/null 2>&1; }

_rdy() {   # <label> <fix> <check-cmd...> — one non-fatal readiness line
  local label="$1" fix="$2"; shift 2
  if "$@" >/dev/null 2>&1; then log "ready: $label OK"; else warn "ready: $label MISSING -> $fix"; fi
}

readiness_report() {   # <ctx7> <playwright> <azure> <ado> <dotnet> — non-fatal env summary; always 0
  local ctx7="${1:-false}" pw="${2:-false}" azure="${3:-false}" ado="${4:-false}" dotnet="${5:-false}"
  local cb; cb="$(claude_bin)"
  _rdy "claude CLI" "provision via chezmoi (or install) before plugins install" command -v claude
  if [ "$ctx7" = true ] || [ "$pw" = true ] || [ "$azure" = true ] || [ "$ado" = true ]; then
    _rdy "MCP runtime (node+npx)" "sudo pacman -S nodejs npm" _have_node_npx
  fi
  if [ "$pw" = true ];     then _rdy "chromium (Playwright)" "sudo pacman -S chromium" _chromium_present; fi
  if [ "$dotnet" = true ]; then _rdy "dotnet SDK" "sudo pacman -S dotnet-sdk" command -v dotnet; fi
  if command -v claude >/dev/null 2>&1; then
    if "$cb" plugin list 2>/dev/null | grep -qE "(^|[[:space:]])superpowers@claude-plugins-official([[:space:]]|\$)"; then
      log "ready: superpowers plugin OK"
    else
      warn "ready: superpowers plugin MISSING -> re-run ./setup.sh"
    fi
    if [ "$dotnet" = true ]; then
      if "$cb" plugin list 2>/dev/null | grep -qE "(^|[[:space:]])dotnet@dotnet-agent-skills([[:space:]]|\$)"; then
        log "ready: dotnet plugin OK"
      else
        warn "ready: dotnet plugin MISSING -> re-run ./setup.sh"
      fi
    fi
  fi
  return 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash /home/stsiapan/dev/claudefiles/skills/tools/test-deps.sh`
Expected: nine `ok ...` lines then `PASS test-deps` (exit 0). If any line reads `FAIL`, fix `lib/deps.sh` (not the test) and re-run.

- [ ] **Step 5: Confirm the rest of the suite is still green**

Run: `bash /home/stsiapan/dev/claudefiles/skills/tools/run-all-tests.sh`
Expected: `ALL TESTS PASSED`. (Adding `deps.sh` + `test-deps.sh` does not touch `setup.sh` or `plugins.sh`, so the old `test-plugins.sh` and `test-setup-idempotent.sh` still pass.)

- [ ] **Step 6: Commit**

```bash
cd /home/stsiapan/dev/claudefiles
git add lib/deps.sh skills/tools/test-deps.sh
git commit -m "$(cat <<'EOF'
feat(deps): flag-aware dependency check + offer-install + readiness

New lib/deps.sh: dep_require/_offer_install/_pacman_install (Arch/pacman,
every path non-fatal, array packages), _chromium_present mirroring the MCP
resolver override, and a non-fatal readiness_report. Unit-tested on an
isolated PATH with fake pacman/sudo (test-deps.sh).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `lib/plugins.sh` — superpowers always, dotnet by flag

**Files:**
- Rewrite: `lib/plugins.sh`
- Rewrite: `skills/tools/test-plugins.sh`

**Interfaces:**
- Consumes: `log`, `warn`, `claude_bin` (`lib/common.sh`).
- Produces (used by Task 3 in `setup.sh`): `plugins_apply <dotnet_enabled:true|false>` — installs `superpowers@claude-plugins-official` always and `dotnet@dotnet-agent-skills` when the arg is `true`; idempotent; always returns 0. Internal guards `_ensure_marketplace <name> <source>` and `_ensure_plugin <plugin@marketplace>`.

**Spec deviation (intentional, documented):** the spec wrote `_ensure_marketplace`'s presence check as an anchored match on the marketplace **name**. The stateful test fake stores the **source** passed to `marketplace add`, and the real CLI's `marketplace list` output format is not verifiable in this environment. So `_ensure_marketplace` matches **name OR source** as fixed strings (`grep -qF -e "$1" -e "$2"`) — idempotent against the fake and robust to whichever the CLI prints. The anchored-both-sides ERE is retained for `_ensure_plugin` (the `plugin@marketplace` identifier), where finding 9's substring-collision risk is real.

- [ ] **Step 1: Write the failing test** — rewrite `skills/tools/test-plugins.sh`

The current test calls `plugins_apply` with no arg and asserts the dotnet plugin — it must be replaced, because the new `plugins_apply` defaults to dotnet-off.

```bash
#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
fails=0
chk()    { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }
hasln()  { grep -qF -- "$1" "$2"; }
noln()   { ! grep -qF -- "$1" "$2"; }

source "$cf/skills/tools/lib/faketools.bash"
source "$cf/lib/common.sh"; source "$cf/lib/plugins.sh"

# --- superpowers ALWAYS, dotnet OFF: only superpowers is installed ---
setup_fixture_home >/dev/null; L="$(fake_claude_calls)"
plugins_apply false
chk "sp: marketplace added"      hasln "plugin marketplace add anthropics/claude-plugins-official" "$L"
chk "sp: plugin installed"       hasln "plugin install superpowers@claude-plugins-official" "$L"
chk "dotnet off: no dotnet mkt"  noln  "plugin marketplace add dotnet/skills" "$L"
chk "dotnet off: no dotnet inst" noln  "plugin install dotnet@dotnet-agent-skills" "$L"

# --- dotnet ON: both plugins installed ---
setup_fixture_home >/dev/null; L="$(fake_claude_calls)"
plugins_apply true
chk "dotnet on: sp installed"     hasln "plugin install superpowers@claude-plugins-official" "$L"
chk "dotnet on: dotnet mkt added" hasln "plugin marketplace add dotnet/skills" "$L"
chk "dotnet on: dotnet installed" hasln "plugin install dotnet@dotnet-agent-skills" "$L"

# --- idempotent: a second run with both already present installs nothing ---
: > "$CLAUDE_FAKE_LOG"
plugins_apply true
chk "rerun: no plugin install"    noln "plugin install" "$L"

# --- substring collision must NOT count as installed (finding 9) ---
setup_fixture_home >/dev/null; L="$(fake_claude_calls)"
printf '%s\n' "superpowers@claude-plugins-official-x" > "$CLAUDE_FAKE_STATE/plugins"
plugins_apply false
chk "collision: superpowers still installed" hasln "plugin install superpowers@claude-plugins-official" "$L"

# --- a failing `claude ... list` (non-zero) still installs; no abort ---
h2="$(mktemp -d)"; mkdir -p "$h2/bin"; export HOME="$h2"
INSTLOG="$h2/inst.log"; : > "$INSTLOG"; export INSTLOG
cat > "$h2/bin/claude" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "plugin list"|"plugin marketplace") exit 1 ;;                       # list ops FAIL
  "plugin install") printf 'install %s\n' "$3" >> "$INSTLOG"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$h2/bin/claude"; export PATH="$h2/bin:$PATH"; hash -r 2>/dev/null || true
( set -e; plugins_apply false ); rc=$?
chk "failing-list: plugins_apply returns 0 under set -e"  [ "$rc" -eq 0 ]
chk "failing-list: superpowers install still attempted"   hasln "install superpowers@claude-plugins-official" "$INSTLOG"

[ "$fails" -eq 0 ] && echo "PASS test-plugins" || { echo "SOME test-plugins CASES FAILED"; exit 1; }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash /home/stsiapan/dev/claudefiles/skills/tools/test-plugins.sh`
Expected: FAIL — the current `plugins_apply` ignores its argument, never touches `claude-plugins-official`, so `sp: marketplace added` / `sp: plugin installed` fail; the run ends `SOME test-plugins CASES FAILED` (exit 1).

- [ ] **Step 3: Rewrite the module** — `lib/plugins.sh`

```bash
# plugins.sh — install Claude Code plugins idempotently: superpowers ALWAYS, dotnet by flag.
# Guards use the repo's `if ! ... | grep -q` style so `set -e` never trips; a failing
# `claude ... list` yields empty output -> treated as "absent" -> the add/install runs,
# and its own failure is caught by `|| warn` (never aborts the rest of setup.sh).

_ensure_marketplace() {   # <name> <source> — add if absent. Match name OR source as fixed strings:
  local cb; cb="$(claude_bin)"     # the real CLI and our stateful test fake differ on which they print.
  if ! "$cb" plugin marketplace list 2>/dev/null | grep -qF -e "$1" -e "$2"; then
    log "adding marketplace $1"; "$cb" plugin marketplace add "$2" || warn "marketplace add '$1' failed"
  fi
}

_ensure_plugin() {        # <plugin@marketplace> — install if absent. Anchored BOTH sides so a
  local cb; cb="$(claude_bin)"     # substring (e.g. '...-official-x') is not mistaken for installed.
  if ! "$cb" plugin list 2>/dev/null | grep -qE "(^|[[:space:]])$1([[:space:]]|\$)"; then
    log "installing $1"; "$cb" plugin install "$1" || warn "install '$1' failed"
  fi
}

plugins_apply() {         # <dotnet_enabled:true|false>
  local dotnet="${1:-false}"
  _ensure_marketplace "claude-plugins-official" "anthropics/claude-plugins-official"
  _ensure_plugin      "superpowers@claude-plugins-official"
  if [ "$dotnet" = true ]; then
    command -v dotnet >/dev/null 2>&1 || warn "dotnet SDK not found; C# LSP will not start until installed"
    _ensure_marketplace "dotnet-agent-skills" "dotnet/skills"
    _ensure_plugin      "dotnet@dotnet-agent-skills"
  fi
  return 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash /home/stsiapan/dev/claudefiles/skills/tools/test-plugins.sh`
Expected: all `ok ...` lines then `PASS test-plugins` (exit 0).

- [ ] **Step 5: Commit**

```bash
cd /home/stsiapan/dev/claudefiles
git add lib/plugins.sh skills/tools/test-plugins.sh
git commit -m "$(cat <<'EOF'
feat(plugins): install superpowers always, dotnet by flag

plugins_apply <dotnet_enabled> now installs superpowers@claude-plugins-official
unconditionally and dotnet@dotnet-agent-skills only when enabled, via factored
idempotent _ensure_marketplace/_ensure_plugin guards. Plugin match is anchored
both sides (no substring collision); a failing `claude ... list` degrades to
"absent" and the add/install's own failure is a warn, not an abort.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `setup.sh` — 8 phases, deps + ungated plugins + readiness

**Files:**
- Modify: `setup.sh` (source `deps`; phase 3 `deps`; renumber `/7`→`/8`; ungate plugins; readiness in verify)
- Modify: `skills/tools/test-setup-idempotent.sh` (fake `pacman`/`sudo`; assert deps no-op on both runs)

**Interfaces:**
- Consumes: `deps_apply`, `readiness_report` (Task 1); `plugins_apply <dotnet_enabled>` (Task 2); existing `config_flag`, `settings_apply`, `skills_apply`, `mcp_apply`, `hooks_hook_path`, `log`, `warn`, `die`, `require_cmd`.

- [ ] **Step 1: Rewrite `setup.sh`** (replace the whole file)

Changes vs. current: `deps` added to the source loop; phase labels `N/7` → `N/8`; new phase 3 `deps` (wired with all five flags in the spec's order `context7 playwright azure_mcp ado dotnet_skills`); plugins phase ungated — `plugins_apply "$(config_flag dotnet_skills)"` with the existing `|| warn` wrapper; `readiness_report ...` added to verify. The `config_ensure_all` block is unchanged.

```bash
#!/usr/bin/env bash
# Install the full ~/.claude config on this machine. Idempotent; the update path too.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for m in common config deps settings skills plugins mcp hooks; do source "$ROOT/lib/$m.sh"; done

log "1/8 preflight"; require_cmd git; require_cmd python3
command -v claude >/dev/null 2>&1 || warn "claude not on PATH yet (install it, then re-run)"

log "2/8 config"
[ "${1:-}" = "--non-interactive" ] && export CLAUDEFILES_ASSUME_TTY=0
config_ensure_all() {   # ask ONCE for every flag/secret that gates a feature
  config_ensure_flag dotnet_skills "Install .NET skills plugin? (y/N)"
  config_ensure_flag context7      "Enable Context7 MCP? (y/N)"
  if [ "$(config_flag context7)" = true ]; then
    config_ensure_optional context7_api_key "Context7 API key (empty = free tier)" --secret
  fi
  config_ensure_flag playwright "Enable Playwright MCP? (y/N)"
  config_ensure_flag azure_mcp  "Enable Azure MCP? (y/N)"
  config_ensure_flag ado        "Enable Azure DevOps MCP? (y/N)"
  if [ "$(config_flag ado)" = true ]; then
    config_ensure ado.email "Azure DevOps account email"
    _orgs_json="$(config_get ado.orgs)"
    if [ -z "$_orgs_json" ] || [ "$_orgs_json" = "[]" ]; then
      if _has_tty; then
        read -r -p "Azure DevOps organizations (comma-separated): " _orgs || true
        config_set_array ado.orgs "$_orgs"
      else
        die "flags.ado is true but ado.orgs is empty and no TTY to prompt (set it in $(config_path))"
      fi
    fi
    for org in $(config_get ado.orgs | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)))'); do
      config_ensure "ado.pat.$org" "PAT for organization '$org'" --secret
    done
  fi
}
config_ensure_all

log "3/8 deps";          deps_apply "$(config_flag context7)" "$(config_flag playwright)" "$(config_flag azure_mcp)" "$(config_flag ado)" "$(config_flag dotnet_skills)"
log "4/8 settings.json"; settings_apply "$(hooks_hook_path "$ROOT")" "$(config_flag dotnet_skills)"
log "5/8 skills";        skills_apply "$ROOT" "$(config_flag dotnet_skills)"
log "6/8 plugins";       plugins_apply "$(config_flag dotnet_skills)" || warn "plugin install failed (rest of config still applied)"
log "7/8 mcp";           mcp_apply
log "8/8 verify"
if python3 -m json.tool "$HOME/.claude/settings.json" >/dev/null 2>&1; then log "settings.json valid"; else die "settings.json is invalid after apply"; fi
"$ROOT/skills/tools/test-gen-dotnet-catalog.sh" >/dev/null 2>&1 || warn "catalog self-test FAILED"
readiness_report "$(config_flag context7)" "$(config_flag playwright)" "$(config_flag azure_mcp)" "$(config_flag ado)" "$(config_flag dotnet_skills)"
log "Done. Restart Claude Code sessions to pick up skills and hook."
```

- [ ] **Step 2: Extend `test-setup-idempotent.sh`** — add fake `pacman`/`sudo` and assert the deps phase mutates nothing on either run

Insert a fake `pacman`/`sudo` into the fixture `bin` (which `setup_fixture_home` already prepends to `PATH`) right after the fixture is created, and add a post-run assertion. Replace the current file with:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
# fake pacman/sudo so the deps phase can never mutate the real system, and we can
# assert it stays a no-op (all real deps are present + non-interactive never installs)
export PACLOG="$h/pac.log"; : > "$PACLOG"
cat > "$h/bin/pacman" <<'EOF'
#!/usr/bin/env bash
printf 'pacman %s\n' "$*" >> "$PACLOG"
exit 0
EOF
cat > "$h/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$PACLOG"
exec "$@"
EOF
chmod +x "$h/bin/pacman" "$h/bin/sudo"; hash -r 2>/dev/null || true
# seed non-interactive config so no prompt is needed
mkdir -p "$h/.config/claudefiles"
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags": {"context7":true,"playwright":true,"azure_mcp":false,"ado":false,"dotnet_skills":true},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
EOF
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive
cp "$h/.claude/settings.json" "$h/first.json"
manifest="$h/.config/claudefiles/managed-mcp.json"; cp "$manifest" "$h/first-manifest.json"
: > "$CLAUDE_FAKE_LOG"                       # capture only the SECOND run's claude calls
: > "$PACLOG"                                # and only the SECOND run's pacman/sudo calls
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive
diff "$h/first.json" "$h/.claude/settings.json" || { echo "FAIL settings not idempotent"; exit 1; }
diff "$h/first-manifest.json" "$manifest"       || { echo "FAIL manifest not idempotent"; exit 1; }
# 2nd run must not re-install the plugin or re-add MCP (stateful fake reflects prior state, finding 7)
grep -q "plugin install" "$CLAUDE_FAKE_LOG" && { echo "FAIL reinstalled plugin on 2nd run"; exit 1; }
grep -q "mcp add-json"    "$CLAUDE_FAKE_LOG" && { echo "FAIL re-added MCP on 2nd run"; exit 1; }
# deps phase must be a no-op: non-interactive never installs, and it must not shell out to pacman/sudo
[ -s "$PACLOG" ] && { echo "FAIL deps phase invoked pacman/sudo"; cat "$PACLOG"; exit 1; }
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$h/.claude/settings.json"
echo "PASS test-setup-idempotent"
```

- [ ] **Step 3: Run the idempotency test**

Run: `bash /home/stsiapan/dev/claudefiles/skills/tools/test-setup-idempotent.sh`
Expected: `PASS test-setup-idempotent` (exit 0). It exercises the 8-phase run twice and confirms no settings/manifest diff, no re-install, and an empty `PACLOG` (deps phase never shells out — all deps present, non-interactive prints manual at most).

- [ ] **Step 4: Run the full suite**

Run: `bash /home/stsiapan/dev/claudefiles/skills/tools/run-all-tests.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Smoke the readiness output** (visual sanity, interactive path)

Run: `CLAUDEFILES_ASSUME_TTY=0 bash -c 'cd /home/stsiapan/dev/claudefiles && ./setup.sh --non-interactive 2>&1 | tail -n 20'`
Expected: phases logged `1/8`…`8/8`; the tail shows `ready: ...` lines. On this dev box (all deps present, `claude` present) every line should read `OK`; a `MISSING -> <fix>` line is acceptable if a real dependency is genuinely absent — it must never abort. Confirm exit status is 0: `echo $?` → `0`.

- [ ] **Step 6: Commit**

```bash
cd /home/stsiapan/dev/claudefiles
git add setup.sh skills/tools/test-setup-idempotent.sh
git commit -m "$(cat <<'EOF'
feat(setup): 8-phase bootstrap — deps phase, ungated plugins, readiness

Insert phase 3 `deps` (deps_apply, flag-aware offer-install), renumber to /8,
ungate plugins (plugins_apply now installs superpowers always + dotnet by flag),
and end verify with a non-fatal readiness_report. Idempotency test gains fake
pacman/sudo and asserts the deps phase never shells out on a full second run.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `README.md` — document the 8 phases + Dependencies

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the phases heading and list**

Replace the heading `## Что делает `setup.sh` (7 фаз)` with `## Что делает `setup.sh` (8 фаз)`.

Then replace the numbered list (current items 1–7, `README.md:9-15`) with this eight-item list — a new **deps** item inserted at position 3, `plugins` reworded, all renumbered:

```markdown
1. **preflight** — проверка git/python3; про `claude` предупреждает, но не падает.
2. **config** — читает/спрашивает флаги и секреты из `~/.config/claudefiles/secrets.json` (только при TTY; без TTY — падает с понятным списком, а не висит).
3. **deps** — по флагам проверяет системные зависимости и предлагает поставить недостающие через `pacman` (Arch-only, `y/N` → `sudo pacman`): `node`/`npx` для MCP-серверов, `chromium` для Playwright, `dotnet-sdk` для .NET-плагина. Любая ветка не фатальна — нет TTY/`pacman`/`sudo` печатает ручную команду и продолжает.
4. **settings.json** — заменяет управляемые ключи (`model`, `effortLevel`, `tui`, `theme`, `enabledPlugins`, `extraKnownMarketplaces`, `hooks`) из шаблона, сохраняя любые чужие ключи. Плагин dotnet попадает в `enabledPlugins` только если флаг включён.
5. **skills** — копирует `context7-mcp`, а при `dotnet_skills=true` клонирует `dotnet/skills` (если нет), регенерирует каталог с путями этой машины и ставит симлинк `dotnet-router`.
6. **plugins** — идемпотентно ставит `superpowers@claude-plugins-official` (всегда) и, при `dotnet_skills=true`, `dotnet@dotnet-agent-skills`; добавляет их marketplace при отсутствии (гварды: повторный запуск — no-op).
7. **mcp** — сверяет user-scope MCP-серверы с манифестом `managed-mcp.json`: если набор не менялся — ноль вызовов; иначе убирает ровно ранее управляемые имена (без «подметания» по префиксу) и добавляет текущие. Чужие/неуправляемые серверы не трогает.
8. **verify** — валидирует `settings.json`, самотест каталога и печатает readiness-сводку (`claude`, node+npx, chromium, dotnet, оба плагина) — не фатально.
```

- [ ] **Step 2: Correct the direct-install note about superpowers**

In the "Напрямую (разработка)" section, `plugins_apply` now installs superpowers, so the manual step is obsolete. Replace the paragraph at `README.md:35`:

```markdown
Требуется: git, bash, GNU coreutils/awk, python3 (только stdlib). Плагин `superpowers@claude-plugins-official` ставится внутри Claude Code (`/plugin install superpowers@claude-plugins-official`) — процессный каркас, в чьи этапы встраивается dotnet-router.
```

with:

```markdown
Требуется: git, bash, GNU coreutils/awk, python3 (только stdlib). Системные зависимости (`node`/`npx`, `chromium`, `.NET SDK`) фаза **deps** предложит поставить через `pacman` — только под нужные включённые флаги. Оба плагина ставит сам `setup.sh`: `superpowers@claude-plugins-official` (всегда) — процессный каркас, в чьи этапы встраивается dotnet-router — и `dotnet@dotnet-agent-skills` при `dotnet_skills=true`.
```

- [ ] **Step 3: Update the layout comment**

In the "Раскладка" code block, update the `setup.sh` and `lib/*.sh` comment lines (`README.md:60-61`) to mention 8 phases and the new module:

Replace:
```
setup.sh                      # оркестратор (7 фаз)
lib/*.sh                      # config, settings, skills, plugins, mcp, hooks, common, apply-if-changed
```
with:
```
setup.sh                      # оркестратор (8 фаз)
lib/*.sh                      # config, deps, settings, skills, plugins, mcp, hooks, common, apply-if-changed
```

- [ ] **Step 4: Verify the README renders and is internally consistent**

Run: `grep -n "8 фаз" /home/stsiapan/dev/claudefiles/README.md && grep -n "deps" /home/stsiapan/dev/claudefiles/README.md`
Expected: the heading and layout both say `8 фаз`; the deps phase and module both appear. No leftover `7 фаз` / `/plugin install superpowers` manual instruction: `grep -n "7 фаз\|/plugin install superpowers" /home/stsiapan/dev/claudefiles/README.md` should print nothing.

- [ ] **Step 5: Commit**

```bash
cd /home/stsiapan/dev/claudefiles
git add README.md
git commit -m "$(cat <<'EOF'
docs: README — 8 phases, deps phase, both plugins installed by setup.sh

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**1. Spec coverage** — every spec section maps to a task:

| Spec section | Task |
|--------------|------|
| §4 8-phase architecture, renumber `/8` | Task 3 |
| §5.1 `lib/deps.sh` (`_pacman_install`, `_offer_install`, `dep_require`, `_chromium_present`, `deps_apply`) | Task 1 |
| §5.1 `setup.sh` deps wiring (five flags, spec order) | Task 3 |
| §5.2 `lib/plugins.sh` (`_ensure_marketplace`, `_ensure_plugin`, `plugins_apply <flag>`) + `setup.sh` `|| warn` wrapper | Task 2 (module) + Task 3 (wiring) |
| §5.3 readiness summary (claude, node+npx, chromium, dotnet, both plugins) | `readiness_report` in Task 1, called in Task 3 |
| §7 error handling (non-fatal everywhere, non-interactive prints manual) | Tasks 1 & 3 code + Task 1 cases D/E and Task 3 `PACLOG`-empty assert |
| §8 testing: `test-deps.sh` (new), `test-plugins.sh` (extend), `test-setup-idempotent.sh` (extend), `run-all-tests.sh` glob | Tasks 1, 2, 3 |
| §9 touched files incl. README; settings.template unchanged | Task 4; template left untouched everywhere |
| §8 finding-specific cases 1/2/3/4/6/9/11 | Task 1 cases B/E/C/F/(C via ASSUME_TTY=1)/, Task 2 collision + failing-list cases |

No spec requirement is left without a task.

**2. Placeholder scan** — no `TBD`/`TODO`/"add error handling"/"similar to Task N". Every code and test step contains complete, runnable content; every run step states the exact command and expected output.

**3. Type/name consistency** — signatures are stable across tasks: `deps_apply`/`readiness_report` take the same five ordered flags in Task 1 and Task 3; `plugins_apply <dotnet_enabled>` is defined in Task 2 and called with `"$(config_flag dotnet_skills)"` in Task 3; `_chromium_present` / `_have_node_npx` are defined once in `deps.sh` and reused by `readiness_report`; the fake-tool globals (`CLAUDE_FAKE_LOG`, `CLAUDE_FAKE_STATE`, `fake_claude_calls`) match `skills/tools/lib/faketools.bash`; `PACLOG` is the one log name across `test-deps.sh` and `test-setup-idempotent.sh`.

**Noted deviation from spec** (Task 2): `_ensure_marketplace` matches marketplace name-OR-source as fixed strings instead of the spec's anchored-name match — required for determinism against the stateful test fake (which stores the source) and robustness to the CLI's unverified `marketplace list` format; the anchored-both-sides match is kept where it matters (the `plugin@marketplace` identifier, finding 9).
