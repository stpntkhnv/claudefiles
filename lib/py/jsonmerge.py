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
