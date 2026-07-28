# clean.sh — the eraser behind a clean install. It deletes the managed config surface of a profile
# so the UNCHANGED recipes rebuild it from the repo: a missing settings.json makes jsonmerge see
# existing={} and emit exactly the template, a missing manifest makes mcp_apply re-add every
# server. Nothing here installs anything. Source, don't execute.

# Per-profile config surfaces. A fixed denylist, deliberately NOT "remove everything unknown":
# Claude Code keeps adding state dirs (sessions/, file-history/, tasks/), and an allowlist would
# eventually eat credentials or transcripts. settings.json.bak* is a glob, handled separately.
_CLEAN_PATHS=(settings.json settings.local.json CLAUDE.md skills plugins rules agents commands output-styles .gstack-setup-head)

# Manifests are mcp.sh's artifact, so their location comes from mcp.sh. _mcp_manifest takes one
# profile name and cannot express "all of them, legacy included", which is what both the
# announcement and the wipe need — derive the directory from the module instead of re-deriving it.
_clean_manifest_dir() { dirname "$(_mcp_legacy)"; }

_clean_paths_announce() {   # what the user is about to lose, and what they keep
  local p d
  log "clean install will remove:"
  printf '  %s\n' "$(config_path)" "$(_clean_manifest_dir)/managed-mcp*.json"
  printf '  in every profile you select next: %s, settings.json.bak*, and every user-scope MCP server\n' "${_CLEAN_PATHS[*]}"
  for p in vanilla super g; do
    d="$(profile_dir "$p")"; [ -d "$d" ] && printf '  on disk now: %s\n' "$d"
  done
  printf '  kept: .credentials.json, .claude.json (minus mcpServers), projects/, history.jsonl, sessions/, caches\n'
  return 0
}

clean_wanted() {   # 0 = the user asked for a clean install. Asked EVERY run, never persisted:
                   # config_ensure_flag would make it prompt-once and silently stick.
  if ! _has_tty; then
    # CLAUDEFILES_CLEAN forces the y/N answer, not the TTY: clean wipes every stored answer, and
    # they can only be re-entered interactively. Wiping first and dying in config_ensure_flag
    # (config.sh:54) would leave the machine with no configuration at all.
    [ "${CLAUDEFILES_CLEAN:-0}" = 1 ] && die "clean install needs a TTY: it wipes every stored answer"
    return 1
  fi
  local a=y
  if [ "${CLAUDEFILES_CLEAN:-0}" != 1 ]; then
    read -r -p "Clean install? Wipes the selected profiles' config and every stored answer. (y/N) " a || true
  fi
  case "${a,,}" in y|yes) ;; *) return 1 ;; esac
  _clean_paths_announce
  local c; read -r -p "Type 'clean' to confirm: " c || true
  [ "$c" = clean ] || { log "clean install cancelled — continuing with a normal update"; return 1; }
  return 0
}

clean_preflight() {   # hard gates: a cleaned profile is rebuilt from the network, so refuse to
                      # start the demolition we cannot finish. Both paths die BEFORE any deletion.
  _claude_present || die "clean install needs the claude CLI: MCP servers and plugins are reconciled through it"
  if [ "${CLAUDEFILES_CLEAN_SKIP_NET:-0}" = 1 ]; then
    warn "clean: network probe skipped (CLAUDEFILES_CLEAN_SKIP_NET=1)"
    return 0
  fi
  timeout 15 git ls-remote https://github.com/anthropics/claude-plugins-official HEAD >/dev/null 2>&1 \
    || die "clean install needs network: github is unreachable and a cleaned profile is rebuilt from it (override: CLAUDEFILES_CLEAN_SKIP_NET=1)"
  return 0
}
