#!/bin/bash
# SwiftBar plugin — Claude session tracker menubar.
# Install: copy (or symlink) into your SwiftBar plugin folder.
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
set -uo pipefail

STATE_DIR="${CST_STATE_DIR:-$HOME/.local/state/claude-session-tracker}/sessions"
# deployed runtime first; repo checkout fallback (symlinked plugin can't rely on $0)
CST="$HOME/.claude/session-tracker/cst"
[ -x "$CST" ] || CST="$(cd "$(dirname "$0")/.." && pwd)/bin/cst"

C_WAIT="#F5A623"
C_RUN="#34C759"
C_DONE="#98989D"
C_DIM="#98989D"

now=$(date +%s)
sessions=$(cat "$STATE_DIR"/*.json 2>/dev/null | jq -s --argjson now "$now" '
  [.[] | select(.status != "ended") | select(($now - (.updated_at // 0)) < 86400)]
  | sort_by(-.updated_at)')

waiting=$(jq 'map(select(.status == "waiting")) | length' <<<"$sessions")
running=$(jq 'map(select(.status == "running")) | length' <<<"$sessions")

# ── menubar title ────────────────────────────────────────────────
if [ "$waiting" -gt 0 ]; then
  echo "$waiting | sfimage=bell.badge.fill"
elif [ "$running" -gt 0 ]; then
  echo "$running | sfimage=terminal.fill"
else
  echo "| sfimage=terminal"
fi
echo "---"

age_of() {
  local a=$(( now - $1 ))
  if   [ "$a" -lt 60 ];   then echo "now"
  elif [ "$a" -lt 3600 ]; then echo "$((a / 60))m"
  else                         echo "$((a / 3600))h"
  fi
}

render_group() { # $1=status filter, $2=header, $3=dot color
  local rows
  rows=$(jq -c --arg st "$1" '.[] | select(.status == $st)' <<<"$sessions")
  [ -n "$rows" ] || return 0
  echo "$2 | size=11 color=$C_DIM"
  while IFS= read -r s; do
    local sid name cwd updated msg age tip
    sid=$(jq -r '.session_id' <<<"$s")
    cwd=$(jq -r '.cwd // "?"' <<<"$s")
    updated=$(jq -r '.updated_at // 0' <<<"$s")
    msg=$(jq -r '.message // ""' <<<"$s")
    name="${cwd##*/}"
    age=$(age_of "$updated")
    tip="${cwd/#$HOME/~}"
    [ -n "$msg" ] && tip="$msg — $tip"
    echo "$name  ·  $age | sfimage=circle.fill sfcolor=$3 tooltip=\"$tip\" bash=$CST param1=jump param2=$sid terminal=false refresh=false"
    echo "Copy resume command | alternate=true sfimage=doc.on.doc bash=$CST param1=copy-resume param2=$sid terminal=false refresh=false"
  done <<<"$rows"
}

total=$(jq 'length' <<<"$sessions")
if [ "$total" -eq 0 ]; then
  echo "No active sessions | color=$C_DIM sfimage=moon.zzz"
else
  render_group waiting "NEEDS INPUT" "$C_WAIT"
  render_group running "RUNNING"     "$C_RUN"
  render_group done    "IDLE"        "$C_DONE"
fi

echo "---"
echo "Clean stale sessions | sfimage=trash bash=$CST param1=clean terminal=false refresh=true"
