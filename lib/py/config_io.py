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
