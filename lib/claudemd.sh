# claudemd.sh — own a marker-delimited block in ~/.claude/CLAUDE.md, preserve the rest.
# Deterministic: strip our block + trailing blank lines, then re-append if enabled.
# Re-running with the same <enabled> yields a byte-identical file. Source, don't execute.
_CLAUDEMD_BEGIN="# >>> claudefiles:codex-review >>>"
_CLAUDEMD_END="# <<< claudefiles:codex-review <<<"
_CLAUDEMD_RULE='At superpowers checkpoints, run the `codex-review` skill for an independent Codex
cross-review, then triage its findings (superpowers:receiving-code-review) before showing the user:
- after writing a spec to docs/superpowers/specs/ (before the user-review gate),
- after writing a plan to docs/superpowers/plans/,
- at requesting-code-review, on the task diff.
Advisory and single-shot: Codex informs, it does not gate. If codex is unauthenticated, report and skip.'

claudemd_apply() { # <enabled:true|false>
  local enabled="${1:-false}"
  local f="${CLAUDEFILES_CLAUDE_MD:-${CLAUDEFILES_TARGET:-$HOME/.claude}/CLAUDE.md}"
  # disable + no file -> nothing to do (don't create a spurious file)
  [ "$enabled" != true ] && [ ! -f "$f" ] && return 0
  mkdir -p "$(dirname "$f")"
  # base = existing content minus our block, with trailing blank lines trimmed
  local base=""
  [ -f "$f" ] && base="$(awk -v b="$_CLAUDEMD_BEGIN" -v e="$_CLAUDEMD_END" '
      $0==b{skip=1;next} $0==e{skip=0;next}
      !skip{a[++n]=$0; if(NF)last=n}
      END{for(i=1;i<=last;i++)print a[i]}' "$f")"
  {
    if [ "$enabled" = true ]; then
      [ -n "$base" ] && printf '%s\n\n' "$base"
      printf '%s\n%s\n%s\n' "$_CLAUDEMD_BEGIN" "$_CLAUDEMD_RULE" "$_CLAUDEMD_END"
    else
      [ -n "$base" ] && printf '%s\n' "$base"
    fi
  } > "$f"
  return 0
}

_PERSONAL_BEGIN="# >>> claudefiles:personal >>>"
_PERSONAL_END="# <<< claudefiles:personal <<<"
_PERSONAL_RULE='Write short and direct. No emojis. No em-dashes. Avoid "ensure", "leverage",
"robust", "seamless", "utilize". Cite file:line when referencing code. No code comments unless asked.'

claudemd_personal_apply() { # <enabled:true|false>
  local enabled="${1:-false}"
  local f="${CLAUDEFILES_CLAUDE_MD:-${CLAUDEFILES_TARGET:-$HOME/.claude}/CLAUDE.md}"
  [ "$enabled" != true ] && [ ! -f "$f" ] && return 0
  mkdir -p "$(dirname "$f")"
  local base=""
  [ -f "$f" ] && base="$(awk -v b="$_PERSONAL_BEGIN" -v e="$_PERSONAL_END" '
      $0==b{skip=1;next} $0==e{skip=0;next}
      !skip{a[++n]=$0; if(NF)last=n}
      END{for(i=1;i<=last;i++)print a[i]}' "$f")"
  {
    if [ "$enabled" = true ]; then
      [ -n "$base" ] && printf '%s\n\n' "$base"
      printf '%s\n%s\n%s\n' "$_PERSONAL_BEGIN" "$_PERSONAL_RULE" "$_PERSONAL_END"
    else
      [ -n "$base" ] && printf '%s\n' "$base"
    fi
  } > "$f"
  return 0
}
