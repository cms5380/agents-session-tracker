#!/bin/bash
# SwiftBar plugin — Claude session tracker menubar.
# Install: copy (or symlink) into your SwiftBar plugin folder.
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
set -uo pipefail

STATE_DIR="${CST_STATE_DIR:-$HOME/.local/state/claude-session-tracker}/sessions"
# deployed runtime first; repo checkout fallback (symlinked plugin can't rely on $0)
CST="$HOME/.claude/session-tracker/cst"
[ -x "$CST" ] || CST="$(cd "$(dirname "$0")/.." && pwd)/bin/cst"

running=0 waiting=0 done_=0
rows=""
now=$(date +%s)

for f in "$STATE_DIR"/*.json; do
  [ -e "$f" ] || continue
  IFS=$'\t' read -r status sid cwd updated msg < <(
    jq -r '[.status, .session_id, (.cwd // "?"), (.updated_at // 0), (.message // "")] | @tsv' "$f")
  [ "$status" = "ended" ] && continue
  age=$(( now - updated ))
  [ "$age" -gt 86400 ] && continue
  case "$status" in
    running) icon="🟢"; running=$((running+1)) ;;
    waiting) icon="🟡"; waiting=$((waiting+1)) ;;
    done)    icon="⚪"; done_=$((done_+1)) ;;
    *)       icon="❔" ;;
  esac
  age_s="$((age / 60))m"; [ "$age" -ge 3600 ] && age_s="$((age / 3600))h"
  label="$icon ${cwd##*/} · ${age_s}"
  [ -n "$msg" ] && label="$label · ${msg:0:40}"
  rows+="$label | bash=$CST param1=jump param2=$sid terminal=false refresh=false"$'\n'
done

# menubar title: waiting sessions demand attention first
if [ "$waiting" -gt 0 ]; then
  echo "🟡 $waiting"
elif [ "$running" -gt 0 ]; then
  echo "🟢 $running"
else
  echo "⚪️"
fi
echo "---"
if [ -n "$rows" ]; then
  printf '%s' "$rows"
else
  echo "no active sessions"
fi
echo "---"
echo "Clean stale | bash=$CST param1=clean terminal=false refresh=true"
