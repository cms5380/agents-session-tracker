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
transcript=$(jq -r '.transcript_path // empty' <<<"$input")
model=$(jq -r '.model // empty' <<<"$input")

# which agent produced this session — codex writes rollout files under
# ~/.codex/sessions and speaks the same hook protocol
agent="claude"
case "$transcript" in */.codex/*) agent="codex" ;; esac

# the payload's transcript path can be stale (forks/worktrees land in a
# different per-project dir) — relocate by session id
if [ "$agent" = "claude" ] && [ -n "$transcript" ] && [ ! -f "$transcript" ]; then
  alt=$(ls "$HOME/.claude/projects"/*/"$session_id.jsonl" 2>/dev/null | head -1 || true)
  [ -n "$alt" ] && transcript="$alt"
fi

# human-readable session title: first user prompt (immutable), else the
# transcript summary — summaries evolve every few turns and made names churn
title=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  if [ "$agent" = "codex" ]; then
    # skip injected context messages (they start with an <xml-ish> tag) at the
    # message level — their bodies span lines that a line filter would keep
    title=$( (head -n 200 "$transcript" 2>/dev/null \
      | jq -r 'select(.type=="response_item") | .payload
               | select(.type=="message" and .role=="user")
               | ((.content // []) | map(select(.type=="input_text")) | first // {}).text // empty
               | select(length > 0) | select(startswith("<") | not)' 2>/dev/null \
      | head -n 1 | cut -c1-80) || true)
  else
    title=$( (head -n 80 "$transcript" 2>/dev/null \
      | jq -r 'select(.type=="user") | .message.content
               | if type=="string" then . else ((map(select(.type=="text")) | first // {}).text // empty) end' 2>/dev/null \
      | grep -vE '^\s*(<|$)' | head -n 1 | cut -c1-80) || true)
    if [ -z "$title" ]; then
      title=$( (grep '"type":"summary"' "$transcript" 2>/dev/null | tail -1 | jq -r '.summary // empty' 2>/dev/null) || true)
    fi
  fi
fi

# claude hooks don't carry the model — read it from the transcript's most
# recent assistant message (cheap: tail keeps it current after /model swaps)
if [ -z "$model" ] && [ "$agent" = "claude" ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  model=$( (tail -n 40 "$transcript" 2>/dev/null \
    | jq -r 'select(.type=="assistant") | .message.model // empty
             | select(startswith("<") | not)' 2>/dev/null \
    | tail -n 1) || true)
fi

case "$event" in
  # a freshly opened/resumed session sits idle at the prompt — only an actual
  # prompt submission marks it running
  SessionStart) status="done" ;;
  UserPromptSubmit|PreToolUse) status="running" ;;
  Notification)
    # only actionable asks raise NEEDS INPUT: permission prompts. The 60s-idle
    # ping means the turn is over; other notifications (completion notices,
    # forwarded task events) keep the current status.
    case "$message" in
      *permission*|*Permission*) status="waiting" ;;
      *"waiting for your input"*) status="input" ;;
      *) status="" ;;
    esac
    ;;
  # codex asks for tool approval via its own PermissionRequest hook event
  PermissionRequest) status="waiting" ;;
  Stop) status="finished" ;;
  SessionEnd) status="ended" ;;
  *) status="running" ;;
esac

# the owning agent process. Claude runs hooks as a direct child; codex runs
# them via a $SHELL -lc wrapper, so walk up until the codex process is found
owner_pid="$PPID"
if [ "$agent" = "codex" ]; then
  p="$PPID"
  for _ in 1 2 3; do
    cmd=$(ps -o command= -p "$p" 2>/dev/null || true)
    case "$cmd" in *codex*) owner_pid="$p"; break ;; esac
    np=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
    case "$np" in ''|0|1) break ;; esac
    p="$np"
  done
fi

# tty of the agent process — Terminal.app fallback driver uses it
claude_tty=$(ps -o tty= -p "$owner_pid" 2>/dev/null | tr -d ' ' || true)
[ "$claude_tty" = "??" ] && claude_tty=""

# classify the owning process so phantom sessions (spawned by agents-view
# TUIs / the spare pool) can be told apart from real clients after death
owner_cmd=$(ps -o command= -p "$owner_pid" 2>/dev/null || true)
case "$owner_cmd" in
  *bg-spare*|*bg-pty-host*|*"claude agents"*) owner="pool" ;;
  *) owner="client" ;;
esac

# VSCode-spawned sessions have no terminal env but can be jumped to via the app
app=""
if [ "${TERM_PROGRAM:-}" = "vscode" ] || [ -n "${VSCODE_GIT_ASKPASS_MAIN:-}" ] || [ "${__CFBundleIdentifier:-}" = "com.microsoft.VSCode" ]; then
  app="vscode"
fi

file="$STATE_DIR/$session_id.json"
existing="{}"
[ -f "$file" ] && existing=$(cat "$file")
# a torn record (crashed writer) must not wedge the hook — start fresh
jq -e . >/dev/null 2>&1 <<<"$existing" || existing="{}"

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
  --arg pid "$owner_pid" \
  --arg owner "$owner" \
  --arg title "$title" \
  --arg transcript "$transcript" \
  --arg agent "$agent" \
  --arg model "$model" \
  '$prev * {
    session_id: $session_id,
    last_event: $event,
    pid: ($pid | tonumber),
    owner: $owner,
    agent: $agent,
    updated_at: ($updated_at | tonumber)
  }
  | .status = (if $status == "" then (.status // "running") else $status end)
  | .started_at = (.started_at // ($updated_at | tonumber))
  | if $cwd != "" then .cwd = $cwd else . end
  | if $message != "" then .message = $message else . end
  | if $title != "" and ((.title // "") == "") then .title = $title else . end
  | if $transcript != "" then .transcript_path = $transcript else . end
  | if $model != "" then .model = $model else . end
  | .terminal = ((.terminal // {}) * ({
      term_program: $term_program,
      iterm_session_id: $iterm_session_id,
      cmux_workspace_id: $cmux_workspace_id,
      cmux_surface_id: $cmux_surface_id,
      tmux_pane: $tmux_pane,
      tty: $tty,
      app: $app
    } | with_entries(select(.value != ""))))
  ' >"$file.tmp.$$" && mv "$file.tmp.$$" "$file"

exit 0
