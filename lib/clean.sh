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

_clean_have_bun() { command -v bun >/dev/null 2>&1; }   # a seam: tests shadow this instead of PATH

_clean_gstack_reachable() {   # the g clone is deliberately NOT backed up (1.5G), so refuse to delete
                              # it unless the CONFIGURED repo answers. clean_preflight probes github
                              # generally, which says nothing about a pinned or self-hosted gstack.
  [ "${CLAUDEFILES_CLEAN_SKIP_NET:-0}" = 1 ] && return 0
  local repo="${CLAUDEFILES_GSTACK_REPO:-https://github.com/garrytan/gstack.git}"
  local ref="${CLAUDEFILES_GSTACK_REF:-}"
  if [ -n "$ref" ]; then
    timeout 30 git ls-remote --exit-code "$repo" "$ref" >/dev/null 2>&1 && return 0
    # a SHA pin resolves to no ref name, so it cannot be proven without cloning; settle for proving
    # the repo itself answers, which is still strictly better than deleting blind.
    timeout 30 git ls-remote "$repo" >/dev/null 2>&1 && return 0
    return 1
  fi
  timeout 30 git ls-remote "$repo" HEAD >/dev/null 2>&1
}

_clean_mcp_names() {   # <claude_json> — whitespace-separated user-scope server names, "" if none
  [ -f "$1" ] || return 0
  python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print(" ".join((d.get("mcpServers") or {}).keys()))' "$1"
}

_clean_mcp_purge() {   # <name> <profile_dir> — drop EVERY user-scope server, not just ours
  local name="$1" d="$2" n cb; cb="$(claude_bin)"
  for n in $(_clean_mcp_names "$d/.claude.json"); do
    "$cb" mcp remove --scope user "$n" >/dev/null 2>&1 \
      || warn "clean: could not remove MCP server '$n' (mcp_apply reconciles next)"
  done
  # The legacy ~/.claude.json predates CLAUDE_CONFIG_DIR and still carries mcpServers for the
  # default profile; the CLI may write only to the profile dir, so drop that ONE key by hand and
  # leave oauthAccount / projects / machineID and the file mode untouched.
  if [ "$name" = vanilla ] && [ -f "$HOME/.claude.json" ]; then
    clean_backup_take "$HOME/.claude.json" "$name/legacy-claude.json"
    # `|| die`: rewriting is the one step here that can leave the file damaged, so its failure must
    # stop the run through our own error path. Unguarded, it would surface as a raw traceback and
    # kill setup.sh via set -e — an unintentional exit, which the module's contract rules out.
    python3 - "$HOME/.claude.json" <<'PY' || die "clean: cannot rewrite $HOME/.claude.json"
import json, os, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    sys.exit(0)
if "mcpServers" not in d:          # `not in`, not pop()-is-None: an explicit null must still be dropped
    sys.exit(0)
del d["mcpServers"]
tmp = p + ".tmp"
try:
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2)
    os.chmod(tmp, os.stat(p).st_mode & 0o777)
    os.replace(tmp, p)
except Exception as e:
    sys.stderr.write(f"{e}\n")
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.exit(1)
PY
  fi
  return 0
}

_clean_backup_skills() {   # <profile_dir> <name> — back up skills/, skipping the gstack clone ONLY
                           # in profile g, where the recipe reclones it. A gstack dir anywhere else
                           # is drift nobody promised to rebuild, so it gets backed up like the rest.
  local d="$1" name="$2" s base
  for s in "$d"/skills/* "$d"/skills/.[!.]*; do
    [ -e "$s" ] || [ -L "$s" ] || continue
    base="$(basename "$s")"
    [ "$base" = gstack ] && [ "$name" = g ] && continue
    clean_backup_take "$s" "$name/skills/$base"
  done
  return 0
}

clean_profile() {   # <name> — phase B, inside provision_selected's subshell, before the recipe.
                    # 0 = wiped, 1 = refused or failed (the profile then goes to PROVISION_FAILED:
                    # a half-wiped, half-rebuilt profile is worse than an honest failure).
  local name="$1" d="${CLAUDEFILES_TARGET:-$HOME/.claude}" p f
  local -a doomed=()
  if [ "$name" = g ]; then
    _clean_have_bun \
      || { warn "clean: profile g needs bun to reinstall gstack — refusing to wipe it (sudo pacman -S --needed bun)"; return 1; }
    _clean_gstack_reachable \
      || { warn "clean: gstack repo/revision does not resolve — refusing to wipe a clone that is not backed up"; return 1; }
  fi
  for p in "${_CLEAN_PATHS[@]}"; do
    [ -e "$d/$p" ] || [ -L "$d/$p" ] || continue
    doomed+=("$d/$p")
  done
  for f in "$d"/settings.json.bak*; do
    [ -e "$f" ] && doomed+=("$f")
  done
  # PASS 1 — back everything up first. clean_backup_take dies on failure, so a broken backup aborts
  # the run with the profile still WHOLE. Interleaving copy and delete would leave the profile
  # half-destroyed the moment a later copy fails, which is the one state with no way back.
  for p in "${doomed[@]}"; do
    case "$(basename "$p")" in
      skills) _clean_backup_skills "$d" "$name" ;;
      *)      clean_backup_take "$p" "$name/$(basename "$p")" ;;
    esac
  done
  _clean_mcp_purge "$name" "$d"          # after the backups: it mutates .claude.json files too
  # PASS 2 — delete.
  for p in "${doomed[@]}"; do
    rm -rf "$p" || { warn "clean: cannot remove $p"; return 1; }
  done
  log "clean: $name wiped — the recipe rebuilds it from the repo"
  return 0
}

clean_verify() {   # <name> <repo_root> — audit a cleaned profile. Always 0: Claude Code re-adds the
                   # official marketplace on its own at next start, so this reports, never gates.
  local name="$1" root="$2" d issues=0 s base p w listing cb
  d="$(profile_dir "$name")"; cb="$(claude_bin)"
  # 1. strays in skills/. Derived from the repo tree (and, for g, from what the clone published),
  #    NOT from a hardcoded list: that knowledge belongs to skills.sh, not to the eraser.
  for s in "$d"/skills/*/; do
    [ -d "$s" ] || continue
    base="$(basename "$s")"
    [ "$base" = gstack ] && continue
    [ -d "$root/claude/skills/$base" ] && continue
    [ -f "$d/skills/gstack/$base/SKILL.md" ] && continue
    warn "clean-verify $name: stray skill '$base'"; issues=$((issues + 1))
  done
  # 2. directories the repo never creates
  for p in rules agents commands output-styles; do
    if [ -e "$d/$p" ]; then warn "clean-verify $name: '$p/' is back"; issues=$((issues + 1)); fi
  done
  # 3. live user-scope MCP set vs the manifest we just wrote
  local manifest; manifest="$(_mcp_manifest "$name")"
  if [ -f "$manifest" ] && [ -f "$d/.claude.json" ]; then
    python3 -c 'import json,sys
want=sorted(json.load(open(sys.argv[1])).keys())
try: live=sorted((json.load(open(sys.argv[2])).get("mcpServers") or {}).keys())
except Exception: live=[]
sys.exit(0 if want==live else 1)' "$manifest" "$d/.claude.json" \
      || { warn "clean-verify $name: user-scope MCP servers differ from $manifest"; issues=$((issues + 1)); }
  fi
  # 4. top-level keys of settings.json vs the profile's template. After a clean the file is written
  #    from scratch, so anything extra means something re-added a key mid-run.
  local tmpl="$root/claude/settings/settings.$name.template.json"
  if [ -f "$tmpl" ] && [ -f "$d/settings.json" ]; then
    python3 -c 'import json,sys
t=set(json.load(open(sys.argv[1])));o=set(json.load(open(sys.argv[2])))
sys.exit(0 if t==o else 1)' "$tmpl" "$d/settings.json" \
      || { warn "clean-verify $name: settings.json keys differ from $(basename "$tmpl")"; issues=$((issues + 1)); }
  fi
  # 5. plugin COVERAGE (expected ⊆ installed), not equality: Claude Code auto-installs the official
  #    marketplace by itself, and reporting that as drift would train the user to ignore the report.
  #    The expected set is read from the profile's OWN enabledPlugins, freshly written from the
  #    template and already flag-gated by jsonmerge.py — so the "which plugins does this profile
  #    want" logic is never duplicated here and cannot go stale.
  local want_plugins=()
  if [ -f "$d/settings.json" ]; then
    while read -r w; do
      [ -n "$w" ] && want_plugins+=("$w")
    done < <(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print("\n".join((d.get("enabledPlugins") or {}).keys()))' "$d/settings.json")
  fi
  if [ "${#want_plugins[@]}" -gt 0 ]; then
    listing="$(env CLAUDE_CONFIG_DIR="$d" "$cb" plugin list 2>/dev/null || true)"
    for w in "${want_plugins[@]}"; do
      _has_token "$w" <<<"$listing" \
        || { warn "clean-verify $name: plugin '$w' is NOT installed after clean"; issues=$((issues + 1)); }
    done
  fi
  if [ "$issues" -eq 0 ]; then
    log "clean-verify $name: OK"
  else
    warn "clean-verify $name: $issues issue(s) — backup: ${CLAUDEFILES_CLEAN_BACKUP:-n/a}"
  fi
  return 0
}

clean_warn_unselected() {   # <selected...> — clean touches ONLY the profiles being installed. A
                            # leftover dir keeps its transcripts, so deleting it is not our call;
                            # saying nothing about it would misrepresent what the run just did.
  local p d
  for p in vanilla super g; do
    case " $* " in *" $p "*) continue ;; esac
    d="$(profile_dir "$p")"
    [ -d "$d" ] && warn "clean: $d was not selected — left untouched (still dirty)"
  done
  return 0
}
