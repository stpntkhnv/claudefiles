#!/usr/bin/env python3
"""Own claudefiles' ENTRIES inside a profile settings.json, never a whole key.

Usage: kb_settings.py <settings.json> <manifest.json> [<vault_abs_path>]

An empty or absent vault means the feature is off: exactly what the manifest records is removed and
the manifest is deleted. jsonmerge.py cannot do this — it replaces a managed key wholesale, which
would drop the user's own env vars and permission rules living under the same two keys."""
import json, os, sys

ENV_KEY = "CLAUDE_CODE_REMOTE_MEMORY_DIR"

def load(path, default):
    try:
        with open(path) as f: return json.load(f)
    except FileNotFoundError:
        return default
    except json.JSONDecodeError as e:
        sys.stderr.write(f"corrupt JSON in {path}: {e}\n"); sys.exit(2)

def pattern(vault):
    # A single leading slash anchors at the settings source, not at the filesystem root, so an
    # absolute vault has to be written as //path/** and a vault under $HOME as ~/path/**.
    home = os.path.expanduser("~").rstrip("/")
    if vault == home or vault.startswith(home + "/"):
        rest = vault[len(home):].strip("/")
        return f"~/{rest}/**" if rest else "~/**"
    return f"//{vault.lstrip('/')}/**"

settings_path, manifest_path = sys.argv[1], sys.argv[2]
vault = (sys.argv[3].rstrip("/") if len(sys.argv) > 3 else "")

prev = load(manifest_path, {})
if not vault and not prev:
    # Off and nothing of ours on record: touching settings.json would only reformat a file we have
    # no business rewriting. Every profile takes this path on every run with the feature disabled.
    sys.exit(0)

s = load(settings_path, {})
prev_env = list(prev.get("env") or [])
prev_env_values = dict(prev.get("env_prev") or {})
prev_allow = list(prev.get("permissions_allow") or [])

env = dict(s.get("env") or {})
for k in prev_env:
    # A value the user had set for the same key before we took it over is put back, not dropped.
    if k in prev_env_values: env[k] = prev_env_values[k]
    else:                    env.pop(k, None)
perms = dict(s.get("permissions") or {})
allow = [e for e in (perms.get("allow") or []) if e not in prev_allow]

new_env, new_allow, saved_env = [], [], {}
if vault:
    if ENV_KEY in env and env[ENV_KEY] != vault:
        saved_env[ENV_KEY] = env[ENV_KEY]
        sys.stderr.write(f"kb: replacing an existing {ENV_KEY}={env[ENV_KEY]!r}\n")
    env[ENV_KEY] = vault
    new_env = [ENV_KEY]
    p = pattern(vault)
    for entry in (f"Read({p})", f"Edit({p})", f"Write({p})"):
        if entry in allow:
            # Already present. Claim it only if we are the ones who added it earlier, so a rule the
            # user wrote by hand is never removed when the feature is switched off.
            if entry in prev_allow:
                new_allow.append(entry)
            continue
        allow.append(entry)
        new_allow.append(entry)

if env: s["env"] = env
else:   s.pop("env", None)
if allow: perms["allow"] = allow
else:     perms.pop("allow", None)
if perms: s["permissions"] = perms
else:     s.pop("permissions", None)

os.makedirs(os.path.dirname(settings_path) or ".", exist_ok=True)
tmp = settings_path + ".kbtmp"
with open(tmp, "w") as f:
    json.dump(s, f, indent=2)
os.replace(tmp, settings_path)

if new_env or new_allow:
    os.makedirs(os.path.dirname(manifest_path) or ".", exist_ok=True)
    fd = os.open(manifest_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"env": new_env, "env_prev": saved_env, "permissions_allow": new_allow}, f, indent=2)
else:
    try:
        os.unlink(manifest_path)
    except FileNotFoundError:
        pass
