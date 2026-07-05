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
except json.JSONDecodeError as e:
    sys.stderr.write(f"corrupt JSON in {target}: {e}\n"); sys.exit(2)
out = dict(existing)              # keep unknown keys
for k in MANAGED:                 # replace managed keys wholesale
    out[k] = managed[k]
os.makedirs(os.path.dirname(target), exist_ok=True)
json.dump(out, open(target, "w"), indent=2)
