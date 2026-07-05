# skills.sh — install personal skills into ~/.claude/skills.
skills_apply() { # skills_apply <repo_root> <dotnet_enabled:true|false>
  local root="$1" dotnet="${2:-false}" dst="$HOME/.claude/skills"
  mkdir -p "$dst"
  # context7-mcp: real dir (copy) — always
  mkdir -p "$dst/context7-mcp"
  cp "$root/claude/skills/context7-mcp/SKILL.md" "$dst/context7-mcp/SKILL.md"
  if [ "$dotnet" != true ]; then
    log "skills installed (context7-mcp); dotnet-router skipped (dotnet disabled)"
    return 0
  fi
  # dotnet-skills clone: the catalog's source of truth. Clone if missing so a FRESH
  # machine gets correct absolute paths (setup.sh used to do this; keep it here).
  if [ ! -d "$root/skills/dotnet-skills/.git" ]; then
    log "cloning dotnet/skills (catalog source)"
    git clone --depth 1 https://github.com/dotnet/skills "$root/skills/dotnet-skills"
  fi
  # catalog: regenerate with absolute paths for THIS machine
  "$root/skills/tools/gen-dotnet-catalog.sh" "$root/skills/dotnet-skills" "$root/claude/skills/dotnet-router"
  # dotnet-router: symlink into the repo
  local d="$dst/dotnet-router"
  [ -e "$d" ] && [ ! -L "$d" ] && die "$d exists and is not a symlink; remove it manually"
  ln -sfnT "$root/claude/skills/dotnet-router" "$d"
  log "skills installed (context7-mcp, dotnet-router)"
}
