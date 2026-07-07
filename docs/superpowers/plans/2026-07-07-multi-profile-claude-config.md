# Multi-Profile `~/.claude` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one machine hold a lightweight `vanilla` profile (`~/.claude`, plain `claude`) alongside the full `super` profile (`~/.claude-super`, `claude-super`), provisioned by the same idempotent `setup.sh`, with a clean one-time migration off today's all-in-one `~/.claude`.

**Architecture:** A profile = a named recipe that runs the existing `*_apply` modules against a target config dir (`CLAUDEFILES_TARGET`), with `CLAUDE_CONFIG_DIR` exported so `claude plugin/mcp` land there. `setup.sh` asks which profiles to install and loops recipes in subshells. Migration off super is handled by generalized `jsonmerge.py` (delete super machinery keys, one-time reset of `model`/`effort`), symmetric skill removal, and legacy MCP-manifest consumption.

**Tech Stack:** Bash (GNU coreutils/awk), Python 3 (stdlib only), Claude Code CLI 2.1.x (`--` flags, `CLAUDE_CONFIG_DIR`), the repo's fake-`claude` + fixture-`$HOME` test harness.

## Global Constraints

- Idempotent: a second `setup.sh` produces zero diff in every provisioned dir and exits 0 when all selected profiles succeed. Copy verbatim: super `model` = `"opus[1m]"`, `effortLevel` = `"xhigh"`, `theme` = `"dark"`, `tui` = `"fullscreen"`; vanilla `theme` = `"light"`, `tui` = `"fullscreen"`.
- Python 3 **stdlib only**; no new runtime dependencies (statusline parses via `python3`, not `jq`).
- Public repo: no secrets in git. Profile selection + flags live in `~/.config/claudefiles/secrets.json` (`600`), outside git.
- Do not edit files under `skills/superpowers/` or `skills/dotnet-skills/` (managed externally).
- Every module is tested against the fake `claude` and a fixture `$HOME` (`skills/tools/lib/faketools.bash`).
- `CLAUDEFILES_TARGET` defaults to `$HOME/.claude` so existing single-target behavior is preserved for any caller that does not set it.
- User owns `model`/`effortLevel` in vanilla: managed once at migration, never clobbered on later runs.

## File Structure

- `claude/settings/settings.super.template.json` — renamed from `settings.template.json` (hook placeholder `<HOOK_PATH>`).
- `claude/settings/settings.vanilla.template.json` — NEW: `theme:light`, `tui:fullscreen`, `statusLine` with `<STATUSLINE_PATH>`.
- `claude/statusline/statusline.sh` — NEW: light-theme status line, parses stdin JSON via python3.
- `lib/py/jsonmerge.py` — generalized: template-driven managed set, delete super-machinery keys absent from template, one-time `model`/`effort` reset when converting off super, optional plugin gating.
- `lib/settings.sh` — target-aware; renders path placeholders; takes a template path.
- `lib/skills.sh` — target-aware (`CLAUDEFILES_TARGET/skills`); removes `dotnet-router` symlink when dotnet disabled.
- `lib/mcp.sh` — per-profile manifest (`managed-mcp.<profile>.json`); explicit servers arg; consumes legacy `managed-mcp.json`.
- `lib/claudemd.sh` — target-aware; adds a second managed block (personal style) beside the codex block.
- `claude/mcp/build_servers.py` — optional `profile` arg; `vanilla` → context7 only (forced on).
- `lib/profiles.sh` — NEW: `profile_dir`, `recipe_vanilla`, `recipe_super`, `ensure_credentials_symlink`, `generate_wrapper`.
- `setup.sh` — profile menu, subshell recipe loop, failure aggregation, post-loop wiring, readiness + runtime guard.
- `skills/tools/test-*.sh` — updated/added tests; `run-all-tests.sh` auto-discovers them.

---

## Task 1: Split settings templates (vanilla + super)

**Files:**
- Rename: `claude/settings/settings.template.json` → `claude/settings/settings.super.template.json`
- Create: `claude/settings/settings.vanilla.template.json`

**Interfaces:**
- Produces: two template files. Super keeps the `<HOOK_PATH>` placeholder in `hooks.SessionStart[0].hooks[0].command`. Vanilla carries `<STATUSLINE_PATH>` in `statusLine.command`.

- [ ] **Step 1: Rename the super template**

```bash
git mv claude/settings/settings.template.json claude/settings/settings.super.template.json
```

- [ ] **Step 2: Create the vanilla template**

Create `claude/settings/settings.vanilla.template.json`:

```json
{
  "theme": "light",
  "tui": "fullscreen",
  "statusLine": {
    "type": "command",
    "command": "<STATUSLINE_PATH>",
    "padding": 2
  }
}
```

- [ ] **Step 3: Verify both are valid JSON**

Run: `python3 -m json.tool claude/settings/settings.super.template.json >/dev/null && python3 -m json.tool claude/settings/settings.vanilla.template.json >/dev/null && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add claude/settings/
git commit -m "refactor(settings): split template into vanilla + super profiles"
```

---

## Task 2: Generalize `jsonmerge.py` + target-aware `settings_apply`

**Files:**
- Modify: `lib/py/jsonmerge.py` (full rewrite)
- Modify: `lib/settings.sh`
- Test: `skills/tools/test-settings.sh` (rewrite)

**Interfaces:**
- Consumes: templates from Task 1; `CLAUDEFILES_TARGET` (default `$HOME/.claude`).
- Produces:
  - `settings_apply <template_path> <dotnet:true|false> <codex_plugin:true|false>` — renders `<HOOK_PATH>`/`<STATUSLINE_PATH>` to repo-absolute paths, writes `${CLAUDEFILES_TARGET:-$HOME/.claude}/settings.json` via jsonmerge.
  - `jsonmerge.py <template> <target> <dotnet:true|false> <codex_plugin:true|false>` — sets template's managed keys, deletes super-machinery keys the template omits, and (only when `target` currently has `enabledPlugins["superpowers@claude-plugins-official"]`) deletes `model`/`effortLevel` the template omits.

- [ ] **Step 1: Write the failing test**

Replace `skills/tools/test-settings.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
source "$cf/lib/common.sh"; source "$cf/lib/settings.sh"
SUPER="$cf/claude/settings/settings.super.template.json"
VANILLA="$cf/claude/settings/settings.vanilla.template.json"

# --- super profile: full stack, hook path rendered, unknown key preserved ---
cat > "$h/.claude/settings.json" <<'EOF'
{ "myCustomKey": {"keep":"me"} }
EOF
settings_apply "$SUPER" true true
python3 - "$h/.claude/settings.json" "$cf" <<'PY'
import json,sys; d=json.load(open(sys.argv[1])); cf=sys.argv[2]
assert d["myCustomKey"]=={"keep":"me"}, "unknown key not preserved"
assert d["model"]=="opus[1m]" and d["theme"]=="dark" and d["tui"]=="fullscreen"
cmd=d["hooks"]["SessionStart"][0]["hooks"][0]["command"]
assert cmd==f"{cf}/claude/hooks/detect-dotnet.sh", f"hook not rendered: {cmd}"
assert d["enabledPlugins"].get("dotnet@dotnet-agent-skills") is True
assert d["enabledPlugins"].get("codex@openai-codex") is True
print("ok super")
PY

# --- super with dotnet+codex off: plugins+marketplaces gated out ---
settings_apply "$SUPER" false false
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert "dotnet@dotnet-agent-skills" not in d["enabledPlugins"]
assert "codex@openai-codex" not in d["enabledPlugins"]
assert "dotnet-agent-skills" not in d["extraKnownMarketplaces"]
assert d["enabledPlugins"]["superpowers@claude-plugins-official"] is True
print("ok super gated")
PY

# --- MIGRATION: existing super dir -> vanilla strips machinery AND model/effort ---
cat > "$h/.claude/settings.json" <<'EOF'
{ "model":"opus[1m]", "effortLevel":"xhigh", "tui":"fullscreen", "theme":"dark",
  "enabledPlugins":{"superpowers@claude-plugins-official":true,"dotnet@dotnet-agent-skills":true},
  "hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/old/detect.sh"}]}]},
  "myCustomKey":{"keep":"me"} }
EOF
settings_apply "$VANILLA" false false
python3 - "$h/.claude/settings.json" "$cf" <<'PY'
import json,sys; d=json.load(open(sys.argv[1])); cf=sys.argv[2]
assert d["theme"]=="light", "vanilla theme not applied"
assert d["statusLine"]["command"]==f"{cf}/claude/statusline/statusline.sh", "statusline not rendered"
assert "enabledPlugins" not in d, "super plugins not removed"
assert "hooks" not in d, "stale hook not removed"
assert "model" not in d and "effortLevel" not in d, "heavy defaults not reset on migration"
assert d["myCustomKey"]=={"keep":"me"}, "unknown key lost"
print("ok migration")
PY

# --- STEADY STATE: user re-adds model on a non-super vanilla dir; re-apply keeps it ---
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1])); d["model"]="sonnet"; d["effortLevel"]="medium"
json.dump(d, open(sys.argv[1],"w"), indent=2)
PY
settings_apply "$VANILLA" false false
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert d["model"]=="sonnet" and d["effortLevel"]=="medium", "user model/effort clobbered on steady-state run"
print("ok steady-state preserves user model/effort")
PY

# --- target-awareness: writes to CLAUDEFILES_TARGET, not $HOME/.claude ---
alt="$h/.claude-super"; mkdir -p "$alt"
CLAUDEFILES_TARGET="$alt" settings_apply "$SUPER" false false
[ -f "$alt/settings.json" ] || { echo FAIL target-not-written; exit 1; }
echo "PASS test-settings"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash skills/tools/test-settings.sh`
Expected: FAIL (old `settings_apply` signature/`jsonmerge` don't handle templates or vanilla).

- [ ] **Step 3: Rewrite `jsonmerge.py`**

Replace `lib/py/jsonmerge.py` with:

```python
#!/usr/bin/env python3
"""Merge a profile's managed keys over an existing settings.json, preserving unknown keys.
Usage: jsonmerge.py <template> <target> <dotnet:true|false> <codex_plugin:true|false>

- Keys present in the template are set (wholesale replace).
- REMOVABLE keys absent from the template are deleted from target (drops super machinery
  when a lighter profile omits them).
- model/effortLevel absent from the template are deleted ONLY when the target currently
  enables the superpowers plugin (i.e. a one-time super->vanilla migration); otherwise they
  are left untouched so a user's manual values survive steady-state re-runs."""
import json, os, sys

MANAGED = ["model", "effortLevel", "tui", "theme", "statusLine",
           "enabledPlugins", "extraKnownMarketplaces", "hooks"]
REMOVABLE = {"enabledPlugins", "extraKnownMarketplaces", "hooks"}
RESET_IF_SUPER = {"model", "effortLevel"}
SUPERPOWERS = "superpowers@claude-plugins-official"

tmpl, target = sys.argv[1], sys.argv[2]
dotnet = len(sys.argv) > 3 and sys.argv[3] == "true"
codex_plugin = len(sys.argv) > 4 and sys.argv[4] == "true"

template = json.load(open(tmpl))
if "enabledPlugins" in template:                 # gate optional plugins, keep marketplaces consistent
    if not dotnet:
        template["enabledPlugins"].pop("dotnet@dotnet-agent-skills", None)
        template.get("extraKnownMarketplaces", {}).pop("dotnet-agent-skills", None)
    if not codex_plugin:
        template["enabledPlugins"].pop("codex@openai-codex", None)
        template.get("extraKnownMarketplaces", {}).pop("openai-codex", None)

try:
    existing = json.load(open(target))
except FileNotFoundError:
    existing = {}
except json.JSONDecodeError as e:
    sys.stderr.write(f"corrupt JSON in {target}: {e}\n"); sys.exit(2)

was_super = bool(existing.get("enabledPlugins", {}).get(SUPERPOWERS))
out = dict(existing)                              # keep unknown keys
for k in MANAGED:
    if k in template:
        out[k] = template[k]
    elif k in REMOVABLE:
        out.pop(k, None)
    elif k in RESET_IF_SUPER and was_super:
        out.pop(k, None)

os.makedirs(os.path.dirname(target), exist_ok=True)
json.dump(out, open(target, "w"), indent=2)
```

- [ ] **Step 4: Rewrite `lib/settings.sh`**

Replace `lib/settings.sh` with:

```bash
# settings.sh — own the managed keys of a profile's settings.json, preserve the rest.
_SET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
settings_apply() { # settings_apply <template_path> <dotnet> <codex_plugin>
  local tmpl="$1" dotnet="${2:-false}" codex_plugin="${3:-false}"
  local target="${CLAUDEFILES_TARGET:-$HOME/.claude}/settings.json"
  local repo; repo="$(cd "$_SET_DIR/.." && pwd)"
  local hook="$repo/claude/hooks/detect-dotnet.sh"
  local statusline="$repo/claude/statusline/statusline.sh"
  local rendered; rendered="$(mktemp)"
  sed -e "s#<HOOK_PATH>#$hook#g" -e "s#<STATUSLINE_PATH>#$statusline#g" "$tmpl" > "$rendered"
  python3 "$_SET_DIR/py/jsonmerge.py" "$rendered" "$target" "$dotnet" "$codex_plugin"
  rm -f "$rendered"
  log "settings.json applied → $target (dotnet: $dotnet, codex_plugin: $codex_plugin)"
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash skills/tools/test-settings.sh`
Expected: `PASS test-settings`

- [ ] **Step 6: Commit**

```bash
git add lib/py/jsonmerge.py lib/settings.sh skills/tools/test-settings.sh
git commit -m "feat(settings): profile-driven jsonmerge + one-time super->vanilla migration"
```

---

## Task 3: `skills.sh` — target-aware + symmetric `dotnet-router` removal

**Files:**
- Modify: `lib/skills.sh`
- Test: `skills/tools/test-skills.sh`

**Interfaces:**
- Consumes: `CLAUDEFILES_TARGET`.
- Produces: `skills_apply <repo_root> <dotnet> <codex_review>` writes `${CLAUDEFILES_TARGET:-$HOME/.claude}/skills`; when `dotnet=false`, any existing `dotnet-router` symlink is removed.

- [ ] **Step 1: Write the failing test**

Add to `skills/tools/test-skills.sh` (before the final `echo "PASS test-skills"`):

```bash
# P1a: a PRE-EXISTING dotnet-router symlink is removed when dotnet=false (migration)
setup_fixture_home >/dev/null; hp="$HOME"
mkdir -p "$hp/.claude/skills/dotnet-router"
ln -sfnT "$cf/claude/skills/dotnet-router" "$hp/.claude/skills/dotnet-router" 2>/dev/null || true
skills_apply "$cf" false false
[ -e "$hp/.claude/skills/dotnet-router" ] && { echo FAIL dotnet-router-not-removed; exit 1; }
# target-awareness: skills land in CLAUDEFILES_TARGET
setup_fixture_home >/dev/null; ht2="$HOME"; alt="$ht2/.claude-super"; mkdir -p "$alt"
CLAUDEFILES_TARGET="$alt" skills_apply "$cf" false false
[ -f "$alt/skills/context7-mcp/SKILL.md" ] || { echo FAIL target-skills; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash skills/tools/test-skills.sh`
Expected: FAIL `dotnet-router-not-removed` (current `skills.sh:15-18` returns without removing).

- [ ] **Step 3: Edit `lib/skills.sh`**

Change the `dst` line and the dotnet-disabled branch. Replace:

```bash
  local root="$1" dotnet="${2:-false}" codex_review="${3:-false}" dst="$HOME/.claude/skills"
```
with:
```bash
  local root="$1" dotnet="${2:-false}" codex_review="${3:-false}" dst="${CLAUDEFILES_TARGET:-$HOME/.claude}/skills"
```

Replace:
```bash
  if [ "$dotnet" != true ]; then
    log "skills installed (context7-mcp); dotnet-router skipped (dotnet disabled)"
    return 0
  fi
```
with:
```bash
  if [ "$dotnet" != true ]; then
    rm -rf "$dst/dotnet-router"          # symmetric with codex-review: leave no trace on disable
    log "skills installed (context7-mcp); dotnet-router removed (dotnet disabled)"
    return 0
  fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash skills/tools/test-skills.sh`
Expected: `PASS test-skills`

- [ ] **Step 5: Commit**

```bash
git add lib/skills.sh skills/tools/test-skills.sh
git commit -m "feat(skills): target-aware dst + remove dotnet-router on disable"
```

---

## Task 4: `mcp.sh` per-profile manifest + legacy consumption; `build_servers.py` vanilla mode

**Files:**
- Modify: `claude/mcp/build_servers.py`
- Modify: `lib/mcp.sh`
- Test: `skills/tools/test-mcp.sh` (rewrite)

**Interfaces:**
- Consumes: `config_path` (secrets), `CLAUDE_CONFIG_DIR` (via `claude mcp`), `claude_bin`.
- Produces:
  - `build_servers.py <secrets> [profile]` — `profile == "vanilla"` emits only `{context7:...}` (forced on, honoring `context7_api_key`); otherwise current flag-driven behavior.
  - `mcp_apply <servers_json> <manifest_path> [<prev_manifest_path>]` — removes servers in prev manifest, adds `servers_json`, writes `manifest_path`; if `prev != manifest` it is consumed (`rm`) after success.
  - `_mcp_manifest <profile>` → `~/.config/claudefiles/managed-mcp.<profile>.json`; `_mcp_legacy` → `~/.config/claudefiles/managed-mcp.json`.

- [ ] **Step 1: Write the failing test**

Replace `skills/tools/test-mcp.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
source "$cf/lib/common.sh"; source "$cf/lib/config.sh"; source "$cf/lib/mcp.sh"
mkdir -p "$h/.config/claudefiles"

# build_servers vanilla mode = context7 only, even with super flags on
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"context7":false,"playwright":true,"azure_mcp":true,"ado":false},"context7_api_key":"" }
EOF
van="$(python3 "$cf/claude/mcp/build_servers.py" "$(config_path)" vanilla)"
echo "$van" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert list(d)==["context7"],d;print("ok vanilla-servers")'

# MIGRATION: legacy manifest lists super servers -> vanilla apply removes them, keeps context7
printf '%s' '{"playwright":{"x":1},"azure":{"x":1},"context7":{"y":1}}' > "$h/.config/claudefiles/managed-mcp.json"
: > "$CLAUDE_FAKE_LOG"
mcp_apply "$van" "$(_mcp_manifest vanilla)" "$(_mcp_legacy)"
grep -q "mcp remove --scope user playwright" "$CLAUDE_FAKE_LOG" || { echo FAIL no-remove-playwright; exit 1; }
grep -q "mcp remove --scope user azure"      "$CLAUDE_FAKE_LOG" || { echo FAIL no-remove-azure; exit 1; }
grep -q "mcp add-json --scope user context7" "$CLAUDE_FAKE_LOG" || { echo FAIL no-add-context7; exit 1; }
[ -f "$(_mcp_manifest vanilla)" ] || { echo FAIL no-vanilla-manifest; exit 1; }
[ -f "$h/.config/claudefiles/managed-mcp.json" ] && { echo FAIL legacy-not-consumed; exit 1; }

# idempotent: same servers, same manifest -> no claude calls
: > "$CLAUDE_FAKE_LOG"
mcp_apply "$van" "$(_mcp_manifest vanilla)"
grep -q "mcp " "$CLAUDE_FAKE_LOG" && { echo FAIL not-idempotent; exit 1; }

# P1c: manifest already == desired BUT a legacy manifest still lingers (interrupted migration)
# -> must NOT early-return; must still remove legacy super servers and consume legacy.
printf '%s' '{"playwright":{"x":1},"context7":{"y":1}}' > "$h/.config/claudefiles/managed-mcp.json"
: > "$CLAUDE_FAKE_LOG"
mcp_apply "$van" "$(_mcp_manifest vanilla)" "$(_mcp_legacy)"
grep -q "mcp remove --scope user playwright" "$CLAUDE_FAKE_LOG" || { echo FAIL legacy-not-swept-when-manifest-current; exit 1; }
[ -f "$h/.config/claudefiles/managed-mcp.json" ] && { echo FAIL legacy-not-consumed-2; exit 1; }
echo "PASS test-mcp"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash skills/tools/test-mcp.sh`
Expected: FAIL (`build_servers.py` ignores the `vanilla` arg; `mcp_apply` has the old signature; `_mcp_manifest`/`_mcp_legacy` undefined).

- [ ] **Step 3: Edit `claude/mcp/build_servers.py`**

Insert, immediately after the `servers = {}` line (before the `if on("playwright")` block):

```python
profile = sys.argv[2] if len(sys.argv) > 2 else "all"
if profile == "vanilla":                 # vanilla always ships context7 only, regardless of flags
    args = ["-y", "@upstash/context7-mcp"]
    if cfg.get("context7_api_key"):
        args += ["--api-key", cfg["context7_api_key"]]
    print(json.dumps({"context7": {"type": "stdio", "command": "npx", "args": args}}))
    sys.exit(0)
```

- [ ] **Step 4: Rewrite `lib/mcp.sh`**

Replace `lib/mcp.sh` with:

```bash
# mcp.sh — reconcile user-scope MCP servers (in $CLAUDE_CONFIG_DIR) against a per-profile manifest.
_MCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash skills/tools/test-mcp.sh`
Expected: `PASS test-mcp`

- [ ] **Step 6: Commit**

```bash
git add claude/mcp/build_servers.py lib/mcp.sh skills/tools/test-mcp.sh
git commit -m "feat(mcp): per-profile manifest, vanilla context7-only, legacy consumption"
```

---

## Task 5: `claudemd.sh` — target-aware + personal-style block

**Files:**
- Modify: `lib/claudemd.sh`
- Test: `skills/tools/test-claudemd.sh` (append cases)

**Interfaces:**
- Consumes: `CLAUDEFILES_TARGET`.
- Produces:
  - `claudemd_apply <codex_enabled>` — unchanged behavior, now defaults its file to `${CLAUDEFILES_CLAUDE_MD:-${CLAUDEFILES_TARGET:-$HOME/.claude}/CLAUDE.md}`.
  - `claudemd_personal_apply <enabled>` — owns a second marker block (personal style); idempotent; removes the block when disabled.

- [ ] **Step 1: Write the failing test**

Append to `skills/tools/test-claudemd.sh` (before its final PASS line):

```bash
# personal-style block: add, idempotent, and removable; coexists with codex block
setup_fixture_home >/dev/null; hp="$HOME"
export CLAUDEFILES_CLAUDE_MD="$hp/.claude/CLAUDE.md"
claudemd_personal_apply true
grep -q "claudefiles:personal" "$hp/.claude/CLAUDE.md" || { echo FAIL personal-missing; exit 1; }
cp "$hp/.claude/CLAUDE.md" "$hp/first.md"
claudemd_personal_apply true
diff "$hp/first.md" "$hp/.claude/CLAUDE.md" || { echo FAIL personal-not-idempotent; exit 1; }
claudemd_apply true                                  # codex block coexists
grep -q "claudefiles:personal" "$hp/.claude/CLAUDE.md" || { echo FAIL personal-lost; exit 1; }
grep -q "claudefiles:codex-review" "$hp/.claude/CLAUDE.md" || { echo FAIL codex-lost; exit 1; }
claudemd_personal_apply false
grep -q "claudefiles:personal" "$hp/.claude/CLAUDE.md" && { echo FAIL personal-not-removed; exit 1; }
grep -q "claudefiles:codex-review" "$hp/.claude/CLAUDE.md" || { echo FAIL codex-collateral; exit 1; }
unset CLAUDEFILES_CLAUDE_MD
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash skills/tools/test-claudemd.sh`
Expected: FAIL (`claudemd_personal_apply` undefined).

- [ ] **Step 3: Edit `lib/claudemd.sh`**

Change the file-resolution line in `claudemd_apply` from:
```bash
  local f="${CLAUDEFILES_CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"
```
to:
```bash
  local f="${CLAUDEFILES_CLAUDE_MD:-${CLAUDEFILES_TARGET:-$HOME/.claude}/CLAUDE.md}"
```

Then append a second, structurally-identical block manager for the personal style:

```bash
_PERSONAL_BEGIN="# >>> claudefiles:personal >>>"
_PERSONAL_END="# <<< claudefiles:personal <<<"
_PERSONAL_RULE='Write short and direct. No emojis. No em-dashes. Avoid "ensure", "leverage",
"robust", "seamless", "utilize". Cite file:line when referencing code. No code comments unless asked.'

claudemd_personal_apply() { # <enabled:true|false>
  local enabled="${1:-false}"
  local f="${CLAUDEFILES_CLAUDE_MD:-${CLAUDEFILES_TARGET:-$HOME/.claude}/CLAUDE.md}"
  [ "$enabled" != true ] && [ ! -f "$f" ] && return 0
  mkdir -p "$(dirname "$f")"
  local base=""
  [ -f "$f" ] && base="$(awk -v b="$_PERSONAL_BEGIN" -v e="$_PERSONAL_END" '
      $0==b{skip=1;next} $0==e{skip=0;next}
      !skip{a[++n]=$0; if(NF)last=n}
      END{for(i=1;i<=last;i++)print a[i]}' "$f")"
  {
    if [ "$enabled" = true ]; then
      [ -n "$base" ] && printf '%s\n\n' "$base"
      printf '%s\n%s\n%s\n' "$_PERSONAL_BEGIN" "$_PERSONAL_RULE" "$_PERSONAL_END"
    else
      [ -n "$base" ] && printf '%s\n' "$base"
    fi
  } > "$f"
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash skills/tools/test-claudemd.sh`
Expected: `PASS test-claudemd`

- [ ] **Step 5: Commit**

```bash
git add lib/claudemd.sh skills/tools/test-claudemd.sh
git commit -m "feat(claudemd): target-aware path + personal-style managed block"
```

---

## Task 6: Status line script

**Files:**
- Create: `claude/statusline/statusline.sh`
- Test: `skills/tools/test-statusline.sh`

**Interfaces:**
- Consumes: Claude Code statusLine JSON on stdin — exact paths `.model.display_name`, `.workspace.current_dir` (fallback `.cwd`), `.context_window.used_percentage`, `.effort.level`.
- Produces: one status line on stdout with ANSI colors: `model  dir branch*  ctx NN%  · effort`.

- [ ] **Step 1: Write the failing test**

Create `skills/tools/test-statusline.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
sl="$cf/claude/statusline/statusline.sh"
[ -x "$sl" ] || { echo "FAIL not-executable"; exit 1; }
json='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp/foo-bar-proj"},"context_window":{"used_percentage":42},"effort":{"level":"xhigh"}}'
out="$(printf '%s' "$json" | bash "$sl")"
echo "$out" | grep -q "Opus"       || { echo "FAIL no-model: $out"; exit 1; }
echo "$out" | grep -q "foo-bar-proj" || { echo "FAIL no-dir: $out"; exit 1; }
echo "$out" | grep -q "42%"        || { echo "FAIL no-ctx: $out"; exit 1; }
# missing optional fields must not crash and must exit 0
printf '%s' '{"model":{"display_name":"Sonnet"},"cwd":"/tmp/x"}' | bash "$sl" >/dev/null || { echo "FAIL crashed-on-sparse"; exit 1; }
echo "PASS test-statusline"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash skills/tools/test-statusline.sh`
Expected: FAIL `not-executable` (file missing).

- [ ] **Step 3: Create `claude/statusline/statusline.sh`**

```bash
#!/usr/bin/env bash
# Claude Code statusLine — light-theme friendly. Reads the status JSON on stdin.
# Parses with python3 (no jq dependency). Fields per Claude Code 2.1.x contract.
in="$(cat)"
parsed="$(printf '%s' "$in" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
m = (d.get("model") or {}).get("display_name", "?")
w = d.get("workspace") or {}
cur = w.get("current_dir") or d.get("cwd") or ""
cw = d.get("context_window") or {}
pct = cw.get("used_percentage")
eff = (d.get("effort") or {}).get("level", "")
print("\t".join([m, cur if cur else "-", str(pct) if pct is not None else "-", eff or "-"]))
')"
IFS=$'\t' read -r MODEL DIR PCT EFFORT <<<"$parsed"

base="${DIR##*/}"; [ -z "$base" ] && base="$DIR"

branch=""
if b="$(git -C "$DIR" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
  dirty=""; [ -n "$(git -C "$DIR" --no-optional-locks status --porcelain 2>/dev/null)" ] && dirty="*"
  branch=" ${b}${dirty}"
fi

ctx=""
if [ "$PCT" != "-" ]; then
  p="${PCT%%.*}"; [ -z "$p" ] && p=0
  col=$'\033[32m'; [ "$p" -ge 70 ] 2>/dev/null && col=$'\033[33m'; [ "$p" -ge 90 ] 2>/dev/null && col=$'\033[31m'
  ctx="  ${col}ctx ${p}%%\033[0m"
fi

eff=""; [ "$EFFORT" != "-" ] && [ -n "$EFFORT" ] && eff=" · ${EFFORT}"

# cyan model, blue dir, magenta branch
printf '\033[36m%s\033[0m \033[34m%s\033[0m\033[35m%s\033[0m'"$ctx"'\033[2m%s\033[0m\n' \
  "$MODEL" "$base" "$branch" "$eff"
```

- [ ] **Step 4: Make executable and run test to verify it passes**

Run: `chmod +x claude/statusline/statusline.sh && bash skills/tools/test-statusline.sh`
Expected: `PASS test-statusline`

- [ ] **Step 5: Commit**

```bash
git add claude/statusline/statusline.sh skills/tools/test-statusline.sh
git commit -m "feat(statusline): light-theme status line (model, dir, branch, ctx)"
```

---

## Task 7: `lib/profiles.sh` — recipes + credentials symlink + wrappers

**Files:**
- Create: `lib/profiles.sh`
- Test: `skills/tools/test-profiles.sh`

**Interfaces:**
- Consumes: all `*_apply` from Tasks 2-5, `build_servers.py`, `config_flag`, `config_path`, `claude_bin`, `CLAUDEFILES_TARGET`/`CLAUDE_CONFIG_DIR` (exported by the caller).
- Produces:
  - `profile_dir <name>` → `vanilla`→`$HOME/.claude`; else `$HOME/.claude-<name>`.
  - `recipe_vanilla <repo_root>` and `recipe_super <repo_root>`.
  - `ensure_credentials_symlink <target_dir>` — for non-default dirs, symlink `<dir>/.credentials.json` → `$HOME/.claude/.credentials.json` if absent.
  - `generate_wrapper <name> <target_dir>` — write executable `$HOME/.local/bin/claude-<name>`, guarded by a managed marker so an unmanaged user file is never clobbered.
  - `provision_selected <repo_root> <profile...>` — runs each recipe in its own subshell (env cannot leak to the caller), wires creds/wrapper on success, and reports failures via the `PROVISION_FAILED` array.

- [ ] **Step 1: Write the failing test**

Create `skills/tools/test-profiles.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
for m in common config settings skills mcp claudemd plugins profiles; do source "$cf/lib/$m.sh"; done
mkdir -p "$h/.config/claudefiles"
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"context7":false,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false},"context7_api_key":"" }
EOF

# profile_dir mapping
[ "$(profile_dir vanilla)" = "$h/.claude" ] || { echo FAIL dir-vanilla; exit 1; }
[ "$(profile_dir super)" = "$h/.claude-super" ] || { echo FAIL dir-super; exit 1; }

# credentials symlink: default dir untouched; non-default gets a symlink to default creds
printf 'CREDS' > "$h/.claude/.credentials.json"
ensure_credentials_symlink "$h/.claude"                       # default: no-op
[ -L "$h/.claude/.credentials.json" ] && { echo FAIL default-symlinked; exit 1; }
mkdir -p "$h/.claude-super"
ensure_credentials_symlink "$h/.claude-super"
[ -L "$h/.claude-super/.credentials.json" ] || { echo FAIL no-symlink; exit 1; }
[ "$(cat "$h/.claude-super/.credentials.json")" = "CREDS" ] || { echo FAIL symlink-target; exit 1; }

# wrapper: executable, exports CLAUDE_CONFIG_DIR
generate_wrapper super "$h/.claude-super"
w="$h/.local/bin/claude-super"
[ -x "$w" ] || { echo FAIL wrapper-not-exec; exit 1; }
grep -q 'CLAUDE_CONFIG_DIR=' "$w" || { echo FAIL wrapper-no-env; exit 1; }
grep -qF "$h/.claude-super" "$w" || { echo FAIL wrapper-no-dir; exit 1; }
grep -qF "claudefiles-managed-wrapper" "$w" || { echo FAIL wrapper-no-marker; exit 1; }

# P2b: an UNMANAGED existing claude-super is not clobbered
printf '#!/bin/sh\necho MINE\n' > "$h/.local/bin/claude-super"; chmod +x "$h/.local/bin/claude-super"
generate_wrapper super "$h/.claude-super"
grep -q "MINE" "$h/.local/bin/claude-super" || { echo FAIL clobbered-unmanaged-wrapper; exit 1; }
rm -f "$h/.local/bin/claude-super"

# P3: provision_selected runs recipes in subshells; env must NOT leak into THIS shell
provision_selected "$cf" vanilla
[ -z "${CLAUDEFILES_TARGET:-}" ] || { echo FAIL target-leaked-into-caller; exit 1; }
[ -z "${CLAUDE_CONFIG_DIR:-}" ] || { echo FAIL config-dir-leaked-into-caller; exit 1; }
[ "${#PROVISION_FAILED[@]}" -eq 0 ] || { echo FAIL vanilla-recipe-failed; exit 1; }
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["theme"]=="light";assert "enabledPlugins" not in d;print("ok vanilla-recipe")' "$h/.claude/settings.json"
[ -f "$h/.claude/skills/context7-mcp/SKILL.md" ] || { echo FAIL vanilla-skill; exit 1; }
grep -q "claudefiles:personal" "$h/.claude/CLAUDE.md" || { echo FAIL vanilla-claudemd; exit 1; }
echo "PASS test-profiles"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash skills/tools/test-profiles.sh`
Expected: FAIL (no `lib/profiles.sh`).

- [ ] **Step 3: Create `lib/profiles.sh`**

```bash
# profiles.sh — profile recipes + per-profile wiring. Source after the other lib/*.sh modules.
profile_dir() { # <name>
  case "$1" in vanilla) echo "$HOME/.claude" ;; *) echo "$HOME/.claude-$1" ;; esac
}

recipe_vanilla() { # <repo_root>  (caller exports CLAUDEFILES_TARGET + CLAUDE_CONFIG_DIR)
  local root="$1"
  settings_apply "$root/claude/settings/settings.vanilla.template.json" false false
  skills_apply "$root" false false
  claudemd_apply false               # drop codex nudge if migrating off super
  claudemd_personal_apply true
  local servers; servers="$(python3 "$root/claude/mcp/build_servers.py" "$(config_path)" vanilla)"
  mcp_apply "$servers" "$(_mcp_manifest vanilla)" "$(_mcp_legacy)"
}

recipe_super() { # <repo_root>
  local root="$1" dotnet cr cpe
  dotnet="$(config_flag dotnet_skills)"; cr="$(config_flag codex_review)"
  cpe=false; [ "$cr" = true ] && [ "$(config_flag codex_plugin)" = true ] && cpe=true
  settings_apply "$root/claude/settings/settings.super.template.json" "$dotnet" "$cpe"
  skills_apply "$root" "$dotnet" "$cr"
  claudemd_apply "$cr"
  claudemd_personal_apply false      # keep super's CLAUDE.md as before (personal block is vanilla-only)
  plugins_apply "$dotnet" "$cpe" || warn "super: plugins_apply reported an error (continuing to verify)"
  local servers; servers="$(python3 "$root/claude/mcp/build_servers.py" "$(config_path)")"
  mcp_apply "$servers" "$(_mcp_manifest super)"
  # P1a: super counts as successful ONLY if its core plugin is actually installed. plugins_apply
  # swallows install errors internally, so verify against reality. CLAUDE_CONFIG_DIR is already
  # exported to the super dir by the caller, so this checks the right profile.
  if command -v claude >/dev/null 2>&1; then
    claude plugin list 2>/dev/null | grep -q 'superpowers@' \
      || { warn "super: superpowers plugin missing after install — marking profile failed"; return 1; }
  else
    warn "super: claude not on PATH; cannot verify superpowers install"
  fi
}

ensure_credentials_symlink() { # <target_dir>
  local dir="$1" src="$HOME/.claude/.credentials.json"
  [ "$dir" = "$HOME/.claude" ] && return 0            # default dir owns the real file
  if [ -e "$dir/.credentials.json" ] || [ -L "$dir/.credentials.json" ]; then
    return 0                                           # idempotent; -L covers a dangling link
  fi
  mkdir -p "$dir"; ln -s "$src" "$dir/.credentials.json"
  log "linked credentials → $dir/.credentials.json"
}

_WRAPPER_MARKER="# claudefiles-managed-wrapper"
generate_wrapper() { # <name> <target_dir>
  local name="$1" dir="$2" bin="$HOME/.local/bin" w
  mkdir -p "$bin"; w="$bin/claude-$name"
  if [ -e "$w" ] && ! grep -qF "$_WRAPPER_MARKER" "$w" 2>/dev/null; then
    warn "$w exists and is not claudefiles-managed; leaving it untouched (P2b)"; return 0
  fi
  printf '#!/usr/bin/env bash\n%s\nexec env CLAUDE_CONFIG_DIR=%q claude "$@"\n' "$_WRAPPER_MARKER" "$dir" > "$w"
  chmod +x "$w"
  log "wrapper → $w"
}

provision_selected() { # <repo_root> <profile...>; sets PROVISION_FAILED=(); runs each recipe in a subshell
  local root="$1"; shift
  PROVISION_FAILED=()
  local p dir
  for p in "$@"; do
    dir="$(profile_dir "$p")"
    log "profile: $p → $dir"
    if ( export CLAUDEFILES_TARGET="$dir"; export CLAUDE_CONFIG_DIR="$dir"; "recipe_$p" "$root" ); then
      ensure_credentials_symlink "$dir"
      [ "$p" != vanilla ] && generate_wrapper "$p" "$dir"
    else
      warn "profile '$p' failed to provision"; PROVISION_FAILED+=("$p")
    fi
  done
}
```

Note on the credentials guard: it is written as an explicit `if` (not `[A] || [B] && return 0`) because under `setup.sh`'s `set -euo pipefail`, the AND-OR one-liner exits the shell when both tests are false. The `-L` test covers a dangling symlink.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash skills/tools/test-profiles.sh`
Expected: `PASS test-profiles`

- [ ] **Step 5: Commit**

```bash
git add lib/profiles.sh skills/tools/test-profiles.sh
git commit -m "feat(profiles): recipes, credentials symlink, wrapper generation"
```

---

## Task 8: `setup.sh` — profile menu, subshell loop, aggregation, readiness

**Files:**
- Modify: `setup.sh`
- Test: covered by Task 9's integration test.

**Interfaces:**
- Consumes: `lib/profiles.sh` and all modules; `config_*`.
- Produces: interactive/`--non-interactive` provisioning of the selected profiles; non-zero exit if a selected profile's recipe fails.

- [ ] **Step 1: Edit the module source list**

In `setup.sh`, change:
```bash
for m in common config deps settings skills plugins mcp hooks claudemd; do source "$ROOT/lib/$m.sh"; done
```
to:
```bash
for m in common config deps settings skills plugins mcp hooks claudemd profiles; do source "$ROOT/lib/$m.sh"; done
```

- [ ] **Step 2: Add the profile question to `config_ensure_all`**

Inside `config_ensure_all()` in `setup.sh`, add as the FIRST question:
```bash
  config_ensure_flag profile_super "Install the 'super' profile (full superpowers stack)? (y/N)"
```
Then wrap the existing super sub-flag questions (`dotnet_skills`, `codex_review`, `codex_plugin`, `playwright`, `azure_mcp`, `ado`, and their follow-ups) in:
```bash
  if [ "$(config_flag profile_super)" = true ]; then
    ...existing super sub-flag questions...
  fi
```
Keep `context7` + `context7_api_key` OUTSIDE the guard (vanilla uses context7 too).

- [ ] **Step 3: Replace the phase pipeline with the profile loop**

Replace the phase block (`log "3/9 deps"` … through `log "9/9 verify"` and the lines up to the final `log "Done…"`) with:

```bash
log "deps"
super_sel=false; [ "$(config_flag profile_super)" = true ] && super_sel=true
# P1b: deps derived from the SELECTED profiles. Vanilla always ships context7 (needs node/npx);
# super-only deps stay off unless super is selected, so stale super flags can't drive installs.
c7_dep=true
pw_dep=false; az_dep=false; ado_dep=false; dn_dep=false; cr_dep=false
if [ "$super_sel" = true ]; then
  pw_dep="$(config_flag playwright)"; az_dep="$(config_flag azure_mcp)"; ado_dep="$(config_flag ado)"
  dn_dep="$(config_flag dotnet_skills)"; cr_dep="$(config_flag codex_review)"
fi
deps_apply "$c7_dep" "$pw_dep" "$az_dep" "$ado_dep" "$dn_dep" "$cr_dep"

# P2a: existing ~/.claude carries the super stack but super was NOT selected -> it will be
# converted to vanilla. Warn loudly (state is regenerable; secrets are preserved).
if [ "$super_sel" != true ] && \
   python3 -c 'import json,sys,os; f=sys.argv[1]; d=json.load(open(f)) if os.path.exists(f) else {}; sys.exit(0 if d.get("enabledPlugins",{}).get("superpowers@claude-plugins-official") else 1)' \
     "$HOME/.claude/settings.json"; then
  warn "existing ~/.claude has the super stack but 'super' was not selected — converting it to vanilla. Re-run and choose super to keep the full stack."
fi

selected=(vanilla)
[ "$super_sel" = true ] && selected+=(super)

provision_selected "$ROOT" "${selected[@]}"        # subshell loop; recipe_super self-verifies superpowers (P1a)
failed=("${PROVISION_FAILED[@]}")

log "verify"
for p in "${selected[@]}"; do
  dir="$(profile_dir "$p")"
  python3 -m json.tool "$dir/settings.json" >/dev/null 2>&1 && log "  $p: settings.json valid" \
    || warn "  $p: settings.json invalid"
done

if [ "${#failed[@]}" -gt 0 ]; then
  warn "profiles failed: ${failed[*]}"; exit 1
fi
log "Done. \`claude\` = vanilla$( [ "$super_sel" = true ] && printf '%s' '; `claude-super` = full stack' )."
```

The old warn-only "runtime guard" is gone on purpose: `recipe_super` now hard-verifies the superpowers plugin (P1a) and returns non-zero if it's missing, so a broken super profile flows into `PROVISION_FAILED` and the non-zero exit — no silent green.

- [ ] **Step 4: Update the phase counter labels (cosmetic)**

The header still says `1/9`/`2/9`. Change `log "1/9 preflight"` → `log "preflight"` and `log "2/9 config"` → `log "config"` so counts do not mislead.

- [ ] **Step 5: Manual smoke (non-interactive, fake claude)**

Run:
```bash
bash skills/tools/test-setup-idempotent.sh
```
Expected: still `PASS test-setup-idempotent` after Task 9 updates it. (Until Task 9, this run may fail on new secrets keys — that is expected and fixed in Task 9.)

- [ ] **Step 6: Commit**

```bash
git add setup.sh
git commit -m "feat(setup): profile menu + subshell recipe loop + failure aggregation"
```

---

## Task 9: Integration, migration, and idempotency tests

**Files:**
- Create: `skills/tools/test-multiprofile.sh`
- Modify: `skills/tools/test-setup-idempotent.sh` (seed `profile_super`, assert both dirs)

**Interfaces:**
- Consumes: full `setup.sh` under fake `claude`.
- Produces: end-to-end guarantees — migration sweep, env non-leak, wrapper/creds wiring, second-run no-diff.

- [ ] **Step 1: Write the integration test**

Create `skills/tools/test-multiprofile.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"

# seed a "today's super" ~/.claude to exercise migration
mkdir -p "$h/.claude/skills/dotnet-router" "$h/.local/bin"
cat > "$h/.claude/settings.json" <<'EOF'
{ "model":"opus[1m]","effortLevel":"xhigh","theme":"dark",
  "enabledPlugins":{"superpowers@claude-plugins-official":true,"dotnet@dotnet-agent-skills":true},
  "hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/old/detect.sh"}]}]} }
EOF
printf 'CREDS' > "$h/.claude/.credentials.json"
mkdir -p "$h/.config/claudefiles"
printf '%s' '{"playwright":{"x":1},"context7":{"y":1}}' > "$h/.config/claudefiles/managed-mcp.json"
cat > "$h/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"profile_super":true,"context7":true,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
EOF

CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive

# vanilla (~/.claude) is clean
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert d["theme"]=="light", d.get("theme")
assert "enabledPlugins" not in d, "superpowers not stripped from vanilla"
assert "hooks" not in d, "stale hook survived in vanilla"
assert "model" not in d and "effortLevel" not in d, "heavy defaults not reset"
print("ok vanilla-clean")
PY
[ -e "$h/.claude/skills/dotnet-router" ] && { echo FAIL router-left; exit 1; }
[ -f "$h/.claude/skills/context7-mcp/SKILL.md" ] || { echo FAIL vanilla-c7; exit 1; }
grep -q "claudefiles:personal" "$h/.claude/CLAUDE.md" || { echo FAIL vanilla-personal; exit 1; }

# super (~/.claude-super) is full + wired
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["enabledPlugins"]["superpowers@claude-plugins-official"] is True;assert d["model"]=="opus[1m]";print("ok super-full")' "$h/.claude-super/settings.json"
[ -L "$h/.claude-super/.credentials.json" ] || { echo FAIL super-creds; exit 1; }
[ -x "$h/.local/bin/claude-super" ] || { echo FAIL wrapper; exit 1; }

# (env non-leak is proven in-process by test-profiles.sh via provision_selected; a child
#  `bash setup.sh` cannot leak exports back here regardless, so it is not re-asserted.)

# legacy MCP manifest consumed
[ -f "$h/.config/claudefiles/managed-mcp.json" ] && { echo FAIL legacy-left; exit 1; }

# second run: no diff in either settings.json, and user model in vanilla survives
python3 - "$h/.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1])); d["model"]="sonnet"; json.dump(d, open(sys.argv[1],"w"), indent=2)
PY
cp "$h/.claude-super/settings.json" "$h/super-first.json"
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive
diff "$h/super-first.json" "$h/.claude-super/settings.json" || { echo FAIL super-not-idempotent; exit 1; }
python3 -c 'import json,sys;assert json.load(open(sys.argv[1]))["model"]=="sonnet","user model clobbered"' "$h/.claude/settings.json"

# --- P2a: super stack present but NOT selected -> warn + convert to vanilla, still exit 0 ---
setup_fixture_home >/dev/null; h2="$HOME"
cat > "$h2/.claude/settings.json" <<'EOF'
{ "model":"opus[1m]","enabledPlugins":{"superpowers@claude-plugins-official":true} }
EOF
printf 'CREDS' > "$h2/.claude/.credentials.json"
mkdir -p "$h2/.config/claudefiles"
cat > "$h2/.config/claudefiles/secrets.json" <<'EOF'
{ "flags":{"profile_super":false,"context7":false,"playwright":false,"azure_mcp":false,"ado":false,"dotnet_skills":false,"codex_review":false,"codex_plugin":false},
  "context7_api_key":"", "ado":{"email":"","orgs":[],"pat":{}} }
EOF
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive 2> "$h2/err.log"
grep -q "not selected" "$h2/err.log" || { echo FAIL no-p2a-warning; exit 1; }
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert "enabledPlugins" not in d,"super not stripped when declined";print("ok p2a-converted")' "$h2/.claude/settings.json"
[ -e "$h2/.local/bin/claude-super" ] && { echo FAIL wrapper-when-declined; exit 1; }
echo "PASS test-multiprofile"
```

- [ ] **Step 2: Run it to verify it fails, then passes after wiring**

Run: `bash skills/tools/test-multiprofile.sh`
Expected before Task 8 is complete: FAIL. After Tasks 1-8: `PASS test-multiprofile`.

- [ ] **Step 3: Update `test-setup-idempotent.sh`**

In its seed `secrets.json`, add `"profile_super":true` to the `flags` object so the existing single-run idempotency test now provisions both profiles. Update its diff assertions to also diff `$h/.claude-super/settings.json` across the two runs (mirror the existing `settings.json` diff for the super dir).

- [ ] **Step 4: Run the whole suite**

Run: `bash skills/tools/run-all-tests.sh`
Expected: `ALL TESTS PASSED`

- [ ] **Step 5: Commit**

```bash
git add skills/tools/test-multiprofile.sh skills/tools/test-setup-idempotent.sh
git commit -m "test: multiprofile migration, env-non-leak, idempotency"
```

---

## Task 10: Update README

**Files:**
- Modify: `README.md`

**Interfaces:** documentation only.

- [ ] **Step 1: Rewrite the intro + phases**

Update the opening paragraph and the "Что делает setup.sh" section to describe profiles: `setup.sh` provisions `vanilla` (`~/.claude`, plain `claude`) always and `super` (`~/.claude-super`, `claude-super`) on selection; each profile is a recipe over the shared modules; migration strips today's super state off the default dir. Add a short "Профили" section with the table (vanilla vs super, dirs, invocation, contents) and the wrapper/credentials-symlink note.

- [ ] **Step 2: Update the layout block**

Reflect the new/renamed files from the File Structure section of this plan (`settings.vanilla/super.template.json`, `claude/statusline/statusline.sh`, `lib/profiles.sh`).

- [ ] **Step 3: Verify no stale references**

Run: `grep -n "settings.template.json" README.md`
Expected: no matches (all references updated to the split templates).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README — multi-profile (vanilla + super) provisioning"
```

---

## Self-Review

**Spec coverage:**
- Profiles + dirs (spec §Профили) → Tasks 1, 7, 8. ✓
- `CLAUDEFILES_TARGET` mechanism (spec §Механизм) → Tasks 2, 3, 5. ✓
- jsonmerge generalization + optional hook + delete-absent (spec §jsonmerge) → Task 2. ✓
- skills dotnet-router removal (spec §skills.sh) → Task 3. ✓
- MCP per-profile + legacy consumption + vanilla context7-only (spec §MCP, §Миграция) → Task 4. ✓
- Personal CLAUDE.md block + codex-block coexistence (spec §рецепт vanilla) → Task 5. ✓
- Statusline (spec §рецепт vanilla) → Task 6. ✓
- Credentials symlink, wrappers, recipes (spec §авторизация, §переключение, §поток) → Task 7. ✓
- Menu, subshell loop (P2c), failure aggregation (P2b), runtime guard (Open Q2) → Task 8. ✓
- Migration sweep + model/effort one-time reset + env-non-leak + idempotency (spec §Миграция, §Ошибки) → Tasks 2, 9. ✓
- P2a (super declined but super-state present): warning is folded directly into Task 8 Step 3 code, with an integration case in Task 9 (`profile_super=false` → warn + convert). ✓
- README (spec §Что в git) → Task 10. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; test bodies are concrete. ✓

**Type/signature consistency:**
- `settings_apply <template> <dotnet> <codex_plugin>` — Tasks 2, 7 agree. ✓
- `jsonmerge.py <template> <target> <dotnet> <codex_plugin>` — Task 2. ✓
- `skills_apply <root> <dotnet> <codex_review>` — Tasks 3, 7 agree. ✓
- `mcp_apply <servers> <manifest> [<prev>]`, `_mcp_manifest <name>`, `_mcp_legacy` — Tasks 4, 7 agree. ✓
- `build_servers.py <secrets> [profile]` — Tasks 4, 7 agree. ✓
- `claudemd_apply <enabled>`, `claudemd_personal_apply <enabled>` — Tasks 5, 7 agree. ✓
- `profile_dir/recipe_vanilla/recipe_super/ensure_credentials_symlink/generate_wrapper` — Tasks 7, 8 agree. ✓

**Codex round-2 fixes folded in:**
- **P1a** — `recipe_super` (Task 7) hard-verifies the superpowers plugin is installed and `return 1`s if not, so a swallowed plugin-install failure now flows into `PROVISION_FAILED` → non-zero exit. The old warn-only runtime guard is removed.
- **P1b** — deps in Task 8 are computed from the selected profiles (context7 always on for vanilla; super-only deps off unless super selected).
- **P1c** — `mcp_apply` (Task 4) early-returns only when `prev == manifest` or `prev` is absent, so a lingering legacy manifest is always consumed; a test covers manifest-current + legacy-present.
- **P2a** — warning folded into Task 8 Step 3 + integration case in Task 9.
- **P2b** — `generate_wrapper` (Task 7) refuses to overwrite an unmanaged file (managed marker); test in Task 7.
- **P3** — the loop is extracted into `provision_selected`; env non-leak is proven in-process in `test-profiles.sh`; the false-positive assertion was removed from `test-multiprofile.sh`.
