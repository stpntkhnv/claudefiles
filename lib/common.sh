# common.sh — shared helpers for setup.sh modules. Source, don't execute.
log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
claude_bin() { command -v claude 2>/dev/null || echo "$HOME/.npm-global/bin/claude"; }

# _has_token <needle> — read whitespace-delimited tokens from stdin; exit 0 iff any token == needle.
# Fixed-string + whole-token (no regex, no substring): 'x@y-official' never matches 'x@y-official-z'.
# Empty stdin (e.g. a failed `... list || true`) -> no tokens -> exit 1.
_has_token() {
  local needle="$1" line
  local -a toks
  while read -r line; do
    read -ra toks <<<"$line"
    for tok in "${toks[@]}"; do [ "$tok" = "$needle" ] && return 0; done
  done
  return 1
}
