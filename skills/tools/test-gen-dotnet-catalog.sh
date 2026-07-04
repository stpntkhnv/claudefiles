#!/usr/bin/env bash
# Tests for gen-dotnet-catalog.sh — runs against the real dotnet-skills checkout.
set -euo pipefail

GEN="/home/stsiapan/devTools/skills/tools/gen-dotnet-catalog.sh"
REPO="/home/stsiapan/devTools/skills/dotnet-skills"
OUTDIR="$(mktemp -d)"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -x "$GEN" ] || fail "generator missing or not executable"
"$GEN" "$REPO" "$OUTDIR" || fail "generator exited non-zero"
[ -f "$OUTDIR/INDEX.md" ] || fail "no INDEX.md written"

# 1. Entry count across domain files matches SKILL.md count in the repo
expected=$(find "$REPO/plugins" -name SKILL.md | wc -l)
actual=$(cat "$OUTDIR"/CATALOG-*.md | grep -c '^- \*\*')
[ "$actual" -eq "$expected" ] || fail "entries: $actual != $expected"

# 2. Long descriptions survive verbatim, incl. negative triggers
grep -q '\*\*assertion-quality\*\*' "$OUTDIR/CATALOG-dotnet-test.md" || fail "assertion-quality entry missing"
grep 'DO NOT USE FOR' "$OUTDIR/CATALOG-dotnet-test.md" | grep -q 'test-gap-analysis' \
  || fail "DO NOT USE FOR disambiguation lost — descriptions were truncated"

# 3. Every listed path exists and is absolute
while IFS= read -r p; do
  case "$p" in /*) ;; *) fail "non-absolute path: $p" ;; esac
  [ -f "$p" ] || fail "listed path missing: $p"
done < <(cat "$OUTDIR"/CATALOG-*.md | grep -o '`/[^`]*SKILL\.md`' | tr -d '\`')

# 4. Size caps: INDEX ≤8000 chars, each domain file ≤40000 chars
ichars=$(wc -c < "$OUTDIR/INDEX.md")
[ "$ichars" -le 8000 ] || fail "INDEX too big: $ichars chars"
for f in "$OUTDIR"/CATALOG-*.md; do
  c=$(wc -c < "$f")
  [ "$c" -le 40000 ] || fail "$(basename "$f") too big: $c chars"
done

# 5. Stage map present in INDEX
grep -q '^## Stage map' "$OUTDIR/INDEX.md" || fail "stage map missing"

# 5b. INDEX completeness: every domain file pointed to, every skill name listed
for f in "$OUTDIR"/CATALOG-*.md; do
  grep -qF -- "$(basename "$f")" "$OUTDIR/INDEX.md" || fail "INDEX misses pointer to $(basename "$f")"
done
while IFS= read -r name; do
  grep -qF -- "$name" "$OUTDIR/INDEX.md" || fail "INDEX misses skill name: $name"
done < <(cat "$OUTDIR"/CATALOG-*.md | sed -n 's/^- \*\*\([^*]*\)\*\*.*/\1/p')

# 5c. Name-list lines are strictly ", "-separated (regression guard: paste
# delimiter-list cycling once produced mixed "a,b c" separators)
while IFS= read -r line; do
  echo "$line" | grep -Eq '^[a-z0-9-]+(, [a-z0-9-]+)*$' \
    || fail "malformed name-list line in INDEX: $line"
done < <(awk '/^### /{getline; print}' "$OUTDIR/INDEX.md")

# 6. No duplicate skill names — name→path cross-referencing needs uniqueness
dups="$(cat "$OUTDIR"/CATALOG-*.md | grep -o '^- \*\*[^*]*\*\*' | sort | uniq -d)"
[ -z "$dups" ] || fail "duplicate skill names: $dups"

# 7. Verbatim property: for EVERY skill the catalog description equals the
# frontmatter description modulo whitespace/quoting. Reference extraction is
# independent (python3 stdlib, line-based) — not the generator's awk.
python3 - "$OUTDIR" "$REPO" <<'PY' || fail "verbatim property violated (see stderr)"
import re, sys, pathlib

outdir, repo = sys.argv[1], sys.argv[2]

def norm(s):
    return re.sub(r'[\s"\'\\]', '', s)

def ref_desc(text):
    fm = text.split('---', 2)[1]
    desc, on = [], False
    for ln in fm.splitlines():
        if on:
            if re.match(r'^[A-Za-z_-]+:', ln):
                break
            if ln.strip():
                desc.append(ln.strip())
        elif ln.startswith('description:'):
            on = True
            first = ln[len('description:'):].strip()
            if first and not re.fullmatch(r'[>|][+-]?', first):
                desc.append(first)
    return ' '.join(desc)

catalog = {}
for cf in pathlib.Path(outdir).glob('CATALOG-*.md'):
    lines = cf.read_text(encoding='utf-8').splitlines()
    for i, ln in enumerate(lines):
        m = re.match(r'^- \*\*(.+?)\*\* — (.*)$', ln)
        if m:
            pm = re.match(r'^  `(/.+/SKILL\.md)`$', lines[i + 1])
            if not pm:
                print(f"no path line after entry: {m.group(1)} in {cf.name}", file=sys.stderr)
                sys.exit(1)
            catalog[pm.group(1)] = m.group(2)

bad = []
for sk in pathlib.Path(repo, 'plugins').rglob('SKILL.md'):
    text = sk.read_text(encoding='utf-8')
    sk = str(sk)
    if sk not in catalog:
        bad.append(f"missing from catalog: {sk}")
    elif norm(ref_desc(text)) != norm(catalog[sk]):
        bad.append(f"description differs from frontmatter: {sk}")

if bad:
    print('\n'.join(bad), file=sys.stderr)
    sys.exit(1)
PY

echo "PASS: all catalog tests"
