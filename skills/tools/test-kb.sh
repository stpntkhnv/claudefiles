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

# --- kb_settings.py --------------------------------------------------------
setup_fixture_home >/dev/null; hs="$HOME"
export CLAUDEFILES_CONFIG_DIR="$hs/.config/claudefiles"; mkdir -p "$CLAUDEFILES_CONFIG_DIR"
S="$hs/.claude/settings.json"; M="$(_kb_manifest vanilla)"
V="$hs/Documents/Notes/kb"
cat > "$S" <<'EOF'
{ "theme": "auto",
  "env": {"MY_OWN_VAR": "keep"},
  "permissions": {"allow": ["Bash(ls:*)"], "deny": ["Read(~/.ssh/**)"]} }
EOF
chk "helper runs" python3 "$cf/lib/py/kb_settings.py" "$S" "$M" "$V"
chk "kb-settings-on" python3 - "$S" "$M" "$V" "$hs" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); m=json.load(open(sys.argv[2])); v=sys.argv[3]
assert s["env"]["CLAUDE_CODE_REMOTE_MEMORY_DIR"]==v, s["env"]
assert s["env"]["MY_OWN_VAR"]=="keep", "user env var lost"
assert s["theme"]=="auto", "unrelated key lost"
p="~/Documents/Notes/kb/**"
for e in (f"Read({p})", f"Edit({p})", f"Write({p})"):
    assert e in s["permissions"]["allow"], (e, s["permissions"]["allow"])
assert "Bash(ls:*)" in s["permissions"]["allow"], "user allow rule lost"
assert s["permissions"]["deny"]==["Read(~/.ssh/**)"], "deny list touched"
assert m["env"]==["CLAUDE_CODE_REMOTE_MEMORY_DIR"], m
assert len(m["permissions_allow"])==3, m
PY
chk "settings write is idempotent" bash -c '
  cp "$1" "$1.run1"; python3 "$2" "$1" "$3" "$4"; cmp -s "$1.run1" "$1"' _ "$S" "$cf/lib/py/kb_settings.py" "$M" "$V"

# vault outside $HOME -> absolute // pattern
chk "helper runs (outside home)" python3 "$cf/lib/py/kb_settings.py" "$S" "$M" "/srv/kb"
chk "kb-settings-outside-home" python3 - "$S" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert "Read(//srv/kb/**)" in s["permissions"]["allow"], s["permissions"]["allow"]
assert not [e for e in s["permissions"]["allow"] if "Documents/Notes/kb" in e], "stale vault rules kept"
PY

# off: our entries go, the user's stay, the manifest is gone
chk "helper runs (off)" python3 "$cf/lib/py/kb_settings.py" "$S" "$M" ""
chk "kb-settings-off" python3 - "$S" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert "CLAUDE_CODE_REMOTE_MEMORY_DIR" not in s.get("env",{}), s.get("env")
assert s["env"]["MY_OWN_VAR"]=="keep", "user env var lost on disable"
assert s["permissions"]["allow"]==["Bash(ls:*)"], s["permissions"]["allow"]
PY
chk "manifest removed on disable" [ ! -e "$M" ]

# no vault and no manifest: the file is not touched at all (not even reformatted)
printf '%s' '{"theme":"auto","env":{"X":"1"}}' > "$S"
cp "$S" "$S.untouched"
chk "helper runs (no-op)" python3 "$cf/lib/py/kb_settings.py" "$S" "$M" ""
chk "kb-settings-noop-does-not-rewrite" cmp -s "$S.untouched" "$S"

# a rule the USER wrote that happens to equal ours is never claimed and never removed
cat > "$S" <<'EOF'
{ "permissions": {"allow": ["Write(~/Documents/Notes/kb/**)"]} }
EOF
chk "helper runs (user rule on)"  python3 "$cf/lib/py/kb_settings.py" "$S" "$M" "$V"
chk "helper runs (user rule off)" python3 "$cf/lib/py/kb_settings.py" "$S" "$M" ""
chk "kb-settings-user-rule-survives" python3 - "$S" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert s["permissions"]["allow"]==["Write(~/Documents/Notes/kb/**)"], s["permissions"]["allow"]
PY

# an env value the USER set for the same key is restored on disable, not deleted
printf '%s' '{"env":{"CLAUDE_CODE_REMOTE_MEMORY_DIR":"/user/own/store"}}' > "$S"
chk "helper runs (user env on)"  python3 "$cf/lib/py/kb_settings.py" "$S" "$M" "$V"
chk "helper runs (user env off)" python3 "$cf/lib/py/kb_settings.py" "$S" "$M" ""
chk "kb-settings-user-env-restored" python3 - "$S" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert s["env"]["CLAUDE_CODE_REMOTE_MEMORY_DIR"]=="/user/own/store", s.get("env")
PY

# empty containers are pruned, not left as {}: a disabled feature leaves no trace
printf '%s' '{"theme":"auto"}' > "$S"
chk "helper runs (prune on)"  python3 "$cf/lib/py/kb_settings.py" "$S" "$M" "$V"
chk "helper runs (prune off)" python3 "$cf/lib/py/kb_settings.py" "$S" "$M" ""
chk "kb-settings-pruned" python3 - "$S" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert "env" not in s and "permissions" not in s, s
PY

# --- kb_apply: vault skeleton + settings ------------------------------------
setup_fixture_home >/dev/null; ha="$HOME"
export CLAUDEFILES_CONFIG_DIR="$ha/.config/claudefiles"; mkdir -p "$CLAUDEFILES_CONFIG_DIR"
export CLAUDEFILES_TARGET="$ha/.claude"
config_set kb.vault_path "$ha/kb"
kb_apply vanilla true
chk "vault projects dir"     [ -d "$ha/kb/projects" ]
chk "vault global index"     [ -f "$ha/kb/global/INDEX.md" ]
chk "vault readme"           [ -f "$ha/kb/README.md" ]
chk "settings env written"   bash -c 'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d[\"env\"][\"CLAUDE_CODE_REMOTE_MEMORY_DIR\"]==sys.argv[2] else 1)" "$1" "$2"' _ "$ha/.claude/settings.json" "$ha/kb"

# user content in the vault is never rewritten
printf 'my index\n' > "$ha/kb/global/INDEX.md"
kb_apply vanilla true
chk "existing index preserved" grep -qx "my index" "$ha/kb/global/INDEX.md"

# second run is byte-identical everywhere
cp "$ha/.claude/settings.json" "$ha/settings.run1"
kb_apply vanilla true
chk "kb_apply idempotent"    cmp -s "$ha/settings.run1" "$ha/.claude/settings.json"

# disable leaves the vault alone but cleans the profile
kb_apply vanilla false
chk "vault survives disable" [ -f "$ha/kb/global/INDEX.md" ]
chk "env entry gone"         bash -c '! grep -q CLAUDE_CODE_REMOTE_MEMORY_DIR "$1"' _ "$ha/.claude/settings.json"
unset CLAUDEFILES_TARGET

[ "$fails" -eq 0 ] && echo "PASS test-kb" || { echo "SOME test-kb CASES FAILED"; exit 1; }
