#!/usr/bin/env bash
# Bootstrap the dotnet-router delivery system on this machine.
# Idempotent — safe to re-run (also the update path after `git pull`).
# Usage: ./setup.sh   (optionally CLAUDE_DIR=/custom/path ./setup.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"

echo "==> 1/5 dotnet-skills source clone"
if [ ! -d "$ROOT/skills/dotnet-skills/.git" ]; then
  git clone --depth 1 https://github.com/dotnet/skills "$ROOT/skills/dotnet-skills"
else
  git -C "$ROOT/skills/dotnet-skills" pull --ff-only || echo "WARN: pull failed, using existing checkout"
fi

echo "==> 2/5 generate catalog (absolute paths for this machine)"
"$ROOT/skills/tools/gen-dotnet-catalog.sh" "$ROOT/skills/dotnet-skills" "$ROOT/claude/skills/dotnet-router"

echo "==> 3/5 symlink skill into $CLAUDE_DIR/skills"
mkdir -p "$CLAUDE_DIR/skills"
dst="$CLAUDE_DIR/skills/dotnet-router"
if [ -e "$dst" ] && [ ! -L "$dst" ]; then
  echo "ERROR: $dst exists and is not a symlink — inspect its contents and remove it manually first" >&2
  exit 1
fi
ln -sfnT "$ROOT/claude/skills/dotnet-router" "$dst"

echo "==> 4/5 wire SessionStart hook into $CLAUDE_DIR/settings.json"
S="$CLAUDE_DIR/settings.json"
mkdir -p "$CLAUDE_DIR"
[ -f "$S" ] || echo '{}' > "$S"
cp "$S" "$S.bak-dotnet-router"
HOOK_CMD="$ROOT/claude/hooks/detect-dotnet.sh" python3 - "$S" <<'PY'
import json, os, sys
path = sys.argv[1]
cmd = os.environ["HOOK_CMD"]
cfg = json.load(open(path))
entries = cfg.setdefault("hooks", {}).setdefault("SessionStart", [])
already = any(h.get("command") == cmd
              for e in entries for h in e.get("hooks", []))
if already:
    print("hook: already wired")
else:
    entries.append({"hooks": [{"type": "command", "command": cmd}]})
    json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
    print("hook: wired")
PY

echo "==> 5/5 verify"
"$ROOT/skills/tools/test-gen-dotnet-catalog.sh"
"$ROOT/skills/tools/test-detect-dotnet.sh"
test -f "$dst/SKILL.md" && test -f "$dst/INDEX.md" && echo "skill+catalog reachable via $dst"
python3 -m json.tool "$S" > /dev/null && echo "settings.json valid"

echo
echo "Done. Restart Claude Code sessions to pick up the skill and hook."
echo "Optional (Roslyn LSP, needs .NET 10 SDK):"
echo "  claude plugin marketplace add dotnet/skills && claude plugin install dotnet@dotnet-agent-skills"
