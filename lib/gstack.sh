# gstack.sh — own the gstack clone inside a profile's skills/ dir and drive its installer.
# The upstream installer is imperative and interactive by default; every flag below buys back
# one specific behaviour. Idempotent: the installer runs only when upstream HEAD moved.
# Source, don't execute.

gstack_apply() {   # no args; target comes from CLAUDEFILES_TARGET. 0 = ok/unchanged, 1 = failed.
  local repo="${CLAUDEFILES_GSTACK_REPO:-https://github.com/garrytan/gstack.git}"
  local target="${CLAUDEFILES_TARGET:-$HOME/.claude}"
  local dst="$target/skills/gstack" marker="$target/.gstack-setup-head"

  # gstack setup:6 exits hard without bun. Fail the profile rather than leave an empty shell.
  if ! command -v bun >/dev/null 2>&1; then
    warn "gstack needs bun — install it: sudo pacman -S --needed bun"
    return 1
  fi

  if [ -d "$dst/.git" ]; then
    # The installer rewrites `name:` fields inside the clone (gstack setup:993, setup:999), so the
    # worktree is permanently dirty and `git pull --ff-only` would fail. Reset to upstream instead.
    git -C "$dst" fetch --depth 1 origin >/dev/null 2>&1 || { warn "gstack: fetch from $repo failed"; return 1; }
    git -C "$dst" reset --hard FETCH_HEAD >/dev/null 2>&1 || { warn "gstack: reset to upstream failed"; return 1; }
  else
    rm -rf "$dst"                       # drop a partial or non-git leftover
    mkdir -p "$(dirname "$dst")"
    git clone --single-branch --depth 1 "$repo" "$dst" >/dev/null 2>&1 \
      || { warn "gstack: clone of $repo failed"; return 1; }
  fi

  local head; head="$(git -C "$dst" rev-parse HEAD)" || { warn "gstack: cannot read clone HEAD"; return 1; }
  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$head" ]; then
    log "gstack unchanged ($head)"; return 0
  fi

  # --host claude is already the upstream default (setup:79), pinned explicitly so a future
  # default of `auto` (setup:204-208) can't pick up a local `codex` and install outside this
  # profile. --no-team leaves project repos alone; --no-plan-tune-hooks kills the interactive
  # prompt at setup:1476; GSTACK_SKIP_FONTS=1 kills the sudo pacman font install at setup:312.
  if ( cd "$dst" && GSTACK_SKIP_FONTS=1 ./setup --host claude --no-team --no-plan-tune-hooks -q ); then
    printf '%s' "$head" > "$marker"
    log "gstack installed → $dst ($head)"
    return 0
  fi
  warn "gstack: installer failed; marker left unchanged so the next run retries"
  return 1
}
