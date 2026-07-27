# gstack.sh — own the gstack clone inside a profile's skills/ dir and drive its installer.
# The upstream installer is imperative and interactive by default; every flag below buys back
# one specific behaviour. Idempotent: the installer runs only when upstream HEAD moved.
# Source, don't execute.

gstack_apply() {   # no args; target comes from CLAUDEFILES_TARGET. 0 = ok/unchanged, 1 = failed.
  local repo="${CLAUDEFILES_GSTACK_REPO:-https://github.com/garrytan/gstack.git}"
  local target="${CLAUDEFILES_TARGET:-$HOME/.claude}"
  local dst="$target/skills/gstack" marker="$target/.gstack-setup-head"
  local remedy="if the clone is broken, remove it and re-run: rm -rf $dst"

  # gstack setup:6 exits hard without bun. Fail the profile rather than leave an empty shell.
  if ! command -v bun >/dev/null 2>&1; then
    warn "gstack needs bun — install it: sudo pacman -S --needed bun"
    return 1
  fi

  if [ -d "$dst/.git" ]; then
    # The installer rewrites `name:` fields inside the clone (gstack setup:993, setup:999), so the
    # worktree is permanently dirty and `git pull --ff-only` would fail. Reset to upstream instead.
    if git -C "$dst" fetch --depth 1 origin >/dev/null 2>&1; then
      git -C "$dst" reset --hard FETCH_HEAD >/dev/null 2>&1 \
        || { warn "gstack: reset to upstream failed — $remedy"; return 1; }
    else
      # No network is not a reason to fail a profile that is already provisioned and at the
      # recorded revision: that is exactly the no-op case below. Skip the update, stay green.
      local at; at="$(git -C "$dst" rev-parse HEAD 2>/dev/null)"
      if [ -n "$at" ] && [ -f "$marker" ] && [ "$(cat "$marker")" = "$at" ]; then
        warn "gstack: fetch from $repo failed; keeping the installed revision ($at)"
        return 0
      fi
      warn "gstack: fetch from $repo failed — $remedy"
      return 1
    fi
  else
    rm -rf "$dst" || { warn "gstack: cannot remove stale $dst"; return 1; }   # drop a partial or non-git leftover
    mkdir -p "$(dirname "$dst")" || { warn "gstack: cannot create $(dirname "$dst")"; return 1; }
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
  # < /dev/null makes the non-interactive contract structural: the clone auto-updates, so an
  # upstream that renames a flag or adds a prompt must fail fast, never block on our stdin.
  if ( cd "$dst" && GSTACK_SKIP_FONTS=1 ./setup --host claude --no-team --no-plan-tune-hooks -q < /dev/null ); then
    printf '%s' "$head" > "$marker" || { warn "gstack: cannot write marker $marker"; return 1; }
    log "gstack installed → $dst ($head)"
    return 0
  fi
  warn "gstack: installer failed; marker left unchanged so the next run retries"
  return 1
}
