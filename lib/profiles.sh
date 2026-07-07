# profiles.sh — profile recipes + per-profile wiring. Source after the other lib/*.sh modules.
profile_dir() { # <name>
  case "$1" in vanilla) echo "$HOME/.claude" ;; *) echo "$HOME/.claude-$1" ;; esac
}

recipe_vanilla() { # <repo_root>  (caller exports CLAUDEFILES_TARGET + CLAUDE_CONFIG_DIR)
  local root="$1"
  settings_apply "$root/claude/settings/settings.vanilla.template.json" false false
  skills_apply "$root" false false
  claudemd_apply false               # drop codex nudge if migrating off super
  claudemd_personal_apply true
  local servers; servers="$(python3 "$root/claude/mcp/build_servers.py" "$(config_path)" vanilla)"
  mcp_apply "$servers" "$(_mcp_manifest vanilla)" "$(_mcp_legacy)"
}

recipe_super() { # <repo_root>
  local root="$1" dotnet cr cpe
  dotnet="$(config_flag dotnet_skills)"; cr="$(config_flag codex_review)"
  cpe=false; [ "$cr" = true ] && [ "$(config_flag codex_plugin)" = true ] && cpe=true
  settings_apply "$root/claude/settings/settings.super.template.json" "$dotnet" "$cpe"
  skills_apply "$root" "$dotnet" "$cr"
  claudemd_apply "$cr"
  claudemd_personal_apply false      # keep super's CLAUDE.md as before (personal block is vanilla-only)
  plugins_apply "$dotnet" "$cpe" || warn "super: plugins_apply reported an error (continuing to verify)"
  local servers; servers="$(python3 "$root/claude/mcp/build_servers.py" "$(config_path)")"
  mcp_apply "$servers" "$(_mcp_manifest super)"
  # P1a: super counts as successful ONLY if its core plugin is actually installed. plugins_apply
  # swallows install errors internally, so verify against reality. CLAUDE_CONFIG_DIR is already
  # exported to the super dir by the caller, so this checks the right profile.
  if command -v claude >/dev/null 2>&1; then
    claude plugin list 2>/dev/null | grep -q 'superpowers@' \
      || { warn "super: superpowers plugin missing after install — marking profile failed"; return 1; }
  else
    warn "super: claude not on PATH; cannot verify superpowers install"
  fi
}

ensure_credentials_symlink() { # <target_dir>
  local dir="$1" src="$HOME/.claude/.credentials.json"
  [ "$dir" = "$HOME/.claude" ] && return 0            # default dir owns the real file
  if [ -e "$dir/.credentials.json" ] || [ -L "$dir/.credentials.json" ]; then
    return 0                                           # idempotent; -L covers a dangling link
  fi
  mkdir -p "$dir"; ln -s "$src" "$dir/.credentials.json"
  log "linked credentials → $dir/.credentials.json"
}

_WRAPPER_MARKER="# claudefiles-managed-wrapper"
generate_wrapper() { # <name> <target_dir>
  local name="$1" dir="$2" bin="$HOME/.local/bin" w
  mkdir -p "$bin"; w="$bin/claude-$name"
  if [ -e "$w" ] && ! grep -qF "$_WRAPPER_MARKER" "$w" 2>/dev/null; then
    warn "$w exists and is not claudefiles-managed; leaving it untouched (P2b)"; return 0
  fi
  printf '#!/usr/bin/env bash\n%s\nexec env CLAUDE_CONFIG_DIR=%q claude "$@"\n' "$_WRAPPER_MARKER" "$dir" > "$w"
  chmod +x "$w"
  log "wrapper → $w"
}

provision_selected() { # <repo_root> <profile...>; sets PROVISION_FAILED=(); runs each recipe in a subshell
  local root="$1"; shift
  PROVISION_FAILED=()
  local p dir
  for p in "$@"; do
    dir="$(profile_dir "$p")"
    log "profile: $p → $dir"
    if ( export CLAUDEFILES_TARGET="$dir"; export CLAUDE_CONFIG_DIR="$dir"; "recipe_$p" "$root" ); then
      ensure_credentials_symlink "$dir"
      if [ "$p" != vanilla ]; then generate_wrapper "$p" "$dir"; fi
    else
      warn "profile '$p' failed to provision"; PROVISION_FAILED+=("$p")
    fi
  done
}
