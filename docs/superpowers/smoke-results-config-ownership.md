# Smoke results — claudefiles config ownership

## Real-host apply (migration + live setup.sh)

Seeded `~/.config/claudefiles/secrets.json` from the **live** state (chezmoi.toml was stale:
`context7_api_key` empty, `setup_dotnet_skills=False` — a naive migration would have wiped the
context7 key and disabled dotnet), then ran `./setup.sh --non-interactive` on the host. Verified:

- SessionStart hook fixed: `~/devTools/...` → `~/dev/claudefiles/claude/hooks/detect-dotnet.sh`
- `dotnet-router` symlink repointed (was dangling after the rename) and resolves (INDEX reachable)
- both plugins enabled (`superpowers`, `dotnet`)
- **context7 API key preserved** (`✔ Connected`), playwright intact, claude.ai connectors untouched
- `secrets.json` + `managed-mcp.json` both `chmod 600`; no plugin reinstall

## Fresh-machine container smoke (isolated podman, debian:stable-slim)

Fresh clone of the **public** repo + stub `claude`, `setup.sh --non-interactive`, twice. All PASS:

- `dotnet-skills` **CLONED by setup.sh** (clone-if-missing path — not exercised on the host)
- dotnet-router catalog generated; symlink created; context7-mcp installed
- `settings.json` written with correct hook; MCP manifest written (`600`)
- 2nd run: `settings.json` byte-identical (idempotent)
- 2nd run: **repo tree clean** (deterministic catalog, gitignored)

## Bugs caught by the smoke (fixed)

1. `gen-dotnet-catalog.sh` stamped `Generated: <date>` → every run re-dirtied `INDEX.md` (blocked
   branch checkout/merge). Removed the date stamp → deterministic.
2. The generated catalog was tracked with machine-specific absolute paths → every checkout dirtied by
   `setup.sh`, breaking the deploy copy's `git pull --ff-only` refresh. Gitignored the catalog;
   `skills_apply` generates it. `SKILL.md` stays tracked.
