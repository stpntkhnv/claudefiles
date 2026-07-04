# claudefiles Config Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the standalone `claudefiles` repo own the entire `~/.claude` configuration via one idempotent `setup.sh`, and shrink chezmoi to installing the `claude` CLI plus pulling and triggering claudefiles.

**Architecture:** `setup.sh` orchestrates focused `lib/*.sh` modules (config/secrets, settings.json, skills, plugins, MCP, hooks), each independently testable against a fake `claude` CLI and a fixture `$HOME`. chezmoi gains a `git-repo` external (public https) that clones the deploy copy and a plain `run_after_` script that HEAD-compares and runs `setup.sh`. Secrets are collected by claudefiles itself into a gitignored JSON store; nothing secret is ever committed.

**Tech Stack:** bash, python3 (stdlib `json` only — no third-party deps), GNU coreutils/awk, git, chezmoi (go-template), Claude Code CLI (`claude`).

## Repos referenced

- **`$CF`** — the claudefiles working checkout. After Task 1 this is `~/dev/claudefiles` (currently `~/devTools`). All `claude/…`, `lib/…`, `skills/…`, `setup.sh`, `docs/…` paths are relative to `$CF`.
- **`$CH`** — the chezmoi source dir `~/.local/share/chezmoi/home`. Tasks 9–11 touch this.

## Global Constraints

- No third-party language deps: bash + python3 **stdlib only** (`json`), GNU coreutils/awk, git.
- **No secret ever in a tracked file.** Secrets live only under `~/.config/claudefiles/` — `secrets.json` (the source) and `managed-mcp.json` (the MCP manifest, which embeds base64 ADO PATs for change-detection); both are written `chmod 600` and are outside the repo. A test enforces nothing secret-bearing is tracked; the repo is **public**.
- **No hardcoded `/home/<user>`.** Use `$HOME`; derive the hook path from the running repo's location.
- Every module is **idempotent**: safe to re-run; `setup.sh` run twice produces no diff and exits 0.
- **TTY rule:** prompt for missing secrets only when a TTY is present; without a TTY, fail fast listing missing keys — never hang.
- Deploy copy: `~/.local/share/claudefiles`. Dev checkout: `~/dev/claudefiles`. Repo: `https://github.com/stpntkhnv/claudefiles.git` (public).
- Managed `settings.json` keys (replaced wholesale): `hooks`, `enabledPlugins`, `extraKnownMarketplaces`, `model`, `effortLevel`, `tui`, `theme`. Unknown top-level keys preserved. `settings.local.json` never touched.
- TDD: failing test first, minimal code, commit per task. **Every commit** ends with the trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`; the `git commit -m "…"` examples below abbreviate it — append it as a second `-m` line on each real commit.
- **Flag typing:** feature flags (`flags.*`) are stored as real JSON booleans, never strings. `config_io.py` emits them lowercase (`true`/`false`) so bash and python agree; `build_servers.py` still coerces defensively.

---

## File structure (created/modified)

```
$CF/setup.sh                         # MODIFY — thin orchestrator over lib/*
$CF/lib/common.sh                    # CREATE — shared helpers (log, require_cmd, claude_bin)
$CF/lib/config.sh                    # CREATE — secrets.json load/prompt/persist (TTY)
$CF/lib/settings.sh                  # CREATE — render/merge ~/.claude/settings.json
$CF/lib/skills.sh                    # CREATE — install context7-mcp + dotnet-router + catalog
$CF/lib/plugins.sh                   # CREATE — idempotent plugin install
$CF/lib/mcp.sh                       # CREATE — MCP reconcile via managed-mcp.json manifest
$CF/lib/hooks.sh                     # CREATE — SessionStart hook path wiring
$CF/claude/settings/settings.template.json   # CREATE — managed-key template
$CF/claude/skills/context7-mcp/SKILL.md      # CREATE — moved from ~/.claude (chezmoi drops it)
$CF/claude/mcp/build_servers.py      # CREATE — build MCP server dict from secrets.json
$CF/lib/py/jsonmerge.py              # CREATE — settings.json managed-key merge
$CF/lib/py/config_io.py              # CREATE — secrets.json get/set/validate
$CF/skills/tools/lib/faketools.bash  # CREATE — test harness: fake `claude`, fixture HOME
$CF/skills/tools/test-config.sh      # CREATE
$CF/skills/tools/test-settings.sh    # CREATE
$CF/skills/tools/test-plugins.sh     # CREATE
$CF/skills/tools/test-mcp.sh         # CREATE
$CF/skills/tools/test-setup-idempotent.sh    # CREATE
$CF/skills/tools/test-secrets-not-tracked.sh # CREATE
$CH/.chezmoiexternal.toml            # MODIFY — add claudefiles git-repo external
$CH/run_after_setup-claudefiles.sh.tmpl      # CREATE — HEAD-compare trigger
$CH/.chezmoi.toml.tmpl               # MODIFY — strip Claude-config prompts
$CH/run_onchange_after_configure-claude-plugins.sh.tmpl  # DELETE
$CH/run_onchange_after_configure-claude-mcp.sh.tmpl      # DELETE
$CH/.chezmoitemplates/mcp-servers    # DELETE
$CH/dot_claude/skills/brainstorming  # DELETE (superpowers plugin already provides it)
```

---

## Task 1: Rename checkout, fix stale refs, scaffold test harness

**Files:**
- Move: `~/devTools` → `~/dev/claudefiles` (the working checkout `$CF`)
- Modify: `$CF/README.md` (title + clone URL), `$CF/claude/skills/dotnet-router/SKILL.md` (Maintenance section)
- Create: `$CF/lib/common.sh`, `$CF/skills/tools/lib/faketools.bash`
- Modify: `$CF/.gitignore`

**Interfaces:**
- Produces: `faketools.bash` exports `setup_fixture_home()` (sets/exports `$HOME` to a temp dir; **must be called directly — `setup_fixture_home >/dev/null; h="$HOME"` — not via `$(...)`**, which would run it in a subshell and lose the exports), `fake_claude_calls()` (path to the log file the fake `claude` appends every invocation to), and puts a **stateful** fake `claude` on `$PATH` (it remembers installed plugins / added marketplaces / added MCP servers, dedups on write, and reflects them in `list` output, so re-runs are true no-ops). `common.sh` exports `log()`, `warn()`, `die()`, `require_cmd <name>`, `claude_bin()` (echoes resolved claude path).

- [ ] **Step 1: Move the checkout and confirm git survives**

```bash
mkdir -p ~/dev
mv ~/devTools ~/dev/claudefiles
cd ~/dev/claudefiles && git status && git branch --show-current   # feat/claudefiles-config-ownership, clean
```

- [ ] **Step 2: Fix stale references (README title/URL + SKILL Maintenance)**

In `$CF/README.md` replace the title `# claudefiles` block's clone line to the public https URL and drop any `ado-mcp`/`devTools` wording. In `$CF/claude/skills/dotnet-router/SKILL.md`, the `## Maintenance` section: replace "the claudefiles repo (this skill's directory is `claude/skills/dotnet-router/` inside that repo … `setup.sh` at the repo root)" so it names `~/dev/claudefiles` and drops `ado-mcp`.

```bash
cd ~/dev/claudefiles
grep -rn 'ado-mcp\|devTools' README.md claude/skills/dotnet-router/SKILL.md   # expect: no matches after edit
```

- [ ] **Step 3: Write the test harness**

Create `$CF/skills/tools/lib/faketools.bash`:

```bash
# faketools.bash — test scaffolding: fixture HOME + a STATEFUL fake `claude` CLI.
# It logs every invocation (so tests can assert the commands setup.sh issues) AND
# remembers installed plugins / added marketplaces / added MCP servers, reflecting
# them back in `list` output — so a second setup run is a genuine no-op (finding 7).
#
# USAGE: call it DIRECTLY so its exports reach your shell, then read $HOME:
#     setup_fixture_home >/dev/null; h="$HOME"
# Do NOT write  h="$(setup_fixture_home)"  — command substitution runs it in a
# subshell, so the HOME/PATH/CLAUDE_FAKE_* exports never reach the caller and the
# functions under test would touch your REAL ~/.claude.
setup_fixture_home() {
  local h; h="$(mktemp -d)"
  mkdir -p "$h/.claude" "$h/.config"
  export HOME="$h"
  export CLAUDE_FAKE_LOG="$h/.claude-calls.log"; : > "$CLAUDE_FAKE_LOG"
  export CLAUDE_FAKE_STATE="$h/.claude-state"; mkdir -p "$CLAUDE_FAKE_STATE"
  : > "$CLAUDE_FAKE_STATE/plugins"; : > "$CLAUDE_FAKE_STATE/marketplaces"; : > "$CLAUDE_FAKE_STATE/mcp"
  local bin="$h/bin"; mkdir -p "$bin"
  cat > "$bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CLAUDE_FAKE_LOG"
S="$CLAUDE_FAKE_STATE"
case "$1 $2" in
  "plugin list")        cat "$S/plugins" 2>/dev/null ;;
  "plugin marketplace")                                   # add <name> | list
    if [ "$3" = "add" ];  then grep -qxF "$4" "$S/marketplaces" 2>/dev/null || printf '%s\n' "$4" >> "$S/marketplaces"
    elif [ "$3" = "list" ]; then cat "$S/marketplaces" 2>/dev/null; fi ;;
  "plugin install")     grep -qxF "$3" "$S/plugins" 2>/dev/null || printf '%s\n' "$3" >> "$S/plugins" ;;
  "mcp list")           cat "$S/mcp" 2>/dev/null ;;
  "mcp add-json")       grep -qxF "$5" "$S/mcp" 2>/dev/null || printf '%s\n' "$5" >> "$S/mcp" ;;   # add-json --scope user NAME JSON; dedup so re-add is a no-op
  "mcp remove")                                            # mcp remove --scope user NAME
    grep -vxF "$5" "$S/mcp" > "$S/mcp.tmp" 2>/dev/null || true; mv "$S/mcp.tmp" "$S/mcp" 2>/dev/null || true ;;
  *) : ;;
esac
exit 0
EOF
  chmod +x "$bin/claude"
  export PATH="$bin:$PATH"
  hash -r 2>/dev/null || true   # drop any cached real-claude path so the fake wins
  echo "$h"
}
fake_claude_calls() { echo "$CLAUDE_FAKE_LOG"; }
```

Create `$CF/lib/common.sh`:

```bash
# common.sh — shared helpers for setup.sh modules. Source, don't execute.
log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
claude_bin() { command -v claude 2>/dev/null || echo "$HOME/.npm-global/bin/claude"; }
```

- [ ] **Step 4: Ignore the runtime stores**

Append to `$CF/.gitignore`:

```
# runtime, never tracked
/lib/py/__pycache__/
```

(The secret store lives at `~/.config/claudefiles/`, outside the repo, so it needs no repo-level ignore — Task 12's test proves nothing secret is tracked.)

- [ ] **Step 5: Commit**

```bash
cd ~/dev/claudefiles
git add -A
git commit -m "chore: rename checkout to ~/dev/claudefiles, fix stale refs, add test harness"
```

---

## Task 2: `lib/config.sh` — secrets store (load / prompt / persist)

**Files:**
- Create: `$CF/lib/config.sh`, `$CF/lib/py/config_io.py`
- Test: `$CF/skills/tools/test-config.sh`

**Interfaces:**
- Consumes: `common.sh`.
- Produces:
  - `config_path()` → `$HOME/.config/claudefiles/secrets.json`
  - `config_get <key>` → value or empty (booleans emitted lowercase `true`/`false`, arrays as JSON)
  - `config_has <key>` → exit 0 if the key **exists** (even if empty), 1 if absent — the presence test that distinguishes "free-tier empty key" from "never asked"
  - `config_set <key> <str>` / `config_set_bool <key> <true|false>` / `config_set_array <key> <csv>` — typed writers (bool stored as JSON boolean; validated)
  - `config_flag <name>` → `true`/`false` (default `false` when unset)
  - `config_ensure <key> <prompt> [--secret]` → **required** string; prompts (TTY) or `die`s (no TTY); empty is rejected
  - `config_ensure_optional <key> <prompt> [--secret]` → prompts **once** (`config_has` gate); empty is valid and remembered; no-TTY records empty without failing
  - `config_ensure_flag <name> <prompt>` → prompts once for a boolean, persists as JSON bool
  - Schema: `{flags:{context7,playwright,azure_mcp,ado,dotnet_skills}, context7_api_key, ado:{email,orgs:[],pat:{}}, playwright:{chromium_path?}}`.

- [ ] **Step 1: Write the failing test**

`$CF/skills/tools/test-config.sh`:

```bash
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
if (CLAUDEFILES_ASSUME_TTY=0 config_ensure ado.pat.a "pat?") 2>/dev/null; then   # subshell: die's exit must not kill this script
  echo "FAIL should have errored without TTY"; exit 1; fi
echo "PASS test-config"
```

- [ ] **Step 2: Run it, expect failure**

Run: `bash skills/tools/test-config.sh`
Expected: FAIL (`config.sh` / functions not defined).

- [ ] **Step 3: Implement `config_io.py`**

`$CF/lib/py/config_io.py`:

```python
#!/usr/bin/env python3
"""get/set/has dotted keys in secrets.json. Never executed as a shell file.
Ops: get <key>            -> prints scalar (bool as lowercase true/false, list as JSON)
     has <key>            -> exit 0 if key present (even if empty), else exit 1
     set <key> <str>      -> store a string
     setbool <key> <t|f>  -> store a real JSON boolean (validated)
     setarray <key> <csv> -> store a trimmed, non-empty list"""
import json, os, sys

def load(path):
    try:
        with open(path) as f: return json.load(f)
    except FileNotFoundError:
        return {}

def walk(d, dotted):          # -> (found, value)
    cur = d
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return (False, "")
        cur = cur[part]
    return (True, cur)

def setk(d, dotted, value):
    cur = d
    parts = dotted.split(".")
    for part in parts[:-1]:
        cur = cur.setdefault(part, {})
    cur[parts[-1]] = value
    return d

def emit(v):
    if isinstance(v, bool):        print("true" if v else "false")   # NOT Python's True/False
    elif isinstance(v, (dict, list)): print(json.dumps(v))
    elif v is None:                print("")
    else:                          print(v)

def persist(d, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f: json.dump(d, f, indent=2)
    os.chmod(path, 0o600)

if __name__ == "__main__":
    op, path = sys.argv[1], sys.argv[2]
    d = load(path)
    if op == "get":
        found, v = walk(d, sys.argv[3]); emit(v if found else "")
    elif op == "has":
        found, _ = walk(d, sys.argv[3]); sys.exit(0 if found else 1)
    elif op == "set":
        setk(d, sys.argv[3], sys.argv[4]); persist(d, path)
    elif op == "setbool":
        val = sys.argv[4].strip().lower()
        if val not in ("true", "false"):
            sys.stderr.write(f"setbool expects true|false, got {sys.argv[4]!r}\n"); sys.exit(2)
        setk(d, sys.argv[3], val == "true"); persist(d, path)
    elif op == "setarray":
        items = [s.strip() for s in sys.argv[4].split(",") if s.strip()]
        setk(d, sys.argv[3], items); persist(d, path)
    else:
        sys.stderr.write(f"unknown op {op}\n"); sys.exit(2)
```

- [ ] **Step 4: Implement `config.sh`**

`$CF/lib/config.sh`:

```bash
# config.sh — secrets.json accessors with TTY-aware prompting.
CLAUDEFILES_CONFIG_DIR="${CLAUDEFILES_CONFIG_DIR:-$HOME/.config/claudefiles}"
_CFG_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/config_io.py"
config_path()      { echo "$CLAUDEFILES_CONFIG_DIR/secrets.json"; }
config_get()       { python3 "$_CFG_PY" get      "$(config_path)" "$1"; }
config_has()       { python3 "$_CFG_PY" has      "$(config_path)" "$1"; }   # exit 0 if key present
config_set()       { python3 "$_CFG_PY" set      "$(config_path)" "$1" "$2"; }
config_set_bool()  { python3 "$_CFG_PY" setbool  "$(config_path)" "$1" "$2"; }
config_set_array() { python3 "$_CFG_PY" setarray "$(config_path)" "$1" "$2"; }

_has_tty() { [ "${CLAUDEFILES_ASSUME_TTY:-}" = "1" ] && return 0
             [ "${CLAUDEFILES_ASSUME_TTY:-}" = "0" ] && return 1
             [ -t 0 ]; }

# flags are real JSON booleans; get emits them lowercase so this compare works.
config_flag() { [ "$(config_get "flags.$1")" = "true" ] && echo true || echo false; }

config_ensure() { # config_ensure <key> <prompt> [--secret] — REQUIRED string, empty rejected
  local key="$1" prompt="$2" secret="${3:-}" cur; cur="$(config_get "$key")"
  [ -n "$cur" ] && return 0
  if _has_tty; then
    local val
    if [ "$secret" = "--secret" ]; then read -rs -p "$prompt " val || true; echo; else read -r -p "$prompt " val || true; fi   # read exits 1 on EOF-without-newline but still assigns; keep set -e happy
    config_set "$key" "$val"
  else
    die "missing required config '$key' and no TTY to prompt (set it in $(config_path))"
  fi
}

config_ensure_optional() { # <key> <prompt> [--secret] — ask ONCE; empty is valid + remembered
  local key="$1" prompt="$2" secret="${3:-}"
  config_has "$key" && return 0                 # already asked (even if stored empty) -> never re-ask
  if _has_tty; then
    local val
    if [ "$secret" = "--secret" ]; then read -rs -p "$prompt " val || true; echo; else read -r -p "$prompt " val || true; fi   # read exits 1 on EOF-without-newline but still assigns; keep set -e happy
    config_set "$key" "$val"                     # persists "" too -> config_has true next run
  else
    config_set "$key" ""                         # no TTY: record empty, do not fail (optional)
  fi
}

config_ensure_flag() { # <name> <prompt> — ask ONCE for a boolean, persist as JSON bool
  local name="$1" prompt="$2"
  config_has "flags.$name" && return 0
  if _has_tty; then
    local val; read -r -p "$prompt " val || true   # EOF-without-newline still assigns
    case "${val,,}" in y|yes|true|1) val=true ;; *) val=false ;; esac
    config_set_bool "flags.$name" "$val"
  else
    die "missing required flag 'flags.$name' and no TTY to prompt (set it in $(config_path))"
  fi
}
```

- [ ] **Step 5: Run the test, expect PASS**

Run: `bash skills/tools/test-config.sh` → `PASS test-config`

- [ ] **Step 6: Commit**

```bash
git add lib/config.sh lib/py/config_io.py skills/tools/test-config.sh
git commit -m "feat: secrets.json store with TTY-aware prompting"
```

---

## Task 3: `lib/settings.sh` — render/merge `settings.json`

**Files:**
- Create: `$CF/lib/settings.sh`, `$CF/lib/py/jsonmerge.py`, `$CF/claude/settings/settings.template.json`
- Test: `$CF/skills/tools/test-settings.sh`

**Interfaces:**
- Consumes: `common.sh`.
- Produces: `settings_apply <hook_abs_path> <dotnet_enabled:true|false>` — writes `~/.claude/settings.json` replacing managed keys from the template (with `<HOOK_PATH>` substituted), preserving unknown top-level keys from any existing file. When `dotnet_enabled` is `false`, the dotnet plugin entry **and** its marketplace are dropped so settings.json stays consistent with what `plugins_apply` actually installed (finding 6).

- [ ] **Step 1: Write the failing test**

`$CF/skills/tools/test-settings.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
source "$cf/lib/common.sh"; source "$cf/lib/settings.sh"

# pre-existing settings with a STALE hook and an UNKNOWN key that must survive
cat > "$h/.claude/settings.json" <<'EOF'
{ "hooks": {"SessionStart":[{"hooks":[{"type":"command","command":"/old/stale/path.sh"}]}]},
  "myCustomKey": {"keep":"me"} }
EOF
settings_apply "/new/hook/detect-dotnet.sh" true
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert d["myCustomKey"]=={"keep":"me"}, "unknown key not preserved"
cmd=d["hooks"]["SessionStart"][0]["hooks"][0]["command"]
assert cmd=="/new/hook/detect-dotnet.sh", f"stale hook survived: {cmd}"
assert d["model"]=="opus[1m]" and d["theme"]=="dark"
assert d["enabledPlugins"].get("dotnet@dotnet-agent-skills") is True, "dotnet plugin missing when enabled"
print("ok dotnet=on")
PY
# dotnet disabled -> plugin AND marketplace must be absent (finding 6)
settings_apply "/new/hook/detect-dotnet.sh" false
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert "dotnet@dotnet-agent-skills" not in d["enabledPlugins"], "dotnet plugin present while disabled"
assert "dotnet-agent-skills" not in d["extraKnownMarketplaces"], "dotnet marketplace present while disabled"
assert d["enabledPlugins"]["superpowers@claude-plugins-official"] is True
assert d["myCustomKey"]=={"keep":"me"}, "unknown key not preserved across re-apply"
print("PASS test-settings")
PY
```

- [ ] **Step 2: Run it, expect FAIL** (`settings.sh` missing).

- [ ] **Step 3: Create the template**

`$CF/claude/settings/settings.template.json`:

```json
{
  "model": "opus[1m]",
  "effortLevel": "xhigh",
  "tui": "fullscreen",
  "theme": "dark",
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true,
    "dotnet@dotnet-agent-skills": true
  },
  "extraKnownMarketplaces": {
    "dotnet-agent-skills": { "source": { "source": "github", "repo": "dotnet/skills" } }
  },
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "<HOOK_PATH>" } ] }
    ]
  }
}
```

- [ ] **Step 4: Implement the merge**

`$CF/lib/py/jsonmerge.py`:

```python
#!/usr/bin/env python3
"""Merge managed keys from a template over an existing settings.json, preserving
unknown top-level keys.
Usage: jsonmerge.py <template> <target> <hook_path> <dotnet_enabled:true|false>"""
import json, os, sys
MANAGED = ["model","effortLevel","tui","theme","enabledPlugins","extraKnownMarketplaces","hooks"]
tmpl, target, hook = sys.argv[1], sys.argv[2], sys.argv[3]
dotnet = (len(sys.argv) > 4 and sys.argv[4] == "true")
managed = json.load(open(tmpl))
managed["hooks"]["SessionStart"][0]["hooks"][0]["command"] = hook
if not dotnet:                    # keep settings.json consistent with plugins_apply (finding 6)
    managed["enabledPlugins"].pop("dotnet@dotnet-agent-skills", None)
    managed["extraKnownMarketplaces"].pop("dotnet-agent-skills", None)
try:
    existing = json.load(open(target))
except FileNotFoundError:
    existing = {}
out = dict(existing)              # keep unknown keys
for k in MANAGED:                 # replace managed keys wholesale
    out[k] = managed[k]
os.makedirs(os.path.dirname(target), exist_ok=True)
json.dump(out, open(target, "w"), indent=2)
```

`$CF/lib/settings.sh`:

```bash
# settings.sh — own ~/.claude/settings.json (managed keys), preserve the rest.
_SET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
settings_apply() { # settings_apply <hook_abs_path> <dotnet_enabled:true|false>
  local hook="$1" dotnet="${2:-false}" tmpl="$_SET_DIR/../claude/settings/settings.template.json"
  python3 "$_SET_DIR/py/jsonmerge.py" "$tmpl" "$HOME/.claude/settings.json" "$hook" "$dotnet"
  log "settings.json applied (hook: $hook, dotnet: $dotnet)"
}
```

- [ ] **Step 5: Run test → `PASS test-settings`.**

- [ ] **Step 6: Commit**

```bash
git add lib/settings.sh lib/py/jsonmerge.py claude/settings/settings.template.json skills/tools/test-settings.sh
git commit -m "feat: own settings.json managed keys, preserve unknown keys"
```

---

## Task 4: `lib/skills.sh` — install personal skills + catalog

**Files:**
- Create: `$CF/lib/skills.sh`, `$CF/claude/skills/context7-mcp/SKILL.md` (move the current on-disk skill into the repo)
- Test: `$CF/skills/tools/test-skills.sh`

**Interfaces:**
- Consumes: `common.sh`, `$CF/skills/tools/gen-dotnet-catalog.sh` (existing), `$CF/skills/dotnet-skills` (existing read-only clone).
- Produces: `skills_apply <repo_root> <dotnet_enabled:true|false>` — always installs `~/.claude/skills/context7-mcp` (copy). When `dotnet_enabled` is `true`, it also clones `dotnet/skills` into `<repo_root>/skills/dotnet-skills` **if missing** (the catalog's source of truth — fixes fresh-machine installs), regenerates the catalog with this machine's absolute paths, and symlinks `~/.claude/skills/dotnet-router → <repo_root>/claude/skills/dotnet-router`. When `false`, only context7-mcp is installed (no dotnet-router — consistent with skipping the dotnet plugin).

- [ ] **Step 1: Bring the context7-mcp skill into the repo**

Copy the current live skill (with the earlier "When NOT to Use" edits) into the repo so claudefiles is its source of truth:

```bash
cp ~/.claude/skills/context7-mcp/SKILL.md ~/dev/claudefiles/claude/skills/context7-mcp/SKILL.md
```

- [ ] **Step 2: Write the failing test**

`$CF/skills/tools/test-skills.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
source "$cf/lib/common.sh"; source "$cf/lib/skills.sh"
# Keep the unit test hermetic: the clone-if-missing path needs the network, so it is
# exercised by the Task 13 container smoke, not here. On the dev machine the clone
# exists, so this asserts the regenerate+symlink behavior without cloning.
[ -d "$cf/skills/dotnet-skills/.git" ] || { echo "SKIP test-skills (clone absent; covered by smoke)"; exit 0; }
skills_apply "$cf" true
[ -f "$h/.claude/skills/context7-mcp/SKILL.md" ] || { echo FAIL c7; exit 1; }
[ -L "$h/.claude/skills/dotnet-router" ] || { echo FAIL symlink; exit 1; }
[ "$(readlink "$h/.claude/skills/dotnet-router")" = "$cf/claude/skills/dotnet-router" ] || { echo FAIL target; exit 1; }
[ -f "$h/.claude/skills/dotnet-router/INDEX.md" ] || { echo FAIL index; exit 1; }
# dotnet disabled -> context7 only, no dotnet-router symlink
setup_fixture_home >/dev/null; h2="$HOME"; skills_apply "$cf" false
[ -f "$h2/.claude/skills/context7-mcp/SKILL.md" ] || { echo FAIL c7-off; exit 1; }
[ -L "$h2/.claude/skills/dotnet-router" ] && { echo FAIL router-should-be-absent; exit 1; }
echo "PASS test-skills"
```

- [ ] **Step 3: Run it, expect FAIL.**

- [ ] **Step 4: Implement `skills.sh`**

`$CF/lib/skills.sh`:

```bash
# skills.sh — install personal skills into ~/.claude/skills.
_SK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
```

- [ ] **Step 5: Run test → `PASS test-skills`. Commit.**

```bash
git add lib/skills.sh claude/skills/context7-mcp/SKILL.md skills/tools/test-skills.sh \
        claude/skills/dotnet-router/          # regenerated catalog: paths now ~/dev/claudefiles
git commit -m "feat: install personal skills (context7-mcp copy, dotnet-router clone+symlink)"
```

---

## Task 5: `lib/plugins.sh` — idempotent plugin install

**Files:**
- Create: `$CF/lib/plugins.sh`; Test: `$CF/skills/tools/test-plugins.sh`

**Interfaces:**
- Consumes: `common.sh`, fake `claude`.
- Produces: `plugins_apply` — adds the `dotnet/skills` marketplace and installs `dotnet@dotnet-agent-skills`, guarded so re-runs are no-ops.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null
source "$cf/lib/common.sh"; source "$cf/lib/plugins.sh"
plugins_apply
grep -q "plugin marketplace add dotnet/skills" "$(fake_claude_calls)" || { echo FAIL mkt; exit 1; }
grep -q "plugin install dotnet@dotnet-agent-skills" "$(fake_claude_calls)" || { echo FAIL inst; exit 1; }
echo "PASS test-plugins"
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement `plugins.sh`** (ported from chezmoi `configure-claude-plugins`, guards intact)

```bash
# plugins.sh — install the dotnet plugin idempotently.
plugins_apply() {
  local cb; cb="$(claude_bin)"
  command -v dotnet >/dev/null 2>&1 || warn "dotnet SDK not found; C# LSP will not start until installed"
  if ! "$cb" plugin marketplace list 2>/dev/null | grep -q "dotnet-agent-skills\|dotnet/skills"; then
    log "adding dotnet/skills marketplace"; "$cb" plugin marketplace add dotnet/skills
  fi
  if ! "$cb" plugin list 2>/dev/null | grep -qE '(^|[[:space:]])dotnet@dotnet-agent-skills'; then
    log "installing dotnet plugin"; "$cb" plugin install dotnet@dotnet-agent-skills
  fi
}
```

- [ ] **Step 4: Run → `PASS test-plugins`. Commit.**

```bash
git add lib/plugins.sh skills/tools/test-plugins.sh
git commit -m "feat: idempotent dotnet plugin install (ported from chezmoi)"
```

---

## Task 6: `lib/mcp.sh` + `build_servers.py` — MCP reconcile via manifest

**Files:**
- Create: `$CF/lib/mcp.sh`, `$CF/claude/mcp/build_servers.py`
- Test: `$CF/skills/tools/test-mcp.sh`

**Interfaces:**
- Consumes: `common.sh`, `config.sh`, fake `claude`.
- Produces: `mcp_apply` — builds the server set from `secrets.json`, reconciles against `~/.config/claudefiles/managed-mcp.json` (the manifest holds the full desired `{name: config}` dict). If the desired set equals the manifest, it returns without issuing any `claude` call (call-idempotent, finding 7); otherwise it removes exactly the previously-managed names, adds the current set, and rewrites the manifest.

- [ ] **Step 1: Write the failing test (covers the finding-5 migration case)**

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
source "$cf/lib/common.sh"; source "$cf/lib/config.sh"; source "$cf/lib/mcp.sh"

# round 1: context7 (free tier) + ado org "old"
config_set_bool flags.context7 true; config_set context7_api_key ""
config_set_bool flags.ado true; config_set ado.email me@x.com
config_set_array ado.orgs "old"
python3 - <<PY
import json;p="$(config_path)";d=json.load(open(p))
d["ado"]["pat"]={"old":"tok1"}; json.dump(d,open(p,"w"))
PY
mcp_apply
grep -q "mcp add-json --scope user context7" "$(fake_claude_calls)" || { echo FAIL add-c7; exit 1; }
grep -q "azureDevOps-old" "$(fake_claude_calls)" || { echo FAIL add-old; exit 1; }
manifest="$h/.config/claudefiles/managed-mcp.json"
grep -q "azureDevOps-old" "$manifest" || { echo FAIL manifest; exit 1; }
[ "$(stat -c '%a' "$manifest")" = "600" ] || { echo "FAIL manifest perms $(stat -c '%a' "$manifest")"; exit 1; }   # secret-bearing -> owner-only

# round 2: drop org "old" -> removed via manifest; an unmanaged user server is never swept
: > "$(fake_claude_calls)"
config_set_array ado.orgs ""            # empty -> []
python3 - <<PY
import json;p="$(config_path)";d=json.load(open(p))
d["ado"]["pat"]={}; json.dump(d,open(p,"w"))
PY
mcp_apply
grep -q "mcp remove --scope user azureDevOps-old" "$(fake_claude_calls)" || { echo FAIL remove-old; exit 1; }
grep -q "someUserServer" "$(fake_claude_calls)" && { echo FAIL nuked-user; exit 1; }

# round 3: nothing changed -> zero claude calls (finding 7, call-idempotent)
: > "$(fake_claude_calls)"
mcp_apply
[ -s "$(fake_claude_calls)" ] && { echo "FAIL churn on unchanged"; exit 1; }
echo "PASS test-mcp"
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement `build_servers.py`** (ports the chezmoi `mcp-servers` template logic to python, reading `secrets.json`)

```python
#!/usr/bin/env python3
"""Emit {name: mcp-config} JSON from secrets.json. No secrets are printed to logs;
callers pass the JSON straight to `claude mcp add-json`."""
import base64, json, os, shutil, sys
cfg = json.load(open(sys.argv[1])) if os.path.exists(sys.argv[1]) else {}
flags = cfg.get("flags", {})

def on(name):                       # canonical flags are real bools; tolerate legacy "true" strings
    v = flags.get(name)
    return v is True or v == "true"

def chromium_path():                # resolver for the standalone case (finding 8)
    override = (cfg.get("playwright") or {}).get("chromium_path")
    if override:
        return override
    for p in ("/usr/bin/chromium", "/usr/bin/chromium-browser"):
        if os.path.exists(p):
            return p
    return shutil.which("chromium") or shutil.which("chromium-browser") or "/usr/bin/chromium"

servers = {}
if on("playwright"):
    servers["playwright"] = {"type":"stdio","command":"npx",
        "args":["-y","@playwright/mcp@latest","--executable-path", chromium_path()]}
if on("context7"):
    args = ["-y","@upstash/context7-mcp"]
    if cfg.get("context7_api_key"): args += ["--api-key", cfg["context7_api_key"]]
    servers["context7"] = {"type":"stdio","command":"npx","args":args}
if on("azure_mcp"):
    servers["azure"] = {"type":"stdio","command":"npx","args":["-y","@azure/mcp@latest","server","start"]}
if on("ado"):
    ado = cfg.get("ado", {}); email = ado.get("email","")
    for org in ado.get("orgs", []):
        pat = ado.get("pat", {}).get(org, "")
        token = base64.b64encode(f"{email}:{pat}".encode()).decode()
        servers[f"azureDevOps-{org}"] = {"type":"stdio","command":"npx",
            "args":["-y","@azure-devops/mcp",org,"--authentication","pat"],
            "env":{"PERSONAL_ACCESS_TOKEN":token}}
print(json.dumps(servers))
```

- [ ] **Step 4: Implement `mcp.sh`**

```bash
# mcp.sh — reconcile user-scope MCP servers against a managed manifest.
# The manifest stores the FULL desired {name: config} dict (not just names), so a
# changed PAT/api-key is detected too, and an unchanged set is a genuine no-op.
_MCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MCP_MANIFEST() { echo "${CLAUDEFILES_CONFIG_DIR:-$HOME/.config/claudefiles}/managed-mcp.json"; }
mcp_apply() {
  local cb; cb="$(claude_bin)"
  local servers; servers="$(python3 "$_MCP_DIR/../claude/mcp/build_servers.py" "$(config_path)")"
  local manifest; manifest="$(_MCP_MANIFEST)"
  # call-idempotent: desired == last-applied -> touch nothing (finding 7)
  if [ -f "$manifest" ] && \
     python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))==json.loads(sys.argv[2]) else 1)' \
        "$manifest" "$servers"; then
    log "MCP servers unchanged"; return 0
  fi
  # remove exactly what we managed last time (manifest keys; never a prefix sweep)
  if [ -f "$manifest" ]; then
    python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1])).keys()))' "$manifest" \
      | while read -r name; do [ -n "$name" ] && "$cb" mcp remove --scope user "$name" >/dev/null 2>&1 || true; done
  fi
  # add current set
  echo "$servers" | python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin).keys()))' \
    | while read -r name; do
        [ -z "$name" ] && continue
        one="$(echo "$servers" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)[sys.argv[1]]))' "$name")"
        "$cb" mcp remove --scope user "$name" >/dev/null 2>&1 || true
        "$cb" mcp add-json --scope user "$name" "$one"
      done
  # rewrite manifest with the full desired dict (chmod 600: it holds base64 PATs, like secrets.json)
  mkdir -p "$(dirname "$manifest")"
  printf '%s' "$servers" > "$manifest"
  chmod 600 "$manifest"
  log "MCP servers reconciled"
}
```

- [ ] **Step 5: Run → `PASS test-mcp`. Commit.**

```bash
git add lib/mcp.sh claude/mcp/build_servers.py skills/tools/test-mcp.sh
git commit -m "feat: MCP reconcile via managed-mcp.json manifest (no prefix sweep)"
```

---

## Task 7: `lib/hooks.sh` — SessionStart hook path

**Files:**
- Create: `$CF/lib/hooks.sh`; Test: folded into Task 8's idempotency test (the hook path is asserted via settings.json).

**Interfaces:**
- Produces: `hooks_hook_path <repo_root>` → absolute path `<repo_root>/claude/hooks/detect-dotnet.sh` (the value `settings_apply` receives).

- [ ] **Step 1: Implement `hooks.sh`**

```bash
# hooks.sh — resolve the SessionStart hook's absolute path for this repo.
hooks_hook_path() { echo "$1/claude/hooks/detect-dotnet.sh"; }
```

- [ ] **Step 2: Commit**

```bash
git add lib/hooks.sh
git commit -m "feat: hook path resolver for settings wiring"
```

---

## Task 8: `setup.sh` — orchestrate all phases, prove idempotency

**Files:**
- Modify: `$CF/setup.sh`; Test: `$CF/skills/tools/test-setup-idempotent.sh`

**Interfaces:**
- Consumes: every `lib/*.sh`. Produces: a single `./setup.sh [--non-interactive]` entry point.

- [ ] **Step 1: Write the failing idempotency test**

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
# seed non-interactive config so no prompt is needed
mkdir -p "$h/.config/claudefiles"
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags": {"context7":true,"playwright":true,"azure_mcp":false,"ado":false,"dotnet_skills":true},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
EOF
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive
cp "$h/.claude/settings.json" "$h/first.json"
manifest="$h/.config/claudefiles/managed-mcp.json"; cp "$manifest" "$h/first-manifest.json"
: > "$CLAUDE_FAKE_LOG"                       # capture only the SECOND run's claude calls
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive
diff "$h/first.json" "$h/.claude/settings.json" || { echo "FAIL settings not idempotent"; exit 1; }
diff "$h/first-manifest.json" "$manifest"       || { echo "FAIL manifest not idempotent"; exit 1; }
# 2nd run must not re-install the plugin or re-add MCP (stateful fake reflects prior state, finding 7)
grep -q "plugin install" "$CLAUDE_FAKE_LOG" && { echo "FAIL reinstalled plugin on 2nd run"; exit 1; }
grep -q "mcp add-json"    "$CLAUDE_FAKE_LOG" && { echo "FAIL re-added MCP on 2nd run"; exit 1; }
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$h/.claude/settings.json"
echo "PASS test-setup-idempotent"
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Rewrite `setup.sh` as the orchestrator**

```bash
#!/usr/bin/env bash
# Install the full ~/.claude config on this machine. Idempotent; the update path too.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for m in common config settings skills plugins mcp hooks; do source "$ROOT/lib/$m.sh"; done

log "1/7 preflight"; require_cmd git; require_cmd python3
command -v claude >/dev/null 2>&1 || warn "claude not on PATH yet (install it, then re-run)"

log "2/7 config"
[ "${1:-}" = "--non-interactive" ] && export CLAUDEFILES_ASSUME_TTY=0
config_ensure_all() {   # ask ONCE for every flag/secret that gates a feature
  config_ensure_flag dotnet_skills "Install .NET skills plugin? (y/N)"
  config_ensure_flag context7      "Enable Context7 MCP? (y/N)"
  if [ "$(config_flag context7)" = true ]; then
    config_ensure_optional context7_api_key "Context7 API key (empty = free tier)" --secret
  fi
  config_ensure_flag playwright "Enable Playwright MCP? (y/N)"
  config_ensure_flag azure_mcp  "Enable Azure MCP? (y/N)"
  config_ensure_flag ado        "Enable Azure DevOps MCP? (y/N)"
  if [ "$(config_flag ado)" = true ]; then
    config_ensure ado.email "Azure DevOps account email"
    if ! config_has ado.orgs; then
      if _has_tty; then
        read -r -p "Azure DevOps organizations (comma-separated): " _orgs
        config_set_array ado.orgs "$_orgs"
      else
        die "flags.ado is true but ado.orgs is unset and no TTY to prompt (set it in $(config_path))"
      fi
    fi
    for org in $(config_get ado.orgs | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)))'); do
      config_ensure "ado.pat.$org" "PAT for organization '$org'" --secret
    done
  fi
}
config_ensure_all

log "3/7 settings.json"; settings_apply "$(hooks_hook_path "$ROOT")" "$(config_flag dotnet_skills)"
log "4/7 skills";        skills_apply "$ROOT" "$(config_flag dotnet_skills)"
log "5/7 plugins";       if [ "$(config_flag dotnet_skills)" = true ]; then plugins_apply || warn "plugin install failed (rest of config still applied)"; else log "skip plugins"; fi
log "6/7 mcp";           mcp_apply
log "7/7 verify"
python3 -m json.tool "$HOME/.claude/settings.json" >/dev/null && log "settings.json valid"
"$ROOT/skills/tools/test-gen-dotnet-catalog.sh" >/dev/null 2>&1 || warn "catalog self-test skipped"
log "Done. Restart Claude Code sessions to pick up skills and hook."
```

Notes:
- Each gate uses `config_has` (Task 2), so a seeded `secrets.json` satisfies every branch and `--non-interactive` never prompts — including the empty-but-set `context7_api_key` (finding 2) and the `ado:false` short-circuit.
- On a fresh interactive machine the flow now also collects Azure MCP and, for ADO, the email + org list + one PAT per org (finding 3) — the ownership transfer of ADO secrets into claudefiles is complete.

- [ ] **Step 4: Run → `PASS test-setup-idempotent`.**

- [ ] **Step 5: Wire all tests into the existing runner and run the suite**

Add the new `test-*.sh` to whatever `skills/tools/` uses to run tests (or a new `run-all-tests.sh` that globs `test-*.sh`). Run it; expect all PASS.

- [ ] **Step 6: Commit**

```bash
git add setup.sh skills/tools/test-setup-idempotent.sh skills/tools/run-all-tests.sh
git commit -m "feat: setup.sh owns full ~/.claude config; idempotent orchestrator"
```

---

## Task 9: chezmoi — add the claudefiles `git-repo` external

**Files:**
- Modify: `$CH/.chezmoiexternal.toml`

- [ ] **Step 1: Append the external (public https, deploy copy)**

Add to `$CH/.chezmoiexternal.toml`:

```toml
[".local/share/claudefiles"]
    type = "git-repo"
    url = "https://github.com/stpntkhnv/claudefiles.git"
    refreshPeriod = "168h"
    [".local/share/claudefiles.pull"]
        args = ["--ff-only"]
```

- [ ] **Step 2: Verify chezmoi parses it**

Run: `chezmoi cat-config >/dev/null && chezmoi execute-template < /dev/null; chezmoi apply --dry-run --verbose 2>&1 | grep -i claudefiles`
Expected: chezmoi lists the external without error (no template/parse failure).

- [ ] **Step 3: Commit (chezmoi source repo, its own history)**

```bash
cd "$HOME/.local/share/chezmoi"
git add home/.chezmoiexternal.toml
git commit -m "feat: pull claudefiles as a git-repo external"
```

---

## Task 10: chezmoi — `run_after` trigger with HEAD-compare

**Files:**
- Create: `$CH/run_after_setup-claudefiles.sh.tmpl`
- Test: `$CF/skills/tools/test-head-compare.sh` (logic lives in claudefiles so it is unit-testable)

**Interfaces:**
- The trigger calls a small helper `lib/apply-if-changed.sh` in claudefiles so the HEAD-compare logic is testable outside chezmoi.

- [ ] **Step 1: Write the failing test for the HEAD-compare helper**

`$CF/skills/tools/test-head-compare.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
export CLAUDEFILES_STATE_DIR="$h/.config/claudefiles"; mkdir -p "$CLAUDEFILES_STATE_DIR"
ran="$h/ran"; run_cb() { echo x >> "$ran"; }
source "$cf/lib/apply-if-changed.sh"
apply_if_changed "AAA" run_cb; [ -f "$ran" ] || { echo FAIL first; exit 1; }   # first time: runs
apply_if_changed "AAA" run_cb; [ "$(wc -l < "$ran")" -eq 1 ] || { echo FAIL nochange; exit 1; } # same HEAD: no-op
apply_if_changed "BBB" run_cb; [ "$(wc -l < "$ran")" -eq 2 ] || { echo FAIL changed; exit 1; }  # new HEAD: runs
echo "PASS test-head-compare"
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement `lib/apply-if-changed.sh`**

```bash
# apply-if-changed.sh — run a callback only when HEAD differs from last applied.
apply_if_changed() { # apply_if_changed <head> <callback>
  local head="$1" cb="$2"
  local state="${CLAUDEFILES_STATE_DIR:-$HOME/.config/claudefiles}/last-applied-head"
  [ -f "$state" ] && [ "$(cat "$state")" = "$head" ] && return 0
  "$cb"
  mkdir -p "$(dirname "$state")"; printf '%s' "$head" > "$state"
}
```

- [ ] **Step 4: Run → `PASS test-head-compare`. Commit (claudefiles).**

```bash
git add lib/apply-if-changed.sh skills/tools/test-head-compare.sh
git commit -m "feat: HEAD-compare helper for idempotent re-apply"
```

- [ ] **Step 5: Create the chezmoi trigger that uses it**

`$CH/run_after_setup-claudefiles.sh.tmpl`:

```bash
#!/bin/bash
{{ if .setup_claude -}}
set -euo pipefail
CF="{{ .chezmoi.homeDir }}/.local/share/claudefiles"
[ -d "$CF/.git" ] || { echo "claudefiles external not present yet; skipping"; exit 0; }
head="$(git -C "$CF" rev-parse HEAD)"
source "$CF/lib/apply-if-changed.sh"
run() { "$CF/setup.sh"{{ if not (stdinIsATTY) }} --non-interactive{{ end }}; }
apply_if_changed "$head" run
{{- else -}}
exit 0
{{- end }}
```

Run: `chezmoi execute-template < "$CH/run_after_setup-claudefiles.sh.tmpl" | head` — expect valid bash, correct `$CF` path.

- [ ] **Step 6: Commit (chezmoi repo)**

```bash
cd "$HOME/.local/share/chezmoi"
git add home/run_after_setup-claudefiles.sh.tmpl
git commit -m "feat: run_after trigger runs claudefiles setup.sh on HEAD change"
```

---

## Task 11: chezmoi — remove moved pieces, strip Claude-config prompts

**Files:**
- Delete: `$CH/run_onchange_after_configure-claude-plugins.sh.tmpl`, `$CH/run_onchange_after_configure-claude-mcp.sh.tmpl`, `$CH/.chezmoitemplates/mcp-servers`, `$CH/dot_claude/skills/brainstorming/SKILL.md` (+ empty dirs)
- Modify: `$CH/.chezmoi.toml.tmpl` (remove Claude-config prompts)

- [ ] **Step 1: Remove the moved scripts, template, and duplicate skill**

```bash
cd "$HOME/.local/share/chezmoi/home"
git rm run_onchange_after_configure-claude-plugins.sh.tmpl \
       run_onchange_after_configure-claude-mcp.sh.tmpl \
       .chezmoitemplates/mcp-servers \
       dot_claude/skills/brainstorming/SKILL.md
```

(The `brainstorming` skill is provided by the superpowers plugin already, so the chezmoi copy is redundant.)

- [ ] **Step 2: Strip Claude-config prompts from `.chezmoi.toml.tmpl`**

Remove the prompt/data lines for `setup_playwright`, `setup_context7`, `context7_api_key`, `setup_dotnet_skills`, `setup_ado`, `ado_orgs`, `ado_email`, and the `ado_pat_*` range. **Keep** `setup_claude` (gates installing the CLI), `git_name`/`git_email`, `setup_codex`, `setup_azure` (Azure CLI install), and container-only options. After editing:

```bash
cd "$HOME/.local/share/chezmoi"
chezmoi execute-template < home/.chezmoi.toml.tmpl >/dev/null && echo "template renders"
```

- [ ] **Step 3: Add a chezmoi ignore so the removed prompts don't strand `~/.claude` writes**

Confirm `chezmoi apply --dry-run` no longer references the deleted scripts:

```bash
chezmoi apply --dry-run --verbose 2>&1 | grep -iE 'configure-claude|mcp-servers|brainstorming' && echo "STILL REFERENCED" || echo "clean"
```

Expected: `clean`.

- [ ] **Step 4: Commit**

```bash
git add -A home/
git commit -m "chore: move Claude plugin/MCP/skill config out of chezmoi into claudefiles"
```

---

## Task 12: Seed `secrets.json` from existing chezmoi data (migration)

**Files:**
- One-shot migration; no repo change. Reads `~/.config/chezmoi/chezmoi.toml`.

- [ ] **Step 1: Extract current Claude secrets from chezmoi's data store**

```bash
python3 - <<'PY'
import tomllib, json, os
src = os.path.expanduser("~/.config/chezmoi/chezmoi.toml")
data = tomllib.load(open(src, "rb")).get("data", {})
orgs = [o.strip() for o in str(data.get("ado_orgs","")).split(",") if o.strip()]
out = {
  "flags": {
    "context7":  bool(data.get("setup_context7")),
    "playwright":bool(data.get("setup_playwright")),
    "azure_mcp": bool(data.get("setup_azure")),
    "ado":       bool(data.get("setup_ado")),
    "dotnet_skills": bool(data.get("setup_dotnet_skills")),
  },
  "context7_api_key": data.get("context7_api_key",""),
  "ado": {"email": data.get("ado_email",""), "orgs": orgs,
          "pat": {o: data.get(f"ado_pat_{o}","") for o in orgs}},
}
dst = os.path.expanduser("~/.config/claudefiles/secrets.json")
os.makedirs(os.path.dirname(dst), exist_ok=True)
json.dump(out, open(dst,"w"), indent=2); os.chmod(dst, 0o600)
print("seeded", dst)
PY
```

(`tomllib` is stdlib on python 3.11+. If older, parse the few keys with `grep`/`sed` instead.)

- [ ] **Step 2: Verify no value was lost and run setup from the dev checkout**

```bash
# redacted verifier — prints presence, NEVER secret values (finding 5)
python3 - <<'PY'
import json, os
d = json.load(open(os.path.expanduser("~/.config/claudefiles/secrets.json")))
print("flags:", d.get("flags"))
ado = d.get("ado", {})
print("ado.email:", ado.get("email") or "(empty)")
print("ado.orgs:", ado.get("orgs"))
print("ado.pat set for orgs:", [o for o, v in ado.get("pat", {}).items() if v])
print("context7_api_key:", "set" if d.get("context7_api_key") else "(empty / free tier)")
PY
cd ~/dev/claudefiles && ./setup.sh --non-interactive
```

Expected: flags/orgs look right (no raw PATs printed); then settings/skills/plugins/MCP applied without prompts; `claude mcp list` shows the expected servers.

- [ ] **Step 3: No commit** (migration touches only `~/.config`, never the repo).

---

## Task 13: Make repo public, prove one-command fresh install, document

**Files:**
- Modify: `$CF/docs/superpowers/smoke-results-dotnet-delivery.md` (append), `$CF/README.md` (install section)
- Create: `$CF/skills/tools/test-secrets-not-tracked.sh`

- [ ] **Step 1: Guard test — no secret path is tracked**

```bash
#!/usr/bin/env bash
set -euo pipefail
cf="$(cd "$(dirname "$0")/../.." && pwd)"
if git -C "$cf" ls-files | grep -Ei 'secrets\.json|managed-mcp\.json|last-applied-head|\.env$'; then
  echo "FAIL: secret-bearing path tracked"; exit 1; fi
echo "PASS test-secrets-not-tracked"
```

Run it → `PASS`. Commit.

- [ ] **Step 2: Scan the FULL history for secrets, then make the repo public**

`git ls-files` (Step 1) only sees the current tree. Before flipping to public, scan every ref — a secret committed and later deleted still ships in history (finding 4). This is a hard gate: a hit stops the task for manual review (`git filter-repo`/BFG) before publishing.

```bash
cd ~/dev/claudefiles
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks detect --no-banner --redact --log-opts="--all" \
    || { echo "ABORT: gitleaks found secrets in history — scrub before publishing"; exit 1; }
else
  # focused fallback: markers that only a leaked secret would produce (not paths/hashes)
  if git log -p --all \
     | grep -nEi 'PERSONAL_ACCESS_TOKEN|api[-_]?key|-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{16,}|xox[baprs]-|AKIA[0-9A-Z]{16}'; then
    echo "ABORT: possible secret in git history — review the hits above before publishing"; exit 1
  fi
fi
echo "history scan clean"

gh repo edit stpntkhnv/claudefiles --visibility public --accept-visibility-change-consequences
gh repo view stpntkhnv/claudefiles --json visibility -q .visibility   # -> "public"
```

- [ ] **Step 3: Merge the feature branch to main and push**

Use superpowers:finishing-a-development-branch. Then push `main` so the external can pull it.

- [ ] **Step 4: End-to-end one-command smoke in a clean container**

```bash
distrobox create --name cf-smoke --image debian:stable && distrobox enter cf-smoke
# inside: install chezmoi, then:
chezmoi init --apply stpntkhnv/dotfiles     # installs claude, pulls claudefiles, runs setup.sh
claude --version && ls ~/.claude/skills && claude mcp list
```

Append the transcript/result to `docs/superpowers/smoke-results-dotnet-delivery.md`.

- [ ] **Step 5: Update README install section** to the two-path model (fresh: `chezmoi init --apply stpntkhnv/dotfiles`; dev: clone claudefiles + `./setup.sh`). Commit.

```bash
git add README.md docs/superpowers/smoke-results-dotnet-delivery.md skills/tools/test-secrets-not-tracked.sh
git commit -m "docs: public repo, one-command smoke, secret-tracking guard"
```

---

## Self-Review

**Spec coverage:**
- §3 two-tier ownership → Tasks 8 (claudefiles owns all) + 9/10 (chezmoi thin) ✓
- §4.1 setup.sh phases → Tasks 2–8 ✓
- §4.2 MCP manifest reconcile → Task 6 ✓
- §4.3 secrets JSON + TTY → Task 2; store safety → Task 13 ✓
- §4.4 external + run_after HEAD-compare → Tasks 9/10; chezmoi removals → Task 11 ✓
- §5 data flow (both paths) → Task 13 smoke + dev runs ✓
- §6 migration → Tasks 1 (rename/refs), 12 (seed secrets) ✓
- §7 portability (no hardcoded home; hook path from repo) → Tasks 3/7 ✓
- §8 tests: idempotency (T8), non-interactive (T8), MCP calls + migration (T6), settings render (T3), secret-not-tracked (T13), HEAD-compare (T10), smoke (T13) ✓
- §9 decisions (public+https, two-copy, TTY, azure split, settings ownership) → encoded in Tasks 9/1/2/6/3 ✓

**Placeholder scan:** no TBD/"handle edge cases"/"similar to Task N"; every code step carries complete code. ✓

**Type/name consistency:** `config_get/config_has/config_set/config_set_bool/config_set_array/config_ensure/config_ensure_optional/config_ensure_flag/config_flag/config_path`, `settings_apply <hook> <dotnet>`, `skills_apply`, `plugins_apply`, `mcp_apply`, `hooks_hook_path`, `apply_if_changed` — used consistently across tasks and the orchestrator. Managed-key list matches the template and §Global Constraints; flag values are JSON booleans everywhere they are read (bash `config_flag` + python `on()`). ✓

**Gap noted & folded:** `setup_azure` in chezmoi still installs the Azure CLI (kept, §9.2); the azure *MCP* flag is `flags.azure_mcp` in secrets.json (Task 6) — the two are intentionally separate, documented in Task 11 Step 2.

### Round-2 review resolution (Codex)

| # | Finding | Resolution | Tasks touched |
|---|---------|-----------|---------------|
| 1 | bool/string flag mixing | Flags stored as real JSON booleans; `config_io get` emits lowercase; typed `setbool`/`config_set_bool`; `build_servers` `on()` also tolerates legacy strings. Test: bool round-trip + literal `false`. | 2, 6 |
| 2 | optional `context7_api_key` treated as required | `config_has` (presence ≠ emptiness) + `config_ensure_optional` (ask once, empty valid, no-TTY records empty w/o dying). setup.sh uses it. | 2, 8 |
| 3 | fresh machine never collects Azure/ADO | `config_ensure_all` now gates `azure_mcp`, `ado`, `ado.email`, `ado.orgs` (array), and one PAT per org. | 8 |
| 4 | history scan before public | Hard gate over `--all` refs (gitleaks or focused grep) before `gh repo edit --visibility public`. | 13 |
| 5 | `cat secrets.json` leaks PATs | Redacted verifier: flags, org names, key-present booleans; never values. | 12 |
| 6 | `dotnet_skills=false` yet plugin enabled | `jsonmerge` drops the dotnet plugin + marketplace when the flag is false; `settings_apply` takes the flag. Test asserts both on/off. | 3, 8 |
| 7 | idempotency test too weak | Fake `claude` is now stateful; `mcp_apply` skips when manifest == desired (call-idempotent). Test asserts no plugin reinstall / no MCP re-add / stable manifest on 2nd run, and zero MCP calls when unchanged. | 1, 6, 8 |
| 8 | playwright chromium "lost detection" | **Premise disputed** — the chezmoi original also hardcoded `/usr/bin/chromium` (relied on `01-install-packages`). Adopted as hardening for the standalone case: `chromium_path()` resolver + `playwright.chromium_path` override. | 6 |
| 9 | commit trailer vs examples | Global Constraints states the exact `Co-Authored-By` trailer once; examples abbreviate it. | Constraints |

**Also fixed in passing:** preflight `require_cmd claude` would `die` before its `|| warn` ever ran — softened to a `command -v` check with a warning, so a machine without `claude` yet gets a clear message instead of an abort.

**Pre-flight fix (execution):** `skills_apply` dropped the `dotnet/skills` clone that the old `setup.sh` performed, so a fresh machine would ship the committed catalog with another machine's absolute paths → dotnet-router `Read`s fail. Restored clone-if-missing inside `skills_apply`, gated on the `dotnet_skills` flag (Task 4), and threaded the flag through `setup.sh` (Task 8).
