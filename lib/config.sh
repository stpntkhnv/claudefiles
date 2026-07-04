# config.sh — secrets.json accessors with TTY-aware prompting.
# `read ... || true` below: bash's `read` returns exit 1 when stdin hits EOF
# without a trailing newline (e.g. a piped secret with no final \n). The value
# is still captured correctly either way; the `|| true` just stops that
# no-newline case from tripping `set -e` in the sourcing script.
CLAUDEFILES_CONFIG_DIR="${CLAUDEFILES_CONFIG_DIR:-$HOME/.config/claudefiles}"
_CFG_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/config_io.py"
config_path()      { echo "$CLAUDEFILES_CONFIG_DIR/secrets.json"; }
config_get()       { python3 "$_CFG_PY" get      "$(config_path)" "$1"; }
config_has()       { python3 "$_CFG_PY" has      "$(config_path)" "$1"; }   # exit 0 if key present
config_set()       { python3 "$_CFG_PY" set      "$(config_path)" "$1" "$2"; }
config_set_bool()  { python3 "$_CFG_PY" setbool  "$(config_path)" "$1" "$2"; }
config_set_array() { python3 "$_CFG_PY" setarray "$(config_path)" "$1" "$2"; }

_has_tty() { [ "${CLAUDEFILES_ASSUME_TTY:-}" = "1" ] && return 0
             [ "${CLAUDEFILES_ASSUME_TTY:-}" = "0" ] && return 1
             [ -t 0 ]; }

# flags are real JSON booleans; get emits them lowercase so this compare works.
config_flag() { [ "$(config_get "flags.$1")" = "true" ] && echo true || echo false; }

config_ensure() { # config_ensure <key> <prompt> [--secret] — REQUIRED string, empty rejected
  local key="$1" prompt="$2" secret="${3:-}" cur; cur="$(config_get "$key")"
  [ -n "$cur" ] && return 0
  if _has_tty; then
    local val
    if [ "$secret" = "--secret" ]; then read -rs -p "$prompt " val || true; echo; else read -r -p "$prompt " val || true; fi
    config_set "$key" "$val"
  else
    die "missing required config '$key' and no TTY to prompt (set it in $(config_path))"
  fi
}

config_ensure_optional() { # <key> <prompt> [--secret] — ask ONCE; empty is valid + remembered
  local key="$1" prompt="$2" secret="${3:-}"
  config_has "$key" && return 0                 # already asked (even if stored empty) -> never re-ask
  if _has_tty; then
    local val
    if [ "$secret" = "--secret" ]; then read -rs -p "$prompt " val || true; echo; else read -r -p "$prompt " val || true; fi
    config_set "$key" "$val"                     # persists "" too -> config_has true next run
  else
    config_set "$key" ""                         # no TTY: record empty, do not fail (optional)
  fi
}

config_ensure_flag() { # <name> <prompt> — ask ONCE for a boolean, persist as JSON bool
  local name="$1" prompt="$2"
  config_has "flags.$name" && return 0
  if _has_tty; then
    local val; read -r -p "$prompt " val || true
    case "${val,,}" in y|yes|true|1) val=true ;; *) val=false ;; esac
    config_set_bool "flags.$name" "$val"
  else
    die "missing required flag 'flags.$name' and no TTY to prompt (set it in $(config_path))"
  fi
}
