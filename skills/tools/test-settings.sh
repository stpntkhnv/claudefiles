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
assert d["statusLine"]["command"]==f"{cf}/claude/statusline/statusline.sh super", "super statusline arg not rendered"
cmd=d["hooks"]["SessionStart"][0]["hooks"][0]["command"]
assert cmd==f"{cf}/claude/hooks/detect-dotnet.sh", f"hook not rendered: {cmd}"
assert d["hooks"]["Stop"][0]["hooks"][0]["command"]==f"paplay {cf}/claude/sounds/ready.wav >/dev/null 2>&1", "super Stop sound not rendered"
assert d["hooks"]["Notification"][0]["hooks"][0]["command"]==f"paplay {cf}/claude/sounds/ready.wav >/dev/null 2>&1", "super Notification sound not rendered"
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
assert d["statusLine"]["command"]==f"{cf}/claude/statusline/statusline.sh vanilla", "vanilla statusline arg not rendered"
assert "enabledPlugins" not in d, "super plugins not removed"
assert "SessionStart" not in d["hooks"], "stale super SessionStart hook not removed"
assert set(d["hooks"]) == {"Stop", "Notification"}, "vanilla notification hooks not applied"
assert d["hooks"]["Stop"][0]["hooks"][0]["command"] == f"paplay {cf}/claude/sounds/ready.wav >/dev/null 2>&1", "sound path not rendered"
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
