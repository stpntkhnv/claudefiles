#!/usr/bin/env bash
# test-kb.sh — unit tests for lib/kb.sh and lib/py/kb_settings.py.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
fails=0
chk() { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }
# `die` exits, so a case that expects it runs in a subshell of THIS shell — `bash -c` would start a
# fresh shell where none of the sourced functions exist and would "pass" for the wrong reason.
dies() { ( "$@" ) >/dev/null 2>&1; [ "$?" -ne 0 ]; }
source "$cf/skills/tools/lib/faketools.bash"
source "$cf/lib/common.sh"; source "$cf/lib/config.sh"; source "$cf/lib/kb.sh"

# --- kb_vault_path ---------------------------------------------------------
setup_fixture_home >/dev/null; h="$HOME"
export CLAUDEFILES_CONFIG_DIR="$h/.config/claudefiles"; mkdir -p "$CLAUDEFILES_CONFIG_DIR"

chk "default vault when unset" [ "$(kb_vault_path)" = "$h/Documents/Notes/kb" ]

config_set kb.vault_path "~/vault"
chk "tilde expanded"           [ "$(kb_vault_path)" = "$h/vault" ]

config_set kb.vault_path "/srv/kb/"
chk "trailing slash stripped"  [ "$(kb_vault_path)" = "/srv/kb" ]

config_set kb.vault_path "relative/kb"
chk "relative path dies"       dies kb_vault_path

config_set kb.vault_path "/srv/../etc/kb"
chk "dot-dot dies"             dies kb_vault_path

config_set kb.vault_path ""
chk "empty falls back to default" [ "$(kb_vault_path)" = "$h/Documents/Notes/kb" ]

chk "manifest path per profile" \
  [ "$(_kb_manifest super)" = "$CLAUDEFILES_CONFIG_DIR/managed-kb.super.json" ]

[ "$fails" -eq 0 ] && echo "PASS test-kb" || { echo "SOME test-kb CASES FAILED"; exit 1; }
