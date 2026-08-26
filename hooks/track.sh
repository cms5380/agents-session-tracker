#!/bin/bash
# Claude Code hook: records session state + terminal identity for jump-back.
# Wire this single script to SessionStart / Notification / Stop / SessionEnd.
set -euo pipefail

STATE_DIR="${CST_STATE_DIR:-$HOME/.local/state/claude-session-tracker}/sessions"
mkdir -p "$STATE_DIR"

input=$(cat)
session_id=$(jq -r '.session_id // empty' <<<"$input")
[ -n "$session_id" ] || exit 0

event=$(jq -r '.hook_event_name // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
message=$(jq -r '.message // empty' <<<"$input")

case "$event" in
  SessionStart|UserPromptSubmit|PreToolUse) status="running" ;;
  Notification) status="waiting" ;;
  Stop) status="done" ;;
  SessionEnd) status="ended" ;;
  *) status="running" ;;
esac

# tty of the claude process (hook's parent) — Terminal.app fallback driver uses it
claude_tty=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ' || true)
[ "$claude_tty" = "??" ] && claude_tty=""

# VSCode-spawned sessions have no terminal env but can be jumped to via the app
app=""
if [ "${TERM_PROGRAM:-}" = "vscode" ] || [ -n "${VSCODE_GIT_ASKPASS_MAIN:-}" ] || [ "${__CFBundleIdentifier:-}" = "com.microsoft.VSCode" ]; then
  app="vscode"
fi

file="$STATE_DIR/$session_id.json"
existing="{}"
[ -f "$file" ] && existing=$(cat "$file")

jq -n \
  --argjson prev "$existing" \
  --arg session_id "$session_id" \
  --arg status "$status" \
  --arg event "$event" \
  --arg cwd "$cwd" \
  --arg message "$message" \
  --arg updated_at "$(date +%s)" \
  --arg term_program "${TERM_PROGRAM:-}" \
  --arg iterm_session_id "${ITERM_SESSION_ID:-}" \
  --arg cmux_workspace_id "${CMUX_WORKSPACE_ID:-}" \
  --arg cmux_surface_id "${CMUX_SURFACE_ID:-}" \
  --arg tmux_pane "${TMUX_PANE:-}" \
  --arg tty "$claude_tty" \
  --arg app "$app" \
  --arg pid "$PPID" \
  '$prev * {
    session_id: $session_id,
    status: $status,
    last_event: $event,
    pid: ($pid | tonumber),
    updated_at: ($updated_at | tonumber)
  }
  | if $cwd != "" then .cwd = $cwd else . end
  | if $message != "" then .message = $message else . end
  | .terminal = ((.terminal // {}) * ({
      term_program: $term_program,
      iterm_session_id: $iterm_session_id,
      cmux_workspace_id: $cmux_workspace_id,
      cmux_surface_id: $cmux_surface_id,
      tmux_pane: $tmux_pane,
      tty: $tty,
      app: $app
    } | with_entries(select(.value != ""))))
  ' >"$file.tmp" && mv "$file.tmp" "$file"

exit 0
