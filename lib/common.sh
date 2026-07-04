# common.sh — shared helpers for setup.sh modules. Source, don't execute.
log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
claude_bin() { command -v claude 2>/dev/null || echo "$HOME/.npm-global/bin/claude"; }
