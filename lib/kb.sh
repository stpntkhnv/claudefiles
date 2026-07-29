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

_KB_INDEX_SEED='# Global index

One line per note: `- [[name]]: what it is about`. This file is loaded into every session, so keep
it under 50 lines and leave the detail in the notes themselves.
'

_KB_README_SEED='# Knowledge base

Written by Claude Code and by hand. Two areas:

- `projects/<slug>/memory/` — auto memory, one folder per repository. The slug comes from the PATH
  of the repository root, so a repository that moves gets a new folder; rename the old one to keep
  its memory.
- `global/` — cross-project notes, indexed by `global/INDEX.md`.

| slug | project |
|---|---|
'

_kb_vault_skeleton() { # <vault>
  local v="$1"
  mkdir -p "$v/projects" "$v/global" || die "kb: cannot create the vault at $v"
  [ -e "$v/global/INDEX.md" ] || printf '%s' "$_KB_INDEX_SEED" > "$v/global/INDEX.md"
  [ -e "$v/README.md" ]       || printf '%s' "$_KB_README_SEED" > "$v/README.md"
}

kb_apply() { # kb_apply <profile> <enabled:true|false>
  local profile="$1" enabled="${2:-false}"
  local target="${CLAUDEFILES_TARGET:-$HOME/.claude}"
  local manifest; manifest="$(_kb_manifest "$profile")"
  local vault=""
  if [ "$enabled" = true ]; then
    vault="$(kb_vault_path)"
    _kb_vault_skeleton "$vault"
  fi
  mkdir -p "$(dirname "$manifest")"
  # Not fatal by design: a knowledge base that cannot be wired is a reason to warn, not a reason to
  # fail a profile whose settings, skills and MCP are already correct.
  python3 "$_KB_PY" "$target/settings.json" "$manifest" "$vault" \
    || { warn "kb ($profile): could not update $target/settings.json"; return 0; }
  if [ "$enabled" = true ]; then
    log "kb ($profile): memory store → $vault"
  else
    log "kb ($profile): disabled"
  fi
  return 0
}
