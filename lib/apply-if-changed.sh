# apply-if-changed.sh — run a callback only when HEAD differs from last applied.
apply_if_changed() { # apply_if_changed <head> <callback>
  local head="$1" cb="$2"
  local state="${CLAUDEFILES_STATE_DIR:-$HOME/.config/claudefiles}/last-applied-head"
  [ -f "$state" ] && [ "$(cat "$state")" = "$head" ] && return 0
  "$cb"
  mkdir -p "$(dirname "$state")"; printf '%s' "$head" > "$state"
}
