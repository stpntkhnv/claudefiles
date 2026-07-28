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

LINEAR = {"type": "http", "url": "https://mcp.linear.app/mcp"}

def context7_cfg():
    args = ["-y", "@upstash/context7-mcp"]
    if cfg.get("context7_api_key"):
        args += ["--api-key", cfg["context7_api_key"]]
    return {"type": "stdio", "command": "npx", "args": args}

servers = {}
profile = sys.argv[2] if len(sys.argv) > 2 else "all"
if profile in ("vanilla", "g"):          # vanilla and g always ship context7, regardless of flags
    servers["context7"] = context7_cfg()
    if on("linear"):
        servers["linear"] = LINEAR
    print(json.dumps(servers))
    sys.exit(0)
if on("playwright"):
    servers["playwright"] = {"type":"stdio","command":"npx",
        "args":["-y","@playwright/mcp@latest","--executable-path", chromium_path()]}
if on("context7"):
    servers["context7"] = context7_cfg()
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
if on("linear"):
    servers["linear"] = LINEAR
print(json.dumps(servers))
