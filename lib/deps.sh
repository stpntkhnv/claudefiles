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
  if [ "${#cmds[@]}" -eq 0 ] || [ "${#pkgs[@]}" -eq 0 ]; then
    warn "dep_require: malformed call for '$why' (expected '<check-cmd...> -- <pkg...>')"; return 0
  fi
  local c
  for c in "${cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || { _offer_install "$why" "${pkgs[@]}"; return 0; }
  done
  return 0
}

_chromium_present() {  # honors the same playwright.chromium_path override as build_servers.py's
                       # chromium_path(), then PATH/well-known; unlike it, requires the override be
                       # executable (-x) and checks PATH before /usr/bin — not a byte-for-byte mirror
  local override; override="$(config_get playwright.chromium_path 2>/dev/null || true)"
  [ -n "$override" ] && [ -x "$override" ] && return 0
  command -v chromium         >/dev/null 2>&1 && return 0
  command -v chromium-browser >/dev/null 2>&1 && return 0
  [ -x /usr/bin/chromium ]         && return 0
  [ -x /usr/bin/chromium-browser ] && return 0
  return 1
}

deps_apply() {   # <ctx7> <playwright> <azure> <ado> <dotnet> <codex> — offer-install each needed dep; always 0
  local ctx7="${1:-false}" pw="${2:-false}" azure="${3:-false}" ado="${4:-false}" dotnet="${5:-false}" codex="${6:-false}"
  if [ "$ctx7" = true ] || [ "$pw" = true ] || [ "$azure" = true ] || [ "$ado" = true ]; then
    dep_require "MCP servers (npx-based)" node npx -- nodejs npm
  fi
  if [ "$pw" = true ]; then
    _chromium_present || _offer_install "Playwright MCP browser" chromium
  fi
  if [ "$dotnet" = true ]; then
    dep_require "C# language server / dotnet plugin" dotnet -- dotnet-sdk
  fi
  if [ "$codex" = true ]; then
    dep_require "Codex CLI runtime (node/npx)" node npx -- nodejs npm
    _codex_ok || warn "codex CLI missing or < 0.142.5 — install/upgrade: npm install -g @openai/codex"
  fi
  return 0     # explicit — a disabled feature must not make this non-zero under set -e (finding 1)
}

_have_node_npx() { command -v node >/dev/null 2>&1 && command -v npx >/dev/null 2>&1; }

_codex_ok() {   # codex present, runnable, and version >= 0.142.5 (min contract floor)
  command -v codex >/dev/null 2>&1 || return 1
  local v; v="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$v" ] || return 1
  [ "$(printf '%s\n%s\n' "0.142.5" "$v" | sort -V | head -1)" = "0.142.5" ]
}

_codex_authed() {   # exit 0 iff codex reports a logged-in session (local, fast; more robust than doctor --json)
  command -v codex >/dev/null 2>&1 || return 1
  timeout 10 codex login status >/dev/null 2>&1
}

_claude_present() {   # consistent with claude_bin: true if `claude` is on PATH OR its fallback is exec
  command -v claude >/dev/null 2>&1 && return 0
  local cb; cb="$(claude_bin)"; [ -x "$cb" ]
}

_rdy() {   # <label> <fix> <check-cmd...> — one non-fatal readiness line
  local label="$1" fix="$2"; shift 2
  if "$@" >/dev/null 2>&1; then log "ready: $label OK"; else warn "ready: $label MISSING -> $fix"; fi
  return 0
}

readiness_report() {   # <ctx7> <playwright> <azure> <ado> <dotnet> <codex> — non-fatal env summary; always 0
  local ctx7="${1:-false}" pw="${2:-false}" azure="${3:-false}" ado="${4:-false}" dotnet="${5:-false}" codex="${6:-false}"
  local cb; cb="$(claude_bin)"
  _rdy "claude CLI" "provision via chezmoi (or install) before plugins install" _claude_present
  if [ "$ctx7" = true ] || [ "$pw" = true ] || [ "$azure" = true ] || [ "$ado" = true ]; then
    _rdy "MCP runtime (node+npx)" "sudo pacman -S nodejs npm" _have_node_npx
  fi
  if [ "$pw" = true ];     then _rdy "chromium (Playwright)" "sudo pacman -S chromium" _chromium_present; fi
  if [ "$dotnet" = true ]; then _rdy "dotnet SDK" "sudo pacman -S dotnet-sdk" command -v dotnet; fi
  if _claude_present; then
    local listing; listing="$("$cb" plugin list 2>/dev/null || true)"
    if _has_token "superpowers@claude-plugins-official" <<<"$listing"; then
      log "ready: superpowers plugin OK"
    else
      warn "ready: superpowers plugin MISSING -> re-run ./setup.sh"
    fi
    if [ "$dotnet" = true ]; then
      if _has_token "dotnet@dotnet-agent-skills" <<<"$listing"; then
        log "ready: dotnet plugin OK"
      else
        warn "ready: dotnet plugin MISSING -> re-run ./setup.sh"
      fi
    fi
  fi
  if [ "$codex" = true ]; then
    _rdy "codex CLI (>=0.142.5)" "npm install -g @openai/codex" _codex_ok
    _rdy "codex auth"            "run: codex login"             _codex_authed
  fi
  return 0
}
