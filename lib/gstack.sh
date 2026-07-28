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

# gstack ships ~57 skills covering its whole lifecycle, including /ship, /land-and-deploy and
# /canary, which merge branches and deploy. Profile g exists for arguing about ideas, so it keeps
# only the vision set. Override with CLAUDEFILES_GSTACK_SKILLS (space-separated names).
_GSTACK_VISION_SKILLS="_gstack-command autoplan context-restore context-save cso design-consultation design-shotgun diagram investigate learn office-hours plan-ceo-review plan-design-review plan-devex-review plan-eng-review"

_gstack_prune() { # <clone_dir> <skills_dir> — drop gstack skills outside the wanted set; always 0
  local clone="$1" sdir="$2" name d removed=0
  local keep=" ${CLAUDEFILES_GSTACK_SKILLS:-$_GSTACK_VISION_SKILLS} "
  for d in "$sdir"/*/; do
    [ -d "$d" ] || continue
    name="${d%/}"; name="${name##*/}"
    [ "$name" = gstack ] && continue                 # the clone itself
    # Only ever remove something gstack published: a matching dir must exist in the clone. Our own
    # skills and anything the user put here by hand have no counterpart there, so they survive.
    [ -f "$clone/$name/SKILL.md" ] || continue
    case "$keep" in *" $name "*) continue ;; esac
    rm -rf "$d" && removed=$((removed + 1))
  done
  [ "$removed" -gt 0 ] && log "gstack: pruned $removed skill(s) outside the vision set"
  return 0
}

# The repo and ref defaults, as accessors: lib/clean.sh's reachability probe needs the same
# values without re-deriving them, so this is the one place either default lives.
_gstack_repo() { echo "${CLAUDEFILES_GSTACK_REPO:-https://github.com/garrytan/gstack.git}"; }
_gstack_ref()  { echo "${CLAUDEFILES_GSTACK_REF:-}"; }

gstack_apply() {   # no args; target comes from CLAUDEFILES_TARGET. 0 = ok/unchanged, 1 = failed.
  local repo; repo="$(_gstack_repo)"
  # Unset (the default) tracks upstream HEAD. Set to a tag/branch/SHA, the clone is held at that
  # revision instead: the upstream installer runs with the user's privileges, so a reviewed
  # revision must be pinnable. claudefiles owns WHERE gstack installs, not WHAT it does.
  local ref; ref="$(_gstack_ref)"
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
    # Prune here too, not only after an install: the wanted set can change between runs, and the
    # fast path is where most runs end up.
    _gstack_prune "$dst" "$target/skills"
    log "gstack unchanged ($head)"; return 0
  fi

  # --host claude is already the upstream default (setup:79), pinned explicitly so a future
  # default of `auto` (setup:204-208) can't pick up a local `codex` and install outside this
  # profile. --no-team leaves project repos alone; --no-plan-tune-hooks kills the interactive
  # prompt at setup:1476; GSTACK_SKIP_FONTS=1 kills the sudo pacman font install at setup:312.
  # < /dev/null makes the non-interactive contract structural: the clone auto-updates, so an
  # upstream that renames a flag or adds a prompt must fail fast, never block on our stdin.
  # timeout bounds what stdin cannot: observed live, the installer's `bunx playwright install
  # chromium` stalled mid-download and sat for 12h with zero progress, which would hang setup.sh
  # forever. A wrong default beats an unbounded wait; the marker stays unwritten either way.
  local secs="${CLAUDEFILES_GSTACK_TIMEOUT:-1800}" rc=0
  ( cd "$dst" && GSTACK_SKIP_FONTS=1 timeout "$secs" ./setup --host claude --no-team --no-plan-tune-hooks -q < /dev/null ) || rc=$?
  if [ "$rc" -eq 0 ]; then
    _gstack_prune "$dst" "$target/skills"
    printf '%s' "$head" > "$marker" || { warn "gstack: cannot write marker $marker"; return 1; }
    log "gstack installed → $dst ($head)"
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    warn "gstack: installer exceeded ${secs}s and was killed (it downloads a browser; a stalled download hangs forever). Raise CLAUDEFILES_GSTACK_TIMEOUT or re-run"
  else
    warn "gstack: installer failed (exit $rc); marker left unchanged so the next run retries"
  fi
  return 1
}
