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

clean_backup_open() {   # [<stamp>] — open the run's backup dir. die on failure: the confirmation
                        # plus this backup ARE the safety net of the mode.
  local stamp="${1:-$(date +%Y%m%d-%H%M%S)}"
  # config.sh:6 already normalises CLAUDEFILES_CONFIG_DIR at source time, so re-declaring its
  # default here would be a second copy of the same fact.
  local dir="$CLAUDEFILES_CONFIG_DIR/clean-backups/$stamp"
  mkdir -p "$dir" || die "clean: cannot create backup dir $dir"
  chmod 700 "$dir" || die "clean: cannot chmod 700 $dir"
  export CLAUDEFILES_CLEAN_BACKUP="$dir"
  log "clean: backup → $dir"
}

clean_backup_take() {   # <src> <rel_dest> — copy into the backup preserving modes. A missing src
                        # is normal (nothing to keep); a FAILED copy is fatal, never a warning.
  local src="$1" rel="$2" dst
  [ -e "$src" ] || [ -L "$src" ] || return 0
  [ -n "${CLAUDEFILES_CLEAN_BACKUP:-}" ] || die "clean: backup dir not open (call clean_backup_open first)"
  dst="$CLAUDEFILES_CLEAN_BACKUP/$rel"
  mkdir -p "$(dirname "$dst")" || die "clean: cannot create $(dirname "$dst")"
  # rm first: `cp -a src dir` where dir already exists copies INTO it, which would nest a second
  # copy on a repeated take instead of replacing the first.
  rm -rf "$dst" || die "clean: cannot remove existing backup at $dst"
  cp -a "$src" "$dst" || die "clean: backup of $src failed — refusing to delete anything"
  return 0
}

clean_global() {   # phase A: the stored answers and the MCP manifests. Runs BEFORE config_ensure_all,
                   # so the run re-asks everything instead of wiping answers it just collected.
  local f mdir; mdir="$(_clean_manifest_dir)"
  clean_backup_take "$(config_path)" "global/secrets.json"
  for f in "$mdir"/managed-mcp*.json; do
    [ -e "$f" ] || continue
    clean_backup_take "$f" "global/$(basename "$f")"
  done
  rm -f "$(config_path)" "$mdir"/managed-mcp*.json
  log "clean: stored answers and MCP manifests wiped"
}
