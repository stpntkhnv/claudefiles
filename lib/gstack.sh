# gstack.sh — own the gstack clone inside a profile's skills/ dir and drive its installer.
# The upstream installer is imperative and interactive by default; every flag below buys back
# one specific behaviour. Idempotent: the installer runs only when the wanted revision moved.
# Source, don't execute.

_gstack_fetch() { # <clone_dir> <ref>  — refresh the clone's objects; 0 = ok
  local dst="$1" ref="$2"
  if [ -z "$ref" ]; then
    git -C "$dst" fetch --depth 1 origin >/dev/null 2>&1
    return
  fi
  # A pin may name a revision older than a shallow clone's single commit, so deepen first.
  if [ "$(git -C "$dst" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    git -C "$dst" fetch --unshallow --tags origin >/dev/null 2>&1
  else
    git -C "$dst" fetch --tags --force origin >/dev/null 2>&1
  fi
}

gstack_apply() {   # no args; target comes from CLAUDEFILES_TARGET. 0 = ok/unchanged, 1 = failed.
  local repo="${CLAUDEFILES_GSTACK_REPO:-https://github.com/garrytan/gstack.git}"
  # Unset (the default) tracks upstream HEAD. Set to a tag/branch/SHA, the clone is held at that
  # revision instead: the upstream installer runs with the user's privileges, so a reviewed
  # revision must be pinnable. claudefiles owns WHERE gstack installs, not WHAT it does.
  local ref="${CLAUDEFILES_GSTACK_REF:-}"
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
    # worktree is permanently dirty and `git pull --ff-only` would fail. Reset to the wanted
    # revision instead.
    if _gstack_fetch "$dst" "$ref"; then
      local want=FETCH_HEAD
      if [ -n "$ref" ]; then
        want="$ref"     # a branch pin has to follow the freshly fetched remote-tracking ref
        git -C "$dst" rev-parse --verify --quiet "refs/remotes/origin/$ref" >/dev/null 2>&1 \
          && want="origin/$ref"
      fi
      git -C "$dst" reset --hard "$want" >/dev/null 2>&1 \
        || { warn "gstack: reset to ${ref:-upstream} failed — $remedy"; return 1; }
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
    if [ -n "$ref" ]; then
      # a pin may name any revision, so keep full history instead of a single-commit clone
      git clone "$repo" "$dst" >/dev/null 2>&1 \
        || { warn "gstack: clone of $repo failed"; return 1; }
      git -C "$dst" checkout --detach "$ref" >/dev/null 2>&1 \
        || { warn "gstack: CLAUDEFILES_GSTACK_REF='$ref' not found in $repo"; return 1; }
    else
      git clone --single-branch --depth 1 "$repo" "$dst" >/dev/null 2>&1 \
        || { warn "gstack: clone of $repo failed"; return 1; }
    fi
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
