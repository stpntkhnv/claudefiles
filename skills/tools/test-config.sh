#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null
source "$cf/lib/common.sh"; source "$cf/lib/config.sh"

# secret string persist + read back
printf 'sekret' | CLAUDEFILES_ASSUME_TTY=1 config_ensure context7_api_key "key?" --secret
[ "$(config_get context7_api_key)" = "sekret" ] || { echo "FAIL read-back"; exit 1; }
# file is chmod 600
perm="$(stat -c '%a' "$(config_path)")"; [ "$perm" = "600" ] || { echo "FAIL perms $perm"; exit 1; }

# booleans round-trip as JSON bools -> config_flag reads them (finding 1)
config_set_bool flags.context7 true
[ "$(config_flag context7)" = true ] || { echo "FAIL flag true"; exit 1; }
config_set_bool flags.playwright false
[ "$(config_flag playwright)" = false ] || { echo "FAIL flag false"; exit 1; }
# a false flag must read as the literal "false" (never Python's "False") so build_servers sees it falsy
[ "$(config_get flags.playwright)" = "false" ] || { echo "FAIL bool literal"; exit 1; }
config_set_bool flags.codex_review true
[ "$(config_flag codex_review)" = true ]  || { echo "FAIL codex_review flag"; exit 1; }
config_set_bool flags.codex_plugin false
[ "$(config_flag codex_plugin)" = false ] || { echo "FAIL codex_plugin flag"; exit 1; }

# config_has distinguishes present-but-empty from absent (finding 2)
config_set ado.email ""
config_has ado.email || { echo "FAIL has present-empty"; exit 1; }
config_has ado.nope  && { echo "FAIL has absent"; exit 1; }

# optional key: present-empty is a no-op even without a TTY (does NOT die, does NOT re-ask)
CLAUDEFILES_ASSUME_TTY=0 config_ensure_optional context7_api_key "key?" --secret
[ "$(config_get context7_api_key)" = "sekret" ] || { echo "FAIL optional clobbered"; exit 1; }

# array setter trims and drops empties
config_set_array ado.orgs "a, b ,c,"
[ "$(config_get ado.orgs)" = '["a", "b", "c"]' ] || { echo "FAIL array"; exit 1; }

# required string still fails fast without TTY (does not hang)
# NOTE: wrapped in a subshell — config_ensure's failure path calls common.sh's
# die(), which does a hard `exit`. Without the subshell, that exit would kill
# this whole test script (bash runs an `if COND` command in the current shell,
# not a subshell), so we'd never reach the PASS line even on correct behavior.
if (CLAUDEFILES_ASSUME_TTY=0 config_ensure ado.pat.a "pat?") 2>/dev/null; then
  echo "FAIL should have errored without TTY"; exit 1; fi
echo "PASS test-config"
