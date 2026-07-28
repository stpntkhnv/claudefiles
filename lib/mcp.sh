# mcp.sh — reconcile user-scope MCP servers (in $CLAUDE_CONFIG_DIR) against a per-profile manifest.
_mcp_manifest() { echo "${CLAUDEFILES_CONFIG_DIR:-$HOME/.config/claudefiles}/managed-mcp.$1.json"; }
_mcp_legacy()   { echo "${CLAUDEFILES_CONFIG_DIR:-$HOME/.config/claudefiles}/managed-mcp.json"; }

mcp_apply() { # mcp_apply <servers_json> <manifest_path> [<prev_manifest_path>]
  local servers="$1" manifest="$2" prev="${3:-$2}"
  local cb; cb="$(claude_bin)"
  # unchanged AND no pending legacy cleanup -> nothing to do (P1c: don't skip legacy consumption)
  if [ -f "$manifest" ] && { [ "$prev" = "$manifest" ] || [ ! -f "$prev" ]; } && \
     python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))==json.loads(sys.argv[2]) else 1)' \
        "$manifest" "$servers"; then
    log "MCP servers unchanged"; return 0
  fi
  if [ -f "$prev" ]; then                # remove exactly what the previous manifest managed
    python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1])).keys()))' "$prev" \
      | while read -r name; do [ -n "$name" ] && "$cb" mcp remove --scope user "$name" >/dev/null 2>&1 || true; done
  fi
  echo "$servers" | python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin).keys()))' \
    | while read -r name; do
        [ -z "$name" ] && continue
        one="$(echo "$servers" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)[sys.argv[1]]))' "$name")"
        "$cb" mcp remove --scope user "$name" >/dev/null 2>&1 || true
        "$cb" mcp add-json --scope user "$name" "$one"
      done
  mkdir -p "$(dirname "$manifest")"
  (umask 077; printf '%s' "$servers" > "$manifest"); chmod 600 "$manifest"
  [ "$prev" != "$manifest" ] && [ -f "$prev" ] && rm -f "$prev"   # consume legacy manifest
  log "MCP servers reconciled → $manifest"
}

# Linear is the only managed server that needs an interactive OAuth login: add-json puts it in the
# config, `claude mcp login` makes it usable. The browser is opened only on a POSITIVE signal, but
# no branch here is silent: an unknown status (wording changed, server failed) warns instead of
# returning quietly, or a future CLI rename would switch the login off unnoticed. A non-zero
# `mcp get` (that isn't a timeout, see below) means the server is missing from this profile while
# its manifest still lists it, so mcp_apply took the unchanged early-return (mcp.sh:9-13) — report
# the drift, don't paper over it.
# Never fatal: setup.sh runs under set -e and a browser flow must not fail a profile.
mcp_linear_login() { # mcp_linear_login <profile>
  local profile="$1" cb status rc=0 fix="run: claude mcp login linear"
  [ "$(config_flag linear)" = true ] || return 0
  cb="$(claude_bin)"
  if [ ! -x "$cb" ] && ! command -v "$cb" >/dev/null 2>&1; then
    warn "linear ($profile): claude not available — $fix"; return 0
  fi
  # --foreground on both calls below: GNU timeout otherwise calls setpgid(0,0) and runs the CLI in
  # a NEW, background process group relative to the controlling terminal. The Claude CLI does
  # tcsetattr on startup regardless of subcommand; from a background group that raises SIGTTOU (or
  # SIGTTIN on read) and the process just STOPS — not exits — so timeout's own signal never lands
  # (a stopped process doesn't act on a pending TERM), and the call hangs well past its bound. This
  # is the entire reason the phase works at all when run from an interactive ./setup.sh; it looks
  # removable because the fake `claude` in tests never touches the terminal and never shows it.
  # Not adding -k: --foreground already means timeout can't kill(2) the whole group on expiry, only
  # the direct child pid — -k would only re-signal that same pid and doesn't restore group-kill, so
  # it wouldn't close that gap, and neither call here is known to spawn grandchildren that outlive
  # a plain SIGTERM (login's browser is launched by the OS opener, not left as our child).
  status="$(timeout --foreground 30 "$cb" mcp get linear 2>&1)" || rc=$?
  if [ "$rc" -eq 124 ]; then
    warn "linear ($profile): status check timed out — $fix"; return 0
  elif [ "$rc" -ne 0 ]; then
    warn "linear ($profile): not in this profile's config — remove $(_mcp_manifest "$profile") and re-run ./setup.sh to re-add it, then $fix"
    return 0
  fi
  case "$status" in
    *"Needs authentication"*)
      if _has_tty; then
        log "linear ($profile): opening browser to authenticate"
        timeout --foreground 300 "$cb" mcp login linear || warn "linear ($profile): login failed — $fix"
      else
        warn "linear ($profile): not authenticated — $fix"
      fi ;;
    *Connected*) : ;;
    *) warn "linear ($profile): unexpected status from 'claude mcp get linear' — $fix" ;;
  esac
  return 0
}
