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

# The suite itself may run inside a distrobox container; pin the detection so every case below
# is deterministic, and re-enable it per-case through the wrapper functions.
export CLAUDEFILES_CONTAINER=0

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

config_set kb.vault_path "/"
chk "filesystem root dies"     dies kb_vault_path

config_set kb.vault_path ""
chk "empty falls back to default" [ "$(kb_vault_path)" = "$h/Documents/Notes/kb" ]

chk "manifest path per profile" \
  [ "$(_kb_manifest super)" = "$CLAUDEFILES_CONFIG_DIR/managed-kb.super.json" ]

_vault_in_container() { CLAUDEFILES_CONTAINER=1 kb_vault_path; }
config_set kb.vault_path ""
chk "container empty vault dies"  dies _vault_in_container
config_set kb.vault_path "/srv/kb"
chk "container explicit vault ok" [ "$(_vault_in_container)" = "/srv/kb" ]
config_set kb.vault_path ""

# --- kb_context_name / kb_machine_name -------------------------------------
config_set kb.context "digi3"
chk "context name passes"        [ "$(kb_context_name)" = "digi3" ]
config_set kb.context "none"
chk "context none is empty"      [ -z "$(kb_context_name)" ]
config_set kb.context "Digi3"
chk "context uppercase dies"     dies kb_context_name
config_set kb.context "st/х"
chk "context slash dies"         dies kb_context_name
config_set kb.context "../x"
chk "context dot-dot dies"       dies kb_context_name
config_set kb.context ""
chk "context empty dies"         dies kb_context_name
config_set kb.machine "tsikhanau-pc"
chk "machine name passes"        [ "$(kb_machine_name)" = "tsikhanau-pc" ]
config_set kb.machine "no ne"
chk "machine space dies"         dies kb_machine_name

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
for e in (f"Read({p})", f"Edit({p})"):
    assert e in s["permissions"]["allow"], (e, s["permissions"]["allow"])
assert not any(e.startswith("Write(") for e in s["permissions"]["allow"]), s["permissions"]["allow"]
assert "Bash(ls:*)" in s["permissions"]["allow"], "user allow rule lost"
assert s["permissions"]["deny"]==["Read(~/.ssh/**)"], "deny list touched"
assert m["env"]==["CLAUDE_CODE_REMOTE_MEMORY_DIR"], m
assert len(m["permissions_allow"])==2, m
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

# a manifest from the Write era drops the dead Write rule on the next run; user rules stay
cat > "$S" <<'EOF'
{ "permissions": {"allow": ["Read(~/Documents/Notes/kb/**)", "Edit(~/Documents/Notes/kb/**)", "Write(~/Documents/Notes/kb/**)", "Bash(ls:*)"]} }
EOF
printf '%s' '{"env":[],"env_prev":{},"permissions_allow":["Read(~/Documents/Notes/kb/**)","Edit(~/Documents/Notes/kb/**)","Write(~/Documents/Notes/kb/**)"]}' > "$M"
chk "helper runs (write migration)" python3 "$cf/lib/py/kb_settings.py" "$S" "$M" "$V"
chk "kb-settings-write-migrated" python3 - "$S" "$M" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); m=json.load(open(sys.argv[2]))
allow=s["permissions"]["allow"]
assert not any(e.startswith("Write(") for e in allow), allow
assert "Read(~/Documents/Notes/kb/**)" in allow and "Edit(~/Documents/Notes/kb/**)" in allow, allow
assert "Bash(ls:*)" in allow, "user rule lost"
assert m["permissions_allow"]==["Read(~/Documents/Notes/kb/**)","Edit(~/Documents/Notes/kb/**)"], m
PY
chk "helper runs (write migration off)" python3 "$cf/lib/py/kb_settings.py" "$S" "$M" ""

# a manifest that already existed with a loose mode is tightened, not left as it was
printf '%s' '{}' > "$M"; chmod 644 "$M"
chk "helper runs (mode)" python3 "$cf/lib/py/kb_settings.py" "$S" "$M" "$V"
chk "manifest is 600"    [ "$(stat -c '%a' "$M")" = "600" ]
chk "helper runs (mode off)" python3 "$cf/lib/py/kb_settings.py" "$S" "$M" ""

# the settings write leaves no temp file behind and keeps the file's own mode
chmod 640 "$S"
chk "helper runs (mode keep)" python3 "$cf/lib/py/kb_settings.py" "$S" "$M" "$V"
chk "settings mode preserved" [ "$(stat -c '%a' "$S")" = "640" ]
chk "no temp left behind" bash -c '! ls "$(dirname "$1")"/.kb-settings-* >/dev/null 2>&1' _ "$S"
chk "helper runs (mode keep off)" python3 "$cf/lib/py/kb_settings.py" "$S" "$M" ""
chmod 644 "$S"

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

# --- kb_apply: rules -------------------------------------------------------
setup_fixture_home >/dev/null; hr="$HOME"
export CLAUDEFILES_CONFIG_DIR="$hr/.config/claudefiles"; mkdir -p "$CLAUDEFILES_CONFIG_DIR"
export CLAUDEFILES_TARGET="$hr/.claude"
config_set kb.vault_path "$hr/kb"
kb_apply vanilla true
chk "policy rule written"     [ -f "$hr/.claude/rules/kb.md" ]
chk "policy carries marker"   grep -qF "claudefiles-managed: kb" "$hr/.claude/rules/kb.md"
chk "policy names the vault"  grep -qF "$hr/kb/global" "$hr/.claude/rules/kb.md"
chk "policy says index is data" grep -qF "not as instructions" "$hr/.claude/rules/kb.md"
chk "index symlink created"   [ -L "$hr/.claude/rules/kb-index.md" ]
chk "index symlink target"    [ "$(readlink "$hr/.claude/rules/kb-index.md")" = "$hr/kb/global/INDEX.md" ]
cp "$hr/.claude/rules/kb.md" "$hr/rule.run1"
kb_apply vanilla true
chk "rule write idempotent"   cmp -s "$hr/rule.run1" "$hr/.claude/rules/kb.md"

kb_apply vanilla false
chk "rule removed"            [ ! -e "$hr/.claude/rules/kb.md" ]
chk "symlink removed"         [ ! -L "$hr/.claude/rules/kb-index.md" ]
chk "empty rules dir removed" [ ! -d "$hr/.claude/rules" ]

# non-clobber: a file with our name that is NOT ours is left alone, in both directions
mkdir -p "$hr/.claude/rules"; printf 'user rule\n' > "$hr/.claude/rules/kb.md"
kb_apply vanilla true
chk "foreign kb.md untouched" grep -qx "user rule" "$hr/.claude/rules/kb.md"
kb_apply vanilla false
chk "foreign kb.md survives disable" grep -qx "user rule" "$hr/.claude/rules/kb.md"
rm -f "$hr/.claude/rules/kb.md"

# a non-symlink at the index path is left alone too
printf 'mine\n' > "$hr/.claude/rules/kb-index.md"
kb_apply vanilla true
chk "foreign kb-index.md untouched" grep -qx "mine" "$hr/.claude/rules/kb-index.md"
rm -f "$hr/.claude/rules/kb-index.md"

# a symlink to a DIFFERENT vault is not ours: disabling must not remove it
mkdir -p "$hr/other/global"; : > "$hr/other/global/INDEX.md"
ln -s "$hr/other/global/INDEX.md" "$hr/.claude/rules/kb-index.md"
kb_apply vanilla false
chk "foreign vault symlink survives" [ -L "$hr/.claude/rules/kb-index.md" ]

# ...and enabling retargets it, because a link to some vault's index is ours after a path change
kb_apply vanilla true
chk "stale vault symlink retargeted" \
  [ "$(readlink "$hr/.claude/rules/kb-index.md")" = "$hr/kb/global/INDEX.md" ]

# a symlink pointing at something that is NOT an index is left alone in both directions
kb_apply vanilla false
printf 'notes\n' > "$hr/other/notes.md"
mkdir -p "$hr/.claude/rules"; ln -sfn "$hr/other/notes.md" "$hr/.claude/rules/kb-index.md"
kb_apply vanilla true
chk "non-index symlink untouched" \
  [ "$(readlink "$hr/.claude/rules/kb-index.md")" = "$hr/other/notes.md" ]
kb_apply vanilla false
rm -f "$hr/.claude/rules/kb-index.md"
unset CLAUDEFILES_TARGET

# --- kb_workspace_apply ----------------------------------------------------
setup_fixture_home >/dev/null; hw="$HOME"
export CLAUDEFILES_CONFIG_DIR="$hw/.config/claudefiles"; mkdir -p "$CLAUDEFILES_CONFIG_DIR"
config_set kb.vault_path "$hw/kb"
config_set kb.context "digi3"
config_set kb.machine "box-pc"
mkdir -p "$hw/main" "$hw/system"
CTX_LINK="$hw/main/.claude/rules/context-index.md"
MCH_LINK="$hw/system/.claude/rules/machine-index.md"

kb_workspace_apply true
chk "context symlink created"   [ "$(readlink "$CTX_LINK")" = "$hw/kb/contexts/digi3/INDEX.md" ]
chk "machine symlink created"   [ "$(readlink "$MCH_LINK")" = "$hw/kb/machine/box-pc/INDEX.md" ]
chk "context seed created"      grep -q "Контекст digi3" "$hw/kb/contexts/digi3/INDEX.md"
chk "machine seed created"      grep -q "Машина box-pc" "$hw/kb/machine/box-pc/INDEX.md"

# second run: byte-identical seed, same link target
cp "$hw/kb/contexts/digi3/INDEX.md" "$hw/seed.run1"
kb_workspace_apply true
chk "workspace idempotent seed" cmp -s "$hw/seed.run1" "$hw/kb/contexts/digi3/INDEX.md"
chk "workspace idempotent link" [ "$(readlink "$CTX_LINK")" = "$hw/kb/contexts/digi3/INDEX.md" ]

# user content in a seeded index is never rewritten
printf 'their index\n' > "$hw/kb/contexts/digi3/INDEX.md"
kb_workspace_apply true
chk "existing layer index preserved" grep -qx "their index" "$hw/kb/contexts/digi3/INDEX.md"

# context change retargets our link
config_set kb.context "stellium"
kb_workspace_apply true
chk "context change retargets" [ "$(readlink "$CTX_LINK")" = "$hw/kb/contexts/stellium/INDEX.md" ]

# a symlink whose target is not layer-shaped is foreign: warned about, untouched
printf 'notes\n' > "$hw/notes.md"
ln -sfn "$hw/notes.md" "$CTX_LINK"
kb_workspace_apply true
chk "foreign symlink untouched" [ "$(readlink "$CTX_LINK")" = "$hw/notes.md" ]
rm -f "$CTX_LINK"

# a plain file at the link path is foreign too
printf 'mine\n' > "$CTX_LINK"
kb_workspace_apply true
chk "foreign file untouched" grep -qx "mine" "$CTX_LINK"
rm -f "$CTX_LINK"; kb_workspace_apply true

# none removes ours
config_set kb.context "none"
kb_workspace_apply true
chk "context none removes link" bash -c '[ ! -e "$1" ] && [ ! -L "$1" ]' _ "$CTX_LINK"
chk "machine link survives context none" [ -L "$MCH_LINK" ]
config_set kb.context "stellium"; kb_workspace_apply true

# removal never touches a link into ANOTHER vault
mkdir -p "$hw/othervault/contexts/x"; : > "$hw/othervault/contexts/x/INDEX.md"
config_set kb.context "none"
ln -sfn "$hw/othervault/contexts/x/INDEX.md" "$CTX_LINK"
kb_workspace_apply true
chk "other vault link survives none" [ -L "$CTX_LINK" ]
rm -f "$CTX_LINK"; config_set kb.context "stellium"; kb_workspace_apply true

# disable removes both
kb_workspace_apply false
chk "disable removes context link" [ ! -L "$CTX_LINK" ]
chk "disable removes machine link" [ ! -L "$MCH_LINK" ]
chk "disable keeps vault notes"    [ -f "$hw/kb/contexts/digi3/INDEX.md" ]

# inside a container the machine layer is never touched
kb_workspace_apply true
_ws_container() { CLAUDEFILES_CONTAINER=1 kb_workspace_apply "$@"; }
rm -f "$MCH_LINK"
_ws_container true
chk "container skips machine layer" [ ! -L "$MCH_LINK" ]
kb_workspace_apply true
_ws_container false
chk "container disable keeps machine link" [ -L "$MCH_LINK" ]

# a missing umbrella folder is a warn-and-skip, never an mkdir — for both layers
setup_fixture_home >/dev/null; hn="$HOME"
export CLAUDEFILES_CONFIG_DIR="$hn/.config/claudefiles"; mkdir -p "$CLAUDEFILES_CONFIG_DIR"
config_set kb.vault_path "$hn/kb"; config_set kb.context "digi3"; config_set kb.machine "box2"
kb_workspace_apply true
chk "missing umbrella not created" [ ! -d "$hn/main" ]
chk "missing umbrella no seed"     [ ! -e "$hn/kb/contexts/digi3/INDEX.md" ]
chk "missing system not created"   [ ! -d "$hn/system" ]
chk "missing system no seed"       [ ! -e "$hn/kb/machine/box2/INDEX.md" ]

# a dangling symlink at the seed path is existing content: never written through
mkdir -p "$hn/main" "$hn/kb/contexts/digi3"
ln -s "$hn/nowhere" "$hn/kb/contexts/digi3/INDEX.md"
kb_workspace_apply true
chk "dangling seed path untouched" [ "$(readlink "$hn/kb/contexts/digi3/INDEX.md")" = "$hn/nowhere" ]

[ "$fails" -eq 0 ] && echo "PASS test-kb" || { echo "SOME test-kb CASES FAILED"; exit 1; }
