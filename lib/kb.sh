# kb.sh — own the knowledge-base wiring of a profile: the vault skeleton, the policy rule and the
# index symlink. The vault CONTENT belongs to the user and to auto memory; this module only creates
# what is missing and never rewrites a file that already has content. Source, don't execute.
_KB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_KB_PY="$_KB_DIR/py/kb_settings.py"
_KB_DEFAULT_VAULT="Documents/Notes/kb"

_kb_manifest() { echo "${CLAUDEFILES_CONFIG_DIR:-$HOME/.config/claudefiles}/managed-kb.$1.json"; }

# A relative path is not merely inconvenient: the CLI itself rejects a relative autoMemoryDirectory,
# and a path with '..' would let a typo in secrets.json point the store at an unrelated tree.
kb_vault_path() {
  local raw; raw="$(config_get kb.vault_path)"
  [ -z "$raw" ] && raw="$HOME/$_KB_DEFAULT_VAULT"
  case "$raw" in
    "~")   raw="$HOME" ;;
    "~/"*) raw="$HOME/${raw#\~/}" ;;
  esac
  case "$raw" in
    /*) ;;
    *)  die "kb.vault_path must be an absolute path or start with ~/ (got '$raw')" ;;
  esac
  case "$raw/" in
    */../*) die "kb.vault_path must not contain '..' (got '$raw')" ;;
  esac
  printf '%s\n' "${raw%/}"
}
