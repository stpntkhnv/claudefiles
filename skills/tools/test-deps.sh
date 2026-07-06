#!/usr/bin/env bash
# test-deps.sh — unit tests for lib/deps.sh (+ _has_token) on an ISOLATED PATH.
# node/npx/dotnet/chromium/sudo/pacman all exist in /usr/bin on the dev box, so the
# "absent" cases only hold if PATH contains just our fakes + the handful of coreutils
# the code and harness need. We symlink those into a fresh sandbox per case.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"

# resolve the real coreutils ONCE, while the real PATH is still active
declare -A REAL
for c in bash env python3 id mktemp mkdir grep chmod cat rm ln dirname sort timeout head; do REAL[$c]="$(command -v "$c")"; done

fails=0
chk() { local d="$1"; shift; if "$@"; then printf 'ok   %s\n' "$d"; else printf 'FAIL %s\n' "$d"; fails=1; fi; }
isempty()  { [ ! -s "$1" ]; }
haspac()   { grep -qF -- "$1" "$2"; }
nogrep_i() { ! grep -qiF -- "$1" "$2"; }
not_token(){ ! _has_token "$1"; }

SANDBOXES=()
trap 'rm -rf "${SANDBOXES[@]}"' EXIT

mk_sandbox() {   # sets SB, HOME, isolated PATH, PACLOG; wipes any leaked config-dir override
  SB="$(mktemp -d)"
  SANDBOXES+=("$SB")
  export HOME="$SB/home"; mkdir -p "$HOME/.config/claudefiles"
  BIN="$SB/bin"; mkdir -p "$BIN"
  local c; for c in "${!REAL[@]}"; do ln -s "${REAL[$c]}" "$BIN/$c"; done
  export PATH="$BIN"
  export PACLOG="$SB/pac.log"; : > "$PACLOG"
  unset CLAUDEFILES_ASSUME_TTY CLAUDEFILES_CONFIG_DIR   # config.sh recomputes CONFIG_DIR from HOME
}
present()    { printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$1"; chmod +x "$BIN/$1"; }
fake_pacman(){ cat > "$BIN/pacman" <<'EOF'
#!/usr/bin/env bash
printf 'pacman %s\n' "$*" >> "$PACLOG"
exit 0
EOF
chmod +x "$BIN/pacman"; }
fake_sudo()  { cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$PACLOG"
exec "$@"
EOF
chmod +x "$BIN/sudo"; }
fake_claude(){   # $1 = exact text `claude plugin list` must print; other subcommands exit 0
cat > "$BIN/claude" <<SCRIPT
#!/usr/bin/env bash
case "\$1 \$2" in
  "plugin list") printf '%s\n' "$1" ;;
  *) exit 0 ;;
esac
SCRIPT
chmod +x "$BIN/claude"; }
fake_codex(){   # $1 = version (e.g. 0.142.5); $2 = auth: ok|fail
cat > "$BIN/codex" <<SCRIPT
#!/usr/bin/env bash
case "\$1" in
  --version) echo "codex-cli $1" ;;
  login)     [ "\$2" = status ] && { [ "$2" = ok ] && exit 0 || { echo "Not logged in"; exit 1; }; } ;;
  *)         exit 0 ;;
esac
SCRIPT
chmod +x "$BIN/codex"; }
load() { source "$cf/lib/common.sh"; source "$cf/lib/config.sh"; source "$cf/lib/deps.sh"; }

# _has_token: whole-token fixed match (collision-safe, no regex) — used by plugins + readiness
mk_sandbox; load
chk "_has_token: whole token matches"       _has_token "b"  <<< "a b c"
chk "_has_token: substring does NOT match"  not_token   "b"  <<< "abx bxc"
chk "_has_token: empty stdin -> no match"   not_token   "b"  <<< ""

# readiness_report: non-fatal contract (finding 1: missing `return 0`) + whole-token plugin detection
mk_sandbox; fake_claude "superpowers@claude-plugins-official"
load
( set -e; readiness_report false false false false false ); rc=$?
chk "readiness_report returns 0 under set -e" [ "$rc" -eq 0 ]

out="$SB/readiness-ok.out"
readiness_report false false false false false >"$out" 2>&1
chk "whole-token listing -> superpowers plugin OK" grep -q "ready: superpowers plugin OK" "$out"

mk_sandbox; fake_claude "superpowers@claude-plugins-official-x"   # substring only, not a whole-token match
load
out="$SB/readiness-missing.out"
readiness_report false false false false false >"$out" 2>&1
chk "substring-only listing -> superpowers plugin MISSING" grep -q "ready: superpowers plugin MISSING" "$out"
chk "substring-only listing -> does NOT report OK"          nogrep_i "superpowers plugin OK" "$out"

# A: everything present -> pacman never called
mk_sandbox; fake_pacman; fake_sudo; present node; present npx; present chromium; present dotnet
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply true true true true true <<< ""
chk "all deps present -> pacman not called" isempty "$PACLOG"

# B: all flags false -> deps_apply returns 0 under set -e, no pacman (finding 1)
mk_sandbox; fake_pacman; fake_sudo
load; export CLAUDEFILES_ASSUME_TTY=0
( set -e; deps_apply false false false false false ); rc=$?
chk "all-flags-false returns 0 under set -e" [ "$rc" -eq 0 ]
chk "all-flags-false -> no pacman"           isempty "$PACLOG"

# C: node/npx missing + TTY + piped y -> pacman installs BOTH packages (findings 3, 6)
mk_sandbox; fake_pacman; fake_sudo
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply true false false false false <<< "y"
chk "missing node/npx -> pacman installs nodejs npm" haspac "pacman -S --needed --noconfirm nodejs npm" "$PACLOG"

# D: missing + no TTY -> sudo/pacman NOT called, manual only
mk_sandbox; fake_pacman; fake_sudo
load; export CLAUDEFILES_ASSUME_TTY=0
deps_apply true false false false false <<< "y"
chk "no TTY -> pacman not called" isempty "$PACLOG"

# E: sudo absent (finding 2). Non-root -> manual only; root -> pacman runs directly (branch flips).
mk_sandbox; fake_pacman           # NO fake_sudo; real sudo not on the isolated PATH
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply true false false false false <<< "y"
if [ "$(id -u)" -eq 0 ]; then
  chk "root + no sudo -> pacman called directly"     haspac "pacman -S --needed --noconfirm nodejs npm" "$PACLOG"
else
  chk "non-root + no sudo -> pacman not run (manual)" isempty "$PACLOG"
fi

# F: node present but npx absent -> still treated as missing (finding 4)
mk_sandbox; fake_pacman; fake_sudo; present node   # npx absent
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply true false false false false <<< "y"
chk "node present, npx absent -> still offers install" haspac "pacman -S --needed --noconfirm nodejs npm" "$PACLOG"

# G: playwright off -> chromium not required even when absent
mk_sandbox; fake_pacman; fake_sudo; present node; present npx   # chromium absent, playwright off
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply true false false false false <<< "y"
chk "playwright off -> chromium not offered" nogrep_i "chromium" "$PACLOG"

# H: playwright on + chromium_path override -> chromium NOT offered (finding 11)
mk_sandbox; fake_pacman; fake_sudo; present node; present npx
mkdir -p "$SB/opt"; dummy="$SB/opt/mychrome"; printf '#!/usr/bin/env bash\nexit 0\n' > "$dummy"; chmod +x "$dummy"
python3 "$cf/lib/py/config_io.py" set "$HOME/.config/claudefiles/secrets.json" playwright.chromium_path "$dummy"
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply true true false false false <<< "y"
chk "chromium_path override honored -> chromium not offered" nogrep_i "chromium" "$PACLOG"

# I: dotnet flag + dotnet absent -> installs dotnet-sdk (single-package array)
mk_sandbox; fake_pacman; fake_sudo; present node; present npx   # dotnet absent
load; export CLAUDEFILES_ASSUME_TTY=1
deps_apply false false false false true <<< "y"
chk "dotnet flag + dotnet absent -> installs dotnet-sdk" haspac "pacman -S --needed --noconfirm dotnet-sdk" "$PACLOG"

# J: codex flag + codex absent -> readiness reports MISSING (non-fatal)
mk_sandbox; fake_claude "superpowers@claude-plugins-official"
load
out="$SB/codex-missing.out"
readiness_report false false false false false true >"$out" 2>&1
chk "codex absent -> readiness MISSING" grep -q "ready: codex CLI .* MISSING" "$out"

# K: codex present + new enough + logged in -> both readiness lines OK
mk_sandbox; fake_claude "superpowers@claude-plugins-official"; fake_codex "0.142.5" "ok"
load
out="$SB/codex-ok.out"
readiness_report false false false false false true >"$out" 2>&1
chk "codex runnable+new -> CLI OK" grep -q "ready: codex CLI .* OK" "$out"
chk "codex logged in -> auth OK"   grep -q "ready: codex auth OK" "$out"

# K2: codex present but NOT logged in -> auth MISSING (login status exits 1)
mk_sandbox; fake_claude "superpowers@claude-plugins-official"; fake_codex "0.142.5" "fail"
load
out="$SB/codex-noauth.out"
readiness_report false false false false false true >"$out" 2>&1
chk "codex not logged in -> auth MISSING" grep -q "ready: codex auth MISSING" "$out"

# L: codex too old -> CLI MISSING (version floor enforced)
mk_sandbox; fake_claude "superpowers@claude-plugins-official"; fake_codex "0.100.0" "ok"
load
out="$SB/codex-old.out"
readiness_report false false false false false true >"$out" 2>&1
chk "codex < floor -> CLI MISSING" grep -q "ready: codex CLI .* MISSING" "$out"

# M: codex flag off -> no codex readiness lines
mk_sandbox; fake_claude "superpowers@claude-plugins-official"
load
out="$SB/codex-off.out"
readiness_report false false false false false false >"$out" 2>&1
chk "codex flag off -> no codex line" bash -c '! grep -q "codex" "'"$out"'"'

[ "$fails" -eq 0 ] && echo "PASS test-deps" || { echo "SOME test-deps CASES FAILED"; exit 1; }
