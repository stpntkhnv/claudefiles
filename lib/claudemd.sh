# claudemd.sh — own marker-delimited blocks in a profile's CLAUDE.md, preserve the rest.
# Deterministic: strip our block + trailing blank lines, then re-append if enabled.
# Re-running with the same arguments yields a byte-identical file. Source, don't execute.

_claudemd_file() { echo "${CLAUDEFILES_CLAUDE_MD:-${CLAUDEFILES_TARGET:-$HOME/.claude}/CLAUDE.md}"; }

_claudemd_block_apply() { # <begin> <end> <rule> <enabled:true|false>
  local begin="$1" end="$2" rule="$3" enabled="${4:-false}"
  local f; f="$(_claudemd_file)"
  # disable + no file -> nothing to do (don't create a spurious file)
  [ "$enabled" != true ] && [ ! -f "$f" ] && return 0
  mkdir -p "$(dirname "$f")"
  # base = existing content minus our block (and the blank separator line our own insert put
  # immediately before it), with any remaining leading/trailing blank lines trimmed.
  # A BEGIN with no END is not a block: everything after it is buffered and given back at END,
  # so a hand-written marker example (or a file left half-written by an older claudefiles) costs
  # the user nothing.
  local base=""
  [ -f "$f" ] && base="$(awk -v b="$begin" -v e="$end" '
      $0==b && !skip{if(n>0 && a[n]=="")n--; skip=1; m=0; next}
      $0==e && skip{skip=0; m=0; next}
      skip{s[++m]=$0; next}
      {a[++n]=$0}
      END{if(skip)for(i=1;i<=m;i++)a[++n]=s[i]
          while(n>0 && a[n]=="")n--
          f=1; while(f<=n && a[f]=="")f++
          for(i=f;i<=n;i++)print a[i]}' "$f")"
  # Write via a temp file and rename: an interrupted run must not leave a truncated CLAUDE.md
  # (that is how an unterminated BEGIN gets created in the first place).
  local tmp="$f.tmp"
  # `elif` rather than a trailing `[ -n "$base" ] && printf`: with the block disabled and nothing
  # left to keep, that test is the group's last command and its exit 1 would be read as a write
  # failure — leaving the block in place on exactly the super->vanilla migration path.
  {
    if [ "$enabled" = true ]; then
      [ -n "$base" ] && printf '%s\n\n' "$base"
      printf '%s\n%s\n%s\n' "$begin" "$rule" "$end"
    elif [ -n "$base" ]; then
      printf '%s\n' "$base"
    fi
  } > "$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp"; warn "claudemd: cannot write $f — left unchanged"; }
  return 0
}

_CLAUDEMD_BEGIN="# >>> claudefiles:codex-review >>>"
_CLAUDEMD_END="# <<< claudefiles:codex-review <<<"
_CLAUDEMD_RULE='At superpowers checkpoints, run the `codex-review` skill for an independent Codex
cross-review, then triage its findings (superpowers:receiving-code-review) before showing the user:
- after writing a spec to docs/superpowers/specs/ (before the user-review gate),
- after writing a plan to docs/superpowers/plans/,
- at requesting-code-review, on the task diff.
Advisory and single-shot: Codex informs, it does not gate. If codex is unauthenticated, report and skip.'

claudemd_apply() { # <enabled:true|false>
  _claudemd_block_apply "$_CLAUDEMD_BEGIN" "$_CLAUDEMD_END" "$_CLAUDEMD_RULE" "${1:-false}"
}

_PERSONAL_BEGIN="# >>> claudefiles:personal >>>"
_PERSONAL_END="# <<< claudefiles:personal <<<"
_PERSONAL_RULE='Write short and direct. No emojis. No em-dashes. Avoid "ensure", "leverage",
"robust", "seamless", "utilize". Cite file:line when referencing code. No code comments unless asked.'

claudemd_personal_apply() { # <enabled:true|false>
  _claudemd_block_apply "$_PERSONAL_BEGIN" "$_PERSONAL_END" "$_PERSONAL_RULE" "${1:-false}"
}

_VISION_BEGIN="# >>> claudefiles:vision >>>"
_VISION_END="# <<< claudefiles:vision <<<"
_VISION_PRODUCER='This profile owns the VISION stage only. When a discussion settles, write the
outcome to docs/vision/YYYY-MM-DD-<topic>.md: which features are needed, what was decided, what was
dropped and why, how it should look and feel. Do NOT write a specification or an implementation
plan — those belong to the superpowers profile (`claude-super`).'
_VISION_CONSUMER='Before superpowers:brainstorming, check docs/vision/ for a vision document on the
topic at hand. If one exists, read it and treat it as settled input: which features are needed, what
was decided, what was dropped. Do not re-open those questions — turn the vision into a specification.'

claudemd_vision_apply() { # <role:producer|consumer|off>
  case "${1:-off}" in
    producer) _claudemd_block_apply "$_VISION_BEGIN" "$_VISION_END" "$_VISION_PRODUCER" true ;;
    consumer) _claudemd_block_apply "$_VISION_BEGIN" "$_VISION_END" "$_VISION_CONSUMER" true ;;
    *)        _claudemd_block_apply "$_VISION_BEGIN" "$_VISION_END" "" false ;;
  esac
}
