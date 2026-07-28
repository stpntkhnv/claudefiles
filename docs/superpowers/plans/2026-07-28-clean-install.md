# Clean Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дать `setup.sh` режим чистой установки: снести управляемую конфиг-поверхность выбранных профилей и все сохранённые ответы, после чего собрать конфигурацию из репозитория заново.

**Architecture:** Clean это проход удаления, а не второй установщик. Новый модуль `lib/clean.sh` только стирает; рецепты `recipe_vanilla/super/g` не меняются ни на строку и восстанавливают всё сами: снесённый `settings.json` заставляет `jsonmerge.py` увидеть `existing={}` и выдать ровно шаблон, снесённый манифест заставляет `mcp_apply` добавить серверы заново. Две фазы: фаза A (до опроса конфига) сносит `secrets.json` и манифесты, фаза B (внутри `provision_selected`, после ответов) сносит поверхность каждого выбранного профиля.

**Tech Stack:** bash 5 под `set -euo pipefail`, python3 для работы с JSON, существующий фикстурный тест-харнесс `skills/tools/lib/faketools.bash`.

**Спека:** `docs/superpowers/specs/2026-07-28-clean-install-design.md`

## Global Constraints

- Все модули в `lib/` это библиотеки: `# module.sh — ...` первой строкой, `Source, don't execute.` в шапке, никакого кода верхнего уровня кроме объявлений.
- `setup.sh` работает под `set -euo pipefail`. Ни одна новая функция не должна ронять прогон непреднамеренно: возврат ненулевого кода это всегда осознанное решение.
- Строки, которые видит пользователь в шелле, английские (как весь существующий код). Русский только в `docs/` и `README.md`.
- Комментарии в стиле репозитория: объясняют ПОЧЕМУ так, а не что делает строка. Плотность как в соседних модулях.
- `log`/`warn`/`die` из `lib/common.sh`, никаких голых `echo` в модулях.
- Все пути к профилям только через `profile_dir`, к конфигу только через `config_path` / `CLAUDEFILES_CONFIG_DIR`, к манифестам только через `_mcp_manifest`.
- Тесты: bash-скрипты `skills/tools/test-*.sh`, падение через `{ echo "FAIL <что>"; exit 1; }`, последняя строка `echo "PASS <имя>"`. Запуск всей сьюты: `bash skills/tools/run-all-tests.sh`.
- Тесты никогда не трогают реальный `~/.claude`: только `setup_fixture_home` из `faketools.bash`, вызванный НЕ в подстановке команд.
- Ни один тест не требует сети: `CLAUDEFILES_CLEAN_SKIP_NET=1` плюс локальный bare-репозиторий как апстрим gstack.

## Файловая структура

| Файл | Ответственность |
|---|---|
| `lib/clean.sh` (создать) | Ластик: подтверждение, clean-preflight, бэкап, снос глобального состояния и поверхности профиля, аудит результата. Логики установки нет. |
| `setup.sh` (править) | Фаза A в нужной точке порядка, прокидывание флага в провижн, warn о невыбранных профилях, печать пути бэкапа. |
| `lib/profiles.sh` (править) | Фаза B: печать разрешённого списка и вызов `clean_profile` перед рецептом внутри субшелла. |
| `skills/tools/test-clean.sh` (создать) | Юнит-тесты модуля: гейты, бэкап, снос, аудит. |
| `skills/tools/test-setup-idempotent.sh` (править) | Сквозной clean-прогон через настоящий `setup.sh` плюс проверка идемпотентности после него. |
| `docs/invariants.md`, `docs/user-flow.md`, `docs/architecture.md`, `README.md` (править) | Документация режима. |

---

### Task 1: Гейты — подтверждение и clean-preflight

Первый кусок `lib/clean.sh`: решить, нужен ли clean, и убедиться, что машина сможет собраться обратно. Ни одного удаления в этой задаче.

**Files:**
- Create: `lib/clean.sh`
- Create: `skills/tools/test-clean.sh`

**Interfaces:**
- Consumes: `log`/`warn`/`die` (`lib/common.sh`), `_has_tty` (`lib/config.sh:15`), `_claude_present` (`lib/deps.sh:102`), `profile_dir` (`lib/profiles.sh:2`).
- Produces: `clean_wanted` (0 = пользователь подтвердил чистую установку), `clean_preflight` (0 или `die`), `_clean_paths_announce` (внутренняя печать списка), массив `_CLEAN_PATHS`.

- [ ] **Step 1: Написать падающий тест**

Создать `skills/tools/test-clean.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
# root ignores file modes, which would silently defeat the fail-closed and chmod assertions below
[ "$(id -u)" -eq 0 ] && { echo "SKIP test-clean (running as root)"; exit 0; }
source "$cf/skills/tools/lib/faketools.bash"; setup_fixture_home >/dev/null; h="$HOME"
for m in common config deps settings skills mcp claudemd plugins gstack profiles clean; do source "$cf/lib/$m.sh"; done
export CLAUDEFILES_CONFIG_DIR="$h/.config/claudefiles"; mkdir -p "$CLAUDEFILES_CONFIG_DIR"
export CLAUDEFILES_CLEAN_SKIP_NET=1

# --- clean_wanted: the gate. Nothing here may delete anything.
# no TTY, no force -> plain update (silent, no die)
if CLAUDEFILES_ASSUME_TTY=0 clean_wanted >/dev/null 2>&1; then echo "FAIL no-tty-wanted"; exit 1; fi
# no TTY + force -> die: wiping every answer with no way to re-enter them bricks the machine
if (CLAUDEFILES_ASSUME_TTY=0 CLAUDEFILES_CLEAN=1 clean_wanted) >/dev/null 2>&1; then
  echo "FAIL force-no-tty-should-die"; exit 1; fi
# TTY, declined
if printf 'n\n' | CLAUDEFILES_ASSUME_TTY=1 clean_wanted >/dev/null 2>&1; then echo "FAIL declined-still-wanted"; exit 1; fi
# TTY, y but the confirmation word is wrong -> declined
if printf 'y\nyes\n' | CLAUDEFILES_ASSUME_TTY=1 clean_wanted >/dev/null 2>&1; then echo "FAIL wrong-word-accepted"; exit 1; fi
# TTY, y + the word
printf 'y\nclean\n' | CLAUDEFILES_ASSUME_TTY=1 clean_wanted >/dev/null 2>&1 || { echo "FAIL confirmed-not-wanted"; exit 1; }
# force answers the y/N question only; the word is still required
printf 'clean\n' | CLAUDEFILES_ASSUME_TTY=1 CLAUDEFILES_CLEAN=1 clean_wanted >/dev/null 2>&1 || { echo "FAIL force-not-wanted"; exit 1; }
# the announcement names what survives, so the user can judge the blast radius
out="$(printf 'y\nclean\n' | CLAUDEFILES_ASSUME_TTY=1 clean_wanted 2>&1)"
printf '%s' "$out" | grep -qF '.credentials.json' || { echo "FAIL announce-missing-kept"; exit 1; }
printf '%s' "$out" | grep -qF 'settings.json'     || { echo "FAIL announce-missing-removed"; exit 1; }

# --- clean_preflight: hard gates, because a clean profile is rebuilt from the network
if (PATH="$h/empty-bin" clean_preflight) >/dev/null 2>&1; then echo "FAIL preflight-without-claude"; exit 1; fi
mkdir -p "$h/netbin"; printf '#!/usr/bin/env bash\nexit 1\n' > "$h/netbin/git"; chmod +x "$h/netbin/git"
if (PATH="$h/netbin:$PATH" CLAUDEFILES_CLEAN_SKIP_NET=0 clean_preflight) >/dev/null 2>&1; then
  echo "FAIL preflight-ignores-unreachable-github"; exit 1; fi
clean_preflight >/dev/null 2>&1 || { echo "FAIL preflight-rejects-good-env"; exit 1; }

echo "PASS test-clean"
```

- [ ] **Step 2: Запустить тест, убедиться что падает**

Run: `bash skills/tools/test-clean.sh`
Expected: FAIL, `lib/clean.sh: No such file or directory`.

- [ ] **Step 3: Написать `lib/clean.sh`**

```bash
# clean.sh — the eraser behind a clean install. It deletes the managed config surface of a profile
# so the UNCHANGED recipes rebuild it from the repo: a missing settings.json makes jsonmerge see
# existing={} and emit exactly the template, a missing manifest makes mcp_apply re-add every
# server. Nothing here installs anything. Source, don't execute.

# Per-profile config surfaces. A fixed denylist, deliberately NOT "remove everything unknown":
# Claude Code keeps adding state dirs (sessions/, file-history/, tasks/), and an allowlist would
# eventually eat credentials or transcripts. settings.json.bak* is a glob, handled separately.
_CLEAN_PATHS=(settings.json settings.local.json CLAUDE.md skills plugins rules agents commands output-styles .gstack-setup-head)

_clean_paths_announce() {   # what the user is about to lose, and what they keep
  local p d
  log "clean install will remove:"
  printf '  %s\n' "$(config_path)" "${CLAUDEFILES_CONFIG_DIR:-$HOME/.config/claudefiles}/managed-mcp*.json"
  printf '  in every profile you select next: %s, settings.json.bak*, and every user-scope MCP server\n' "${_CLEAN_PATHS[*]}"
  for p in vanilla super g; do
    d="$(profile_dir "$p")"; [ -d "$d" ] && printf '  on disk now: %s\n' "$d"
  done
  printf '  kept: .credentials.json, .claude.json (minus mcpServers), projects/, history.jsonl, sessions/, caches\n'
  return 0
}

clean_wanted() {   # 0 = the user asked for a clean install. Asked EVERY run, never persisted:
                   # config_ensure_flag would make it prompt-once and silently stick.
  if ! _has_tty; then
    # CLAUDEFILES_CLEAN forces the y/N answer, not the TTY: clean wipes every stored answer, and
    # they can only be re-entered interactively. Wiping first and dying in config_ensure_flag
    # (config.sh:54) would leave the machine with no configuration at all.
    [ "${CLAUDEFILES_CLEAN:-0}" = 1 ] && die "clean install needs a TTY: it wipes every stored answer"
    return 1
  fi
  local a=y
  if [ "${CLAUDEFILES_CLEAN:-0}" != 1 ]; then
    read -r -p "Clean install? Wipes the selected profiles' config and every stored answer. (y/N) " a || true
  fi
  case "${a,,}" in y|yes) ;; *) return 1 ;; esac
  _clean_paths_announce
  local c; read -r -p "Type 'clean' to confirm: " c || true
  [ "$c" = clean ] || { log "clean install cancelled — continuing with a normal update"; return 1; }
  return 0
}

clean_preflight() {   # hard gates: a cleaned profile is rebuilt from the network, so refuse to
                      # start the demolition we cannot finish. Both paths die BEFORE any deletion.
  _claude_present || die "clean install needs the claude CLI: MCP servers and plugins are reconciled through it"
  if [ "${CLAUDEFILES_CLEAN_SKIP_NET:-0}" = 1 ]; then
    warn "clean: network probe skipped (CLAUDEFILES_CLEAN_SKIP_NET=1)"
    return 0
  fi
  timeout 15 git ls-remote https://github.com/anthropics/claude-plugins-official HEAD >/dev/null 2>&1 \
    || die "clean install needs network: github is unreachable and a cleaned profile is rebuilt from it (override: CLAUDEFILES_CLEAN_SKIP_NET=1)"
  return 0
}
```

- [ ] **Step 4: Запустить тест, убедиться что проходит**

Run: `bash skills/tools/test-clean.sh`
Expected: `PASS test-clean`

- [ ] **Step 5: Прогнать всю сьюту (регрессия)**

Run: `bash skills/tools/run-all-tests.sh`
Expected: `ALL TESTS PASSED`. Модуль ещё никем не подключён, поэтому падений быть не должно.

- [ ] **Step 6: Коммит**

```bash
git add lib/clean.sh skills/tools/test-clean.sh
git commit -m "feat(clean): confirmation gate and clean-only preflight"
```

---

### Task 2: Бэкап и снос глобального состояния

Бэкап это весь предохранитель режима, поэтому он fail-closed: любая ошибка копирования означает `die` до первого удаления.

**Files:**
- Modify: `lib/clean.sh`
- Modify: `skills/tools/test-clean.sh`

**Interfaces:**
- Consumes: `config_path`, `CLAUDEFILES_CONFIG_DIR`, `log`/`warn`/`die`.
- Produces: `clean_backup_open [<stamp>]` (экспортирует `CLAUDEFILES_CLEAN_BACKUP`), `clean_backup_take <src> <rel_dest>`, `clean_global`.

- [ ] **Step 1: Написать падающий тест**

Вставить в `skills/tools/test-clean.sh` перед строкой `echo "PASS test-clean"`:

```bash
# --- backup + global wipe
printf '{"flags":{"context7":true}}' > "$CLAUDEFILES_CONFIG_DIR/secrets.json"; chmod 600 "$CLAUDEFILES_CONFIG_DIR/secrets.json"
printf '{"context7":{}}' > "$CLAUDEFILES_CONFIG_DIR/managed-mcp.vanilla.json"
printf '{"context7":{}}' > "$CLAUDEFILES_CONFIG_DIR/managed-mcp.json"
clean_backup_open 20260728-000000 >/dev/null
b="$CLAUDEFILES_CLEAN_BACKUP"
[ -d "$b" ] || { echo "FAIL backup-dir-missing"; exit 1; }
[ "$(stat -c %a "$b")" = 700 ] || { echo "FAIL backup-dir-mode"; exit 1; }
clean_global >/dev/null
[ -e "$CLAUDEFILES_CONFIG_DIR/secrets.json" ] && { echo "FAIL secrets-survived"; exit 1; }
[ -e "$CLAUDEFILES_CONFIG_DIR/managed-mcp.vanilla.json" ] && { echo "FAIL manifest-survived"; exit 1; }
[ -e "$CLAUDEFILES_CONFIG_DIR/managed-mcp.json" ] && { echo "FAIL legacy-manifest-survived"; exit 1; }
[ -f "$b/global/secrets.json" ] || { echo "FAIL secrets-not-backed-up"; exit 1; }
[ "$(stat -c %a "$b/global/secrets.json")" = 600 ] || { echo "FAIL backup-secrets-mode"; exit 1; }
[ -f "$b/global/managed-mcp.vanilla.json" ] || { echo "FAIL manifest-not-backed-up"; exit 1; }

# fail-closed: a backup that cannot be written must abort BEFORE anything is deleted
printf '{"flags":{}}' > "$CLAUDEFILES_CONFIG_DIR/secrets.json"
chmod 500 "$b"
if (clean_global) >/dev/null 2>&1; then chmod 700 "$b"; echo "FAIL backup-not-fail-closed"; exit 1; fi
chmod 700 "$b"
[ -f "$CLAUDEFILES_CONFIG_DIR/secrets.json" ] || { echo "FAIL deleted-despite-backup-failure"; exit 1; }

# taking a missing source is a no-op, not a failure: absent files are the normal case
clean_backup_take "$CLAUDEFILES_CONFIG_DIR/nope.json" "global/nope.json" || { echo "FAIL take-missing-src"; exit 1; }
[ -e "$b/global/nope.json" ] && { echo "FAIL invented-backup"; exit 1; }
```

- [ ] **Step 2: Запустить тест, убедиться что падает**

Run: `bash skills/tools/test-clean.sh`
Expected: FAIL, `clean_backup_open: command not found`.

- [ ] **Step 3: Дописать `lib/clean.sh`**

Добавить после `clean_preflight`:

```bash
clean_backup_open() {   # [<stamp>] — open the run's backup dir. die on failure: the confirmation
                        # plus this backup ARE the safety net of the mode.
  local stamp="${1:-$(date +%Y%m%d-%H%M%S)}"
  local dir="${CLAUDEFILES_CONFIG_DIR:-$HOME/.config/claudefiles}/clean-backups/$stamp"
  mkdir -p "$dir" || die "clean: cannot create backup dir $dir"
  chmod 700 "$dir" || die "clean: cannot chmod 700 $dir"
  export CLAUDEFILES_CLEAN_BACKUP="$dir"
  log "clean: backup → $dir"
}

clean_backup_take() {   # <src> <rel_dest> — copy into the backup preserving modes. A missing src
                        # is normal (nothing to keep); a FAILED copy is fatal, never a warning.
  local src="$1" rel="$2" dst
  [ -e "$src" ] || [ -L "$src" ] || return 0
  [ -n "${CLAUDEFILES_CLEAN_BACKUP:-}" ] || die "clean: backup dir not open (call clean_backup_open first)"
  dst="$CLAUDEFILES_CLEAN_BACKUP/$rel"
  mkdir -p "$(dirname "$dst")" || die "clean: cannot create $(dirname "$dst")"
  # rm first: `cp -a src dir` where dir already exists copies INTO it, which would nest a second
  # copy on a repeated take instead of replacing the first.
  rm -rf "$dst"
  cp -a "$src" "$dst" || die "clean: backup of $src failed — refusing to delete anything"
  return 0
}

clean_global() {   # phase A: the stored answers and the MCP manifests. Runs BEFORE config_ensure_all,
                   # so the run re-asks everything instead of wiping answers it just collected.
  local cfg="${CLAUDEFILES_CONFIG_DIR:-$HOME/.config/claudefiles}" f
  clean_backup_take "$cfg/secrets.json" "global/secrets.json"
  for f in "$cfg"/managed-mcp*.json; do
    [ -e "$f" ] || continue
    clean_backup_take "$f" "global/$(basename "$f")"
  done
  rm -f "$cfg/secrets.json" "$cfg"/managed-mcp*.json
  log "clean: stored answers and MCP manifests wiped"
}
```

- [ ] **Step 4: Запустить тест, убедиться что проходит**

Run: `bash skills/tools/test-clean.sh`
Expected: `PASS test-clean`

- [ ] **Step 5: Коммит**

```bash
git add lib/clean.sh skills/tools/test-clean.sh
git commit -m "feat(clean): fail-closed backup and global state wipe"
```

---

### Task 3: Снос поверхности профиля

Ядро режима. Включает bun-гард для профиля `g` (не сносить то, что заведомо не соберётся обратно) и точечную операцию над легаси `~/.claude.json`.

**Files:**
- Modify: `lib/clean.sh`
- Modify: `skills/tools/test-clean.sh`

**Interfaces:**
- Consumes: `claude_bin` (`lib/common.sh:6`), `CLAUDEFILES_TARGET`, `clean_backup_take`.
- Produces: `clean_profile <name>` (0 = вычищено, 1 = отказ или ошибка), `_clean_have_bun` (переопределяемая в тестах), `_clean_mcp_names <claude_json>`, `_clean_backup_skills <dir> <name>`, `_clean_mcp_purge <name> <dir>`.

- [ ] **Step 1: Написать падающий тест**

Вставить в `skills/tools/test-clean.sh` перед `echo "PASS test-clean"`:

```bash
# --- clean_profile: the demolition itself
d="$h/.claude"
mkdir -p "$d/skills/ges-esp" "$d/skills/context7-mcp" "$d/skills/gstack/foo" \
         "$d/rules" "$d/agents" "$d/plugins/repos" "$d/projects/x" "$d/sessions"
printf 'STRAY' > "$d/skills/ges-esp/SKILL.md"
printf 'GSTACK' > "$d/skills/gstack/foo/SKILL.md"
printf '{"a":1}' > "$d/settings.json"
printf 'LOCAL' > "$d/settings.local.json"
printf 'BAK' > "$d/settings.json.bak.20260101-000000"
printf 'hand-written' > "$d/CLAUDE.md"
printf 'RULE' > "$d/rules/context7.md"
printf 'PLUG' > "$d/plugins/config.json"
printf 'CREDS' > "$d/.credentials.json"
printf 'HIST' > "$d/history.jsonl"
printf 'HEAD' > "$d/.gstack-setup-head"
python3 -c 'import json,sys;json.dump({"mcpServers":{"context7":{},"stray":{}},"oauthAccount":{"e":"x"}},open(sys.argv[1],"w"))' "$d/.claude.json"
# legacy ~/.claude.json: pre-CLAUDE_CONFIG_DIR layout, still carries mcpServers for the default profile
python3 -c 'import json,sys;json.dump({"mcpServers":{"old":{}},"oauthAccount":{"e":"x"},"projects":{"p":1}},open(sys.argv[1],"w"))' "$h/.claude.json"
chmod 600 "$h/.claude.json"

: > "$CLAUDE_FAKE_LOG"
( export CLAUDEFILES_TARGET="$d" CLAUDE_CONFIG_DIR="$d"; clean_profile vanilla ) >/dev/null \
  || { echo "FAIL clean_profile-vanilla-failed"; exit 1; }

for gone in settings.json settings.local.json settings.json.bak.20260101-000000 CLAUDE.md \
            skills plugins rules agents .gstack-setup-head; do
  [ -e "$d/$gone" ] && { echo "FAIL survived: $gone"; exit 1; }
done
for kept in .credentials.json history.jsonl projects/x sessions .claude.json; do
  [ -e "$d/$kept" ] || { echo "FAIL destroyed: $kept"; exit 1; }
done
# every user-scope server is dropped, not only the ones our manifest owns
grep -qF 'mcp remove --scope user context7' "$CLAUDE_FAKE_LOG" || { echo "FAIL mcp-ours-not-removed"; exit 1; }
grep -qF 'mcp remove --scope user stray'    "$CLAUDE_FAKE_LOG" || { echo "FAIL mcp-stray-not-removed"; exit 1; }
# legacy file: only mcpServers goes, everything else and the mode survive
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert "mcpServers" not in d,d;assert d["oauthAccount"]=={"e":"x"};assert d["projects"]=={"p":1}' "$h/.claude.json" \
  || { echo "FAIL legacy-surgery"; exit 1; }
[ "$(stat -c %a "$h/.claude.json")" = 600 ] || { echo "FAIL legacy-mode-changed"; exit 1; }
# backup: strays are recoverable, the multi-GB gstack clone is not copied
[ -f "$b/vanilla/skills/ges-esp/SKILL.md" ] || { echo "FAIL stray-not-backed-up"; exit 1; }
[ -f "$b/vanilla/CLAUDE.md" ] || { echo "FAIL claudemd-not-backed-up"; exit 1; }
[ -f "$b/vanilla/plugins/config.json" ] || { echo "FAIL plugins-not-backed-up"; exit 1; }
[ -e "$b/vanilla/skills/gstack" ] && { echo "FAIL gstack-clone-copied-into-backup"; exit 1; }

# an already-clean directory is not an error: absent files are the normal steady state
( export CLAUDEFILES_TARGET="$d" CLAUDE_CONFIG_DIR="$d"; clean_profile vanilla ) >/dev/null \
  || { echo "FAIL clean_profile-not-idempotent"; exit 1; }

# profile g without bun: refuse and touch NOTHING — gstack_apply exits early without bun
# (gstack.sh:53), so wiping the clone we cannot reinstall is the one unrecoverable move.
gd="$h/.claude-g"; mkdir -p "$gd/skills/gstack"; printf 'HEAD' > "$gd/.gstack-setup-head"
printf '{"b":2}' > "$gd/settings.json"
_clean_have_bun() { return 1; }                 # shadows the real check, like test-profiles.sh does
if ( export CLAUDEFILES_TARGET="$gd" CLAUDE_CONFIG_DIR="$gd"; clean_profile g ) >/dev/null 2>&1; then
  echo "FAIL g-cleaned-without-bun"; exit 1; fi
[ -d "$gd/skills/gstack" ] || { echo "FAIL g-clone-removed-without-bun"; exit 1; }
[ -f "$gd/.gstack-setup-head" ] || { echo "FAIL g-marker-removed-without-bun"; exit 1; }
[ -f "$gd/settings.json" ] || { echo "FAIL g-settings-removed-without-bun"; exit 1; }
unset -f _clean_have_bun
```

- [ ] **Step 2: Запустить тест, убедиться что падает**

Run: `bash skills/tools/test-clean.sh`
Expected: FAIL, `clean_profile: command not found`.

- [ ] **Step 3: Дописать `lib/clean.sh`**

Добавить после `clean_global`:

```bash
_clean_have_bun() { command -v bun >/dev/null 2>&1; }   # a seam: tests shadow this instead of PATH

_clean_mcp_names() {   # <claude_json> — whitespace-separated user-scope server names, "" if none
  [ -f "$1" ] || return 0
  python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print(" ".join((d.get("mcpServers") or {}).keys()))' "$1"
}

_clean_mcp_purge() {   # <name> <profile_dir> — drop EVERY user-scope server, not just ours
  local name="$1" d="$2" n cb; cb="$(claude_bin)"
  for n in $(_clean_mcp_names "$d/.claude.json"); do
    "$cb" mcp remove --scope user "$n" >/dev/null 2>&1 \
      || warn "clean: could not remove MCP server '$n' (mcp_apply reconciles next)"
  done
  # The legacy ~/.claude.json predates CLAUDE_CONFIG_DIR and still carries mcpServers for the
  # default profile; the CLI may write only to the profile dir, so drop that ONE key by hand and
  # leave oauthAccount / projects / machineID and the file mode untouched.
  if [ "$name" = vanilla ] && [ -f "$HOME/.claude.json" ]; then
    clean_backup_take "$HOME/.claude.json" "$name/legacy-claude.json"
    python3 - "$HOME/.claude.json" <<'PY'
import json, os, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    sys.exit(0)
if d.pop("mcpServers", None) is None:
    sys.exit(0)
tmp = p + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
os.chmod(tmp, os.stat(p).st_mode & 0o777)
os.replace(tmp, p)
PY
  fi
  return 0
}

_clean_backup_skills() {   # <profile_dir> <name> — back up skills/ EXCEPT the gstack clone: 1.5G of
  local d="$1" name="$2" s base   # node_modules that git+bun rebuild, versus KBs of real config.
  for s in "$d"/skills/* "$d"/skills/.[!.]*; do
    [ -e "$s" ] || [ -L "$s" ] || continue
    base="$(basename "$s")"
    [ "$base" = gstack ] && continue
    clean_backup_take "$s" "$name/skills/$base"
  done
  return 0
}

clean_profile() {   # <name> — phase B, inside provision_selected's subshell, before the recipe.
                    # 0 = wiped, 1 = refused or failed (the profile then goes to PROVISION_FAILED:
                    # a half-wiped, half-rebuilt profile is worse than an honest failure).
  local name="$1" d="${CLAUDEFILES_TARGET:-$HOME/.claude}" p f
  if [ "$name" = g ] && ! _clean_have_bun; then
    warn "clean: profile g needs bun to reinstall gstack — refusing to wipe it (sudo pacman -S --needed bun)"
    return 1
  fi
  _clean_mcp_purge "$name" "$d"
  for p in "${_CLEAN_PATHS[@]}"; do
    [ -e "$d/$p" ] || [ -L "$d/$p" ] || continue
    if [ "$p" = skills ]; then _clean_backup_skills "$d" "$name"
    else clean_backup_take "$d/$p" "$name/$p"; fi
    rm -rf "$d/$p" || { warn "clean: cannot remove $d/$p"; return 1; }
  done
  for f in "$d"/settings.json.bak*; do
    [ -e "$f" ] || continue
    clean_backup_take "$f" "$name/$(basename "$f")"
    rm -f "$f" || { warn "clean: cannot remove $f"; return 1; }
  done
  log "clean: $name wiped — the recipe rebuilds it from the repo"
  return 0
}
```

- [ ] **Step 4: Запустить тест, убедиться что проходит**

Run: `bash skills/tools/test-clean.sh`
Expected: `PASS test-clean`

- [ ] **Step 5: Коммит**

```bash
git add lib/clean.sh skills/tools/test-clean.sh
git commit -m "feat(clean): wipe a profile's config surface, keep credentials and history"
```

---

### Task 4: Аудит результата

`clean_verify` делает результат чистой установки проверяемым. Закрывает конкретную дыру: `plugins_apply` глотает ошибки установки и всегда возвращает 0 (`lib/plugins.sh:17-19,36`), а после clean каталог `plugins/` снесён, поэтому провалившаяся установка означала бы молчаливую потерю.

**Files:**
- Modify: `lib/clean.sh`
- Modify: `skills/tools/test-clean.sh`

**Interfaces:**
- Consumes: `profile_dir`, `_mcp_manifest` (`lib/mcp.sh:2`), `config_flag`, `_has_token` (`lib/common.sh:11`), `claude_bin`.
- Produces: `clean_verify <name> <repo_root>` (всегда 0, печатает `warn` на каждое расхождение), `clean_warn_unselected <selected...>` (всегда 0).

- [ ] **Step 1: Написать падающий тест**

Вставить в `skills/tools/test-clean.sh` перед `echo "PASS test-clean"`:

```bash
# --- clean_verify: the audit. Always 0; every finding is a warn on stderr.
vd="$h/.claude"; mkdir -p "$vd/skills/context7-mcp"
python3 -c 'import json,sys;json.dump({"model":"x"},open(sys.argv[1],"w"))' "$vd/settings.json"
python3 -c 'import json,sys;json.dump({"context7":{}},open(sys.argv[1],"w"))' "$CLAUDEFILES_CONFIG_DIR/managed-mcp.vanilla.json"
python3 -c 'import json,sys;json.dump({"mcpServers":{"context7":{}}},open(sys.argv[1],"w"))' "$vd/.claude.json"
printf '{"flags":{"profile_super":true,"dotnet_skills":true,"codex_review":false,"codex_plugin":false}}' > "$CLAUDEFILES_CONFIG_DIR/secrets.json"

# a repo-owned skill is not drift; a stray one is
out="$(clean_verify vanilla "$cf" 2>&1)" || { echo "FAIL verify-nonzero"; exit 1; }
printf '%s' "$out" | grep -qF 'stray skill' && { echo "FAIL false-positive-on-repo-skill"; exit 1; }
mkdir -p "$vd/skills/ges-esp"
out="$(clean_verify vanilla "$cf" 2>&1)"
printf '%s' "$out" | grep -qF "stray skill 'ges-esp'" || { echo "FAIL stray-skill-not-reported"; exit 1; }
rm -rf "$vd/skills/ges-esp"

# a dir the repo never creates coming back
mkdir -p "$vd/rules"
out="$(clean_verify vanilla "$cf" 2>&1)"
printf '%s' "$out" | grep -qF "'rules/' is back" || { echo "FAIL rules-not-reported"; exit 1; }
rm -rf "$vd/rules"

# live MCP set drifting from the manifest
python3 -c 'import json,sys;json.dump({"mcpServers":{"context7":{},"extra":{}}},open(sys.argv[1],"w"))' "$vd/.claude.json"
out="$(clean_verify vanilla "$cf" 2>&1)"
printf '%s' "$out" | grep -qF 'MCP servers differ' || { echo "FAIL mcp-drift-not-reported"; exit 1; }
python3 -c 'import json,sys;json.dump({"mcpServers":{"context7":{}}},open(sys.argv[1],"w"))' "$vd/.claude.json"

# a key the template does not own surviving in settings.json
python3 -c 'import json,sys;json.dump({"model":"x","junk":1},open(sys.argv[1],"w"))' "$vd/settings.json"
out="$(clean_verify vanilla "$cf" 2>&1)"
printf '%s' "$out" | grep -qF 'settings.json keys' || { echo "FAIL settings-drift-not-reported"; exit 1; }

# plugins: coverage of what the flags demand. plugins_apply swallows install errors, and after a
# clean the plugins/ dir is gone, so a silent loss must be visible here.
sd="$h/.claude-super"; mkdir -p "$sd/skills"
: > "$CLAUDE_FAKE_STATE/plugins"
out="$(clean_verify super "$cf" 2>&1)"
printf '%s' "$out" | grep -qF "plugin 'superpowers@claude-plugins-official' is NOT installed" \
  || { echo "FAIL missing-plugin-not-reported"; exit 1; }
printf 'superpowers@claude-plugins-official\ndotnet@dotnet-agent-skills\n' > "$CLAUDE_FAKE_STATE/plugins"
out="$(clean_verify super "$cf" 2>&1)"
printf '%s' "$out" | grep -qF 'is NOT installed' && { echo "FAIL false-positive-on-installed-plugins"; exit 1; }

# --- clean_warn_unselected: a profile left out of this run keeps its transcripts, so it is never
# deleted — but staying dirty silently would be a lie about what "clean install" just did.
mkdir -p "$h/.claude-g"
out="$(clean_warn_unselected vanilla super 2>&1)" || { echo "FAIL warn-unselected-nonzero"; exit 1; }
printf '%s' "$out" | grep -qF "$h/.claude-g" || { echo "FAIL unselected-profile-not-reported"; exit 1; }
printf '%s' "$out" | grep -qF "$h/.claude-super" && { echo "FAIL selected-profile-reported"; exit 1; }
[ -d "$h/.claude-g" ] || { echo "FAIL unselected-profile-deleted"; exit 1; }
```

- [ ] **Step 2: Запустить тест, убедиться что падает**

Run: `bash skills/tools/test-clean.sh`
Expected: FAIL, `clean_verify: command not found`.

- [ ] **Step 3: Дописать `lib/clean.sh`**

Добавить в конец файла:

```bash
clean_verify() {   # <name> <repo_root> — audit a cleaned profile. Always 0: Claude Code re-adds the
                   # official marketplace on its own at next start, so this reports, never gates.
  local name="$1" root="$2" d issues=0 s base p w listing cb
  d="$(profile_dir "$name")"; cb="$(claude_bin)"
  # 1. strays in skills/. Derived from the repo tree (and, for g, from what the clone published),
  #    NOT from a hardcoded list: that knowledge belongs to skills.sh, not to the eraser.
  for s in "$d"/skills/*/; do
    [ -d "$s" ] || continue
    base="$(basename "$s")"
    [ "$base" = gstack ] && continue
    [ -d "$root/claude/skills/$base" ] && continue
    [ -f "$d/skills/gstack/$base/SKILL.md" ] && continue
    warn "clean-verify $name: stray skill '$base'"; issues=$((issues + 1))
  done
  # 2. directories the repo never creates
  for p in rules agents commands output-styles; do
    if [ -e "$d/$p" ]; then warn "clean-verify $name: '$p/' is back"; issues=$((issues + 1)); fi
  done
  # 3. live user-scope MCP set vs the manifest we just wrote
  local manifest; manifest="$(_mcp_manifest "$name")"
  if [ -f "$manifest" ] && [ -f "$d/.claude.json" ]; then
    python3 -c 'import json,sys
want=sorted(json.load(open(sys.argv[1])).keys())
try: live=sorted((json.load(open(sys.argv[2])).get("mcpServers") or {}).keys())
except Exception: live=[]
sys.exit(0 if want==live else 1)' "$manifest" "$d/.claude.json" \
      || { warn "clean-verify $name: user-scope MCP servers differ from $manifest"; issues=$((issues + 1)); }
  fi
  # 4. top-level keys of settings.json vs the profile's template. After a clean the file is written
  #    from scratch, so anything extra means something re-added a key mid-run.
  local tmpl="$root/claude/settings/settings.$name.template.json"
  if [ -f "$tmpl" ] && [ -f "$d/settings.json" ]; then
    python3 -c 'import json,sys
t=set(json.load(open(sys.argv[1])));o=set(json.load(open(sys.argv[2])))
sys.exit(0 if t==o else 1)' "$tmpl" "$d/settings.json" \
      || { warn "clean-verify $name: settings.json keys differ from $(basename "$tmpl")"; issues=$((issues + 1)); }
  fi
  # 5. plugin COVERAGE (expected ⊆ installed), not equality: Claude Code auto-installs the official
  #    marketplace by itself, and reporting that as drift would train the user to ignore the report.
  local want_plugins=()
  if [ "$name" = super ]; then
    want_plugins+=("superpowers@claude-plugins-official")
    [ "$(config_flag dotnet_skills)" = true ] && want_plugins+=("dotnet@dotnet-agent-skills")
    [ "$(config_flag codex_review)" = true ] && [ "$(config_flag codex_plugin)" = true ] \
      && want_plugins+=("codex@openai-codex")
  fi
  if [ "${#want_plugins[@]}" -gt 0 ]; then
    listing="$(env CLAUDE_CONFIG_DIR="$d" "$cb" plugin list 2>/dev/null || true)"
    for w in "${want_plugins[@]}"; do
      _has_token "$w" <<<"$listing" \
        || { warn "clean-verify $name: plugin '$w' is NOT installed after clean"; issues=$((issues + 1)); }
    done
  fi
  if [ "$issues" -eq 0 ]; then
    log "clean-verify $name: OK"
  else
    warn "clean-verify $name: $issues issue(s) — backup: ${CLAUDEFILES_CLEAN_BACKUP:-n/a}"
  fi
  return 0
}

clean_warn_unselected() {   # <selected...> — clean touches ONLY the profiles being installed. A
                            # leftover dir keeps its transcripts, so deleting it is not our call;
                            # saying nothing about it would misrepresent what the run just did.
  local p d
  for p in vanilla super g; do
    case " $* " in *" $p "*) continue ;; esac
    d="$(profile_dir "$p")"
    [ -d "$d" ] && warn "clean: $d was not selected — left untouched (still dirty)"
  done
  return 0
}
```

- [ ] **Step 4: Запустить тест, убедиться что проходит**

Run: `bash skills/tools/test-clean.sh`
Expected: `PASS test-clean`

- [ ] **Step 5: Коммит**

```bash
git add lib/clean.sh skills/tools/test-clean.sh
git commit -m "feat(clean): audit the end state, catch silently lost plugins"
```

---

### Task 5: Подключение к setup.sh и сквозной тест

Две фазы встают на свои места в порядке прогона. Только здесь режим становится доступен пользователю.

**Files:**
- Modify: `setup.sh:5`, `setup.sh:10-11`, `setup.sh:68-85`
- Modify: `lib/profiles.sh:82-96`
- Modify: `skills/tools/test-setup-idempotent.sh`

**Interfaces:**
- Consumes: `clean_wanted`, `clean_preflight`, `clean_backup_open`, `clean_global`, `clean_profile`, `clean_verify`.
- Produces: `CLAUDEFILES_CLEAN_ACTIVE` (`true`/`false`, читается `provision_selected`).

- [ ] **Step 1: Написать падающий тест**

Дописать в конец `skills/tools/test-setup-idempotent.sh`, перед строкой `echo "PASS test-setup-idempotent"`:

```bash
# --- clean install, end to end through the real setup.sh.
# Plant exactly the junk a clean install exists to remove, then answer every question the way the
# seeded secrets.json was configured: same answers -> byte-identical result, which is what makes
# the diffs below meaningful.
mkdir -p "$h/.claude/skills/ges-esp" "$h/.claude/rules"
printf 'STRAY' > "$h/.claude/skills/ges-esp/SKILL.md"
printf 'RULE'  > "$h/.claude/rules/context7.md"
printf 'BAK'   > "$h/.claude/settings.json.bak.20260101-000000"
python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d["junkKey"]=1;json.dump(d,open(p,"w"))' "$h/.claude/settings.json"
printf '\nhand-written line\n' >> "$h/.claude/CLAUDE.md"
printf 'CREDS' > "$h/.claude/.credentials.json"; printf 'HIST' > "$h/.claude/history.jsonl"
mkdir -p "$h/.claude/projects/keepme"
: > "$CLAUDE_FAKE_LOG"; : > "$PACLOG"
# answers: confirm word, super y, dotnet y, codex_review y, codex_plugin n, playwright y,
# azure n, ado n, gstack y, context7 y, context7 key (empty). Trailing blanks absorb any
# dep prompt that a non-provisioned box might raise AFTER the config phase.
printf 'clean\ny\ny\ny\nn\ny\nn\nn\ny\ny\n\n\n\n\n' | \
  CLAUDEFILES_ASSUME_TTY=1 CLAUDEFILES_CLEAN=1 CLAUDEFILES_CLEAN_SKIP_NET=1 bash "$cf/setup.sh"

[ -e "$h/.claude/skills/ges-esp" ] && { echo "FAIL clean kept a stray skill"; exit 1; }
[ -e "$h/.claude/rules" ] && { echo "FAIL clean kept rules/"; exit 1; }
[ -e "$h/.claude/settings.json.bak.20260101-000000" ] && { echo "FAIL clean kept a settings backup"; exit 1; }
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert "junkKey" not in d,d' "$h/.claude/settings.json" \
  || { echo "FAIL clean kept an unknown settings key"; exit 1; }
grep -q 'hand-written line' "$h/.claude/CLAUDE.md" && { echo "FAIL clean kept hand-written CLAUDE.md text"; exit 1; }
[ "$(cat "$h/.claude/.credentials.json")" = CREDS ] || { echo "FAIL clean touched credentials"; exit 1; }
[ "$(cat "$h/.claude/history.jsonl")" = HIST ] || { echo "FAIL clean touched history"; exit 1; }
[ -d "$h/.claude/projects/keepme" ] || { echo "FAIL clean touched projects/"; exit 1; }
[ -s "$PACLOG" ] && { echo "FAIL clean run invoked pacman/sudo"; cat "$PACLOG"; exit 1; }
# the backup is the whole safety net: the stray must be recoverable from it
bdir="$(ls -d "$h/.config/claudefiles/clean-backups"/*/ | head -1)"
[ -f "$bdir/vanilla/skills/ges-esp/SKILL.md" ] || { echo "FAIL stray not in the clean backup"; exit 1; }
[ -f "$bdir/global/secrets.json" ] || { echo "FAIL answers not in the clean backup"; exit 1; }
# same answers as the seeded run -> the rebuilt config is byte-identical to the pre-clean one
diff "$h/first.json" "$h/.claude/settings.json" || { echo "FAIL clean rebuild differs from a normal run"; exit 1; }
diff "$h/first-claudemd.md" "$h/.claude/CLAUDE.md" || { echo "FAIL clean CLAUDE.md differs"; exit 1; }
# ...and a normal run right after a clean one is still a no-op
cp "$h/.claude/settings.json" "$h/post-clean.json"
CLAUDEFILES_ASSUME_TTY=0 bash "$cf/setup.sh" --non-interactive
diff "$h/post-clean.json" "$h/.claude/settings.json" || { echo "FAIL not idempotent after clean"; exit 1; }
```

- [ ] **Step 2: Запустить тест, убедиться что падает**

Run: `bash skills/tools/test-setup-idempotent.sh`
Expected: FAIL, чистая установка не запускается (`clean` уходит в первый вопрос конфига), остаётся `ges-esp`.

- [ ] **Step 3: Подключить модуль в `setup.sh`**

Строка 5, добавить `clean` последним (модуль зовёт `profile_dir` и `_mcp_manifest` в рантайме):

```bash
for m in common config deps settings skills plugins mcp claudemd gstack profiles clean; do source "$ROOT/lib/$m.sh"; done
```

Заменить строки 10-11 на:

```bash
log "config"
[ "${1:-}" = "--non-interactive" ] && export CLAUDEFILES_ASSUME_TTY=0
# Phase A: asked BEFORE config_ensure_all, because clean wipes the stored answers — asking after
# would erase what the user has just typed. Never persisted: a per-run choice, not a flag.
CLEAN=false
if clean_wanted; then
  CLEAN=true
  clean_preflight
  clean_backup_open
  clean_global
fi
```

- [ ] **Step 4: Прокинуть флаг в провижн и предупредить о невыбранных профилях**

В `setup.sh`, между `selected=(...)` (строки 68-70) и `provision_selected` (строка 72), вставить:

```bash
if [ "$CLEAN" = true ]; then clean_warn_unselected "${selected[@]}"; fi
export CLAUDEFILES_CLEAN_ACTIVE="$CLEAN"
```

- [ ] **Step 5: Вызвать `clean_profile` перед рецептом**

В `lib/profiles.sh`, `provision_selected` (строки 82-96). После `PROVISION_FAILED=()` добавить:

```bash
  if [ "${CLAUDEFILES_CLEAN_ACTIVE:-false}" = true ]; then
    log "clean install: wiping $*"     # phase B: the profile list is finally resolved here
  fi
```

и заменить строку запуска рецепта на:

```bash
    if ( export CLAUDEFILES_TARGET="$dir"; export CLAUDE_CONFIG_DIR="$dir"
         if [ "${CLAUDEFILES_CLEAN_ACTIVE:-false}" = true ]; then clean_profile "$p" || exit 1; fi
         "recipe_$p" "$root" ); then
```

- [ ] **Step 6: Добавить аудит и печать бэкапа в `verify`**

В `setup.sh`, в цикле `verify` (строки 76-80), после проверки `json.tool` добавить:

```bash
  if [ "$CLEAN" = true ]; then clean_verify "$p" "$ROOT"; fi
```

и перед финальным `log "Done. ..."` (строка 85):

```bash
if [ "$CLEAN" = true ]; then log "clean: backup kept at $CLAUDEFILES_CLEAN_BACKUP"; fi
```

- [ ] **Step 7: Запустить тест, убедиться что проходит**

Run: `bash skills/tools/test-setup-idempotent.sh`
Expected: `PASS test-setup-idempotent`

- [ ] **Step 8: Прогнать всю сьюту**

Run: `bash skills/tools/run-all-tests.sh`
Expected: `ALL TESTS PASSED`

- [ ] **Step 9: Коммит**

```bash
git add setup.sh lib/profiles.sh skills/tools/test-setup-idempotent.sh
git commit -m "feat(clean): wire the clean install into setup.sh in two phases"
```

---

### Task 6: Документация

Диаграммы и инварианты правятся в том же PR, что и код (`docs/architecture.md:3`).

**Files:**
- Modify: `docs/invariants.md`, `docs/user-flow.md`, `docs/architecture.md`, `README.md`

- [ ] **Step 1: Инварианты**

Добавить в конец списка `docs/invariants.md`:

```markdown
- **Чистая установка стирает только конфиг-поверхность.** Снос идёт по фиксированному denylist (`settings*`, `CLAUDE.md`, `skills/`, `plugins/`, `rules/`, `agents/`, `commands/`, `output-styles/`, маркер gstack, user-scope MCP); `.credentials.json`, `.claude.json` кроме `mcpServers`, `projects/`, `history.jsonl`, `sessions/` и кеши переживают режим. Тесты: `test-clean.sh`, `test-setup-idempotent.sh`.
- **Clean fail-closed.** Провал clean-preflight (нет `claude`, недостижим github) или провал бэкапа означает ноль удалений. Тест: `test-clean.sh`.
- **Clean не сносит то, что не сможет восстановить.** Профиль `g` без `bun` не чистится вообще: клон и маркер остаются, профиль уходит в `PROVISION_FAILED`. Тест: `test-clean.sh`.
- **Clean недоступен без TTY.** Вопрос не задаётся, а `CLAUDEFILES_CLEAN=1` без TTY это `die` до первого удаления: ответы сносятся, а ввести их заново без TTY нельзя. Тест: `test-clean.sh`.
- **После clean прогон снова идемпотентен.** Обычный прогон сразу после чистой установки не даёт diff. Тест: `test-setup-idempotent.sh`.
```

- [ ] **Step 2: User-flow**

В `docs/user-flow.md` вставить развилку между `run` и опросом конфига, заменив ребро `run --> q`:

```
  run --> clean{"чистая установка? (y/N + слово clean)"}
  clean -->|да| wipe["clean-preflight, бэкап, снос secrets.json и манифестов"]
  clean -->|нет| q
  wipe --> q
```

и добавить ребро от провижна к сносу профиля:

```
  provision --> cp["перед рецептом: clean_profile (только выбранные профили)"]
```

- [ ] **Step 3: Архитектура**

В `docs/architecture.md`, в блок `subgraph orch` добавить узел и рёбра:

```
    cleanm["clean.sh (ластик чистой установки)"]
```
```
  setup --> cleanm
  prof --> cleanm
```

В sequence-диаграмме прогона добавить шаг перед `config_ensure_all`:

```
  Note over U: clean (опционально): подтверждение, preflight, бэкап, снос ответов и манифестов
```

и внутрь цикла по профилям, перед `P->>R`:

```
  opt чистая установка
    P->>P: clean_profile (снос конфиг-поверхности; g без bun = отказ)
  end
```

- [ ] **Step 4: README**

Добавить раздел после `## Установка` (README.md:48-65):

```markdown
## Чистая установка

Обычный прогон аддитивен: он владеет только своими ключами и своими артефактами, всё остальное
переживает установку. Чистая установка снимает и это: сторонние скиллы, `rules/`, MCP-серверы,
добавленные руками, чужие ключи в `settings.json`, ручные правки `CLAUDE.md`, установленные
плагины.

```bash
./setup.sh
# Clean install? Wipes the selected profiles' config and every stored answer. (y/N) y
# Type 'clean' to confirm: clean
```

Вопрос задаётся в каждом прогоне, по умолчанию нет. Подтверждение словом обязательно: случайный
`y` не должен стоить вам ADO PAT-ов.

Что сносится: `settings.json` (переписывается ровно из шаблона), `settings.local.json`,
`settings.json.bak*`, `CLAUDE.md`, `skills/`, `plugins/`, `rules/`, `agents/`, `commands/`,
`output-styles/`, маркер gstack, все user-scope MCP-серверы, `secrets.json` и MCP-манифесты.

Что сохраняется: `.credentials.json` (вы не разлогинитесь), `projects/` с транскриптами,
`history.jsonl`, `sessions/`, кеши, `.claude.json` кроме ключа `mcpServers`.

Чистятся только те профили, что выбраны в этом прогоне. Оставшийся на диске каталог невыбранного
профиля не трогается, о нём печатается предупреждение.

Перед первым удалением всё удаляемое копируется в `~/.config/claudefiles/clean-backups/<время>/`
(права 700), кроме клона gstack на 1.5G. Любая ошибка бэкапа отменяет прогон до удаления.

Требования: TTY (ответы сносятся, вводить их заново придётся руками), `claude` на PATH и
доступный github. Профиль `g` дополнительно требует `bun`, иначе он не чистится вовсе.
Чистая установка профиля `g` заново клонирует gstack и прогоняет его инсталлятор: это долго.
```

- [ ] **Step 5: Проверить рендер mermaid**

Run: `python3 -c "import re,sys;[print(f) for f in ['docs/user-flow.md','docs/architecture.md'] if open(f).read().count('\`\`\`mermaid') != open(f).read().count('\`\`\`')//2]"`
Expected: пустой вывод (число открытых блоков mermaid совпадает с числом пар ограждений).

- [ ] **Step 6: Коммит**

```bash
git add docs/invariants.md docs/user-flow.md docs/architecture.md README.md
git commit -m "docs: document the clean install mode"
```

---

## Проверка перед сдачей

- [ ] `bash skills/tools/run-all-tests.sh` → `ALL TESTS PASSED`
- [ ] `bash -n setup.sh lib/clean.sh lib/profiles.sh` → без вывода
- [ ] Обычный прогон без clean не изменился: `CLAUDEFILES_ASSUME_TTY=0 bash setup.sh --non-interactive` на фикстуре не задаёт новых вопросов и не создаёт `clean-backups/`
