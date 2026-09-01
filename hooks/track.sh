#!/bin/bash
# Claude Code hook: records session state + terminal identity for jump-back.
# Wire this single script to SessionStart / Notification / Stop / SessionEnd.
set -euo pipefail

STATE_DIR="${CST_STATE_DIR:-$HOME/.local/state/claude-session-tracker}/sessions"
mkdir -p "$STATE_DIR"

# internal headless helpers (cst tidy ai etc.) must not appear as sessions
[ -n "${CST_INTERNAL:-}" ] && exit 0

input=$(cat)
# one jq for the whole payload — this runs on every tool call, so a field-at-
# a-time parse (6 spawns) was the hook's dominant cost. Message goes last and
# is slurped by the loop below because it may itself span lines.
message=""
# trailing empty fields vanish with the trailing newlines of $( ), so every
# read must tolerate EOF — otherwise set -e kills the hook mid-parse
session_id=""; event=""; cwd=""; transcript=""; model=""
{
  IFS= read -r session_id || true
  IFS= read -r event || true
  IFS= read -r cwd || true
  IFS= read -r transcript || true
  IFS= read -r model || true
  while IFS= read -r _line; do message="$message$_line"; done
} <<<"$(jq -r '[(.session_id // ""), (.hook_event_name // ""), (.cwd // ""),
                (.transcript_path // ""), (.model // ""), (.message // "")]
               | join("\n")' <<<"$input" 2>/dev/null)"
[ -n "$session_id" ] || exit 0

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

# the record is read early so the expensive transcript digs below can be
# skipped once title/model are already known — this script runs on every
# tool call, so the common case must stay cheap
file="$STATE_DIR/$session_id.json"
existing="{}"
[ -f "$file" ] && existing=$(cat "$file")
# a torn record (crashed writer) must not wedge the hook — the same jq that
# reports what the record already knows doubles as the validity check
have=$(jq -r '(if (.title // "") != "" then "t" else "" end)
              + (if (.model // "") != "" then "m" else "" end)' <<<"$existing" 2>/dev/null) \
  || { existing="{}"; have=""; }

# human-readable session title: first user prompt (immutable), else the
# transcript summary — summaries evolve every few turns and made names churn
title=""
if [ -n "$transcript" ] && [ -f "$transcript" ] && [ "${have#*t}" = "$have" ]; then
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
    # continuation boilerplate is not a name — a compaction summary is one
    # giant message, so it must be dropped whole (line filters let its body
    # through: "Summary:" → next line "1. Primary Request and Intent:" …)
    title=$( (head -n 80 "$transcript" 2>/dev/null \
      | jq -r 'select(.type=="user") | .message.content
               | if type=="string" then . else ((map(select(.type=="text")) | first // {}).text // empty) end
               | select(test("This session is being continued|Primary Request and Intent|^(Summary|Analysis):") | not)' 2>/dev/null \
      | grep -vE '^\s*(<|$)' \
      | head -n 1 | cut -c1-80) || true)
    if [ -z "$title" ]; then
      title=$( (head -n 5 "$transcript" 2>/dev/null \
        | jq -r 'select(.type=="ai-title") | .aiTitle // empty' 2>/dev/null | head -n 1) || true)
    fi
    if [ -z "$title" ]; then
      title=$( (grep '"type":"summary"' "$transcript" 2>/dev/null | tail -1 | jq -r '.summary // empty' 2>/dev/null) || true)
    fi
  fi
fi

# claude hooks don't carry the model — read it from the transcript's most
# recent assistant message. Once known it's only re-read at turn start, so
# /model swaps still land on the next prompt without a tail per tool call.
if [ -z "$model" ] && [ "$agent" = "claude" ] && [ -n "$transcript" ] && [ -f "$transcript" ] \
   && { [ "${have#*m}" = "$have" ] || [ "$event" = "UserPromptSubmit" ]; }; then
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
  # a naturally closed session (tab closed, reboot) stays resumable in the
  # ENDED section — only an explicit ^X^X (cst end) marks it "ended"/hidden
  SessionEnd) status="gone" ;;
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

# headless one-shot runs have no terminal of their own: claude -p and
# codex exec inherit the launching session's tab, so a row for them would
# only jump back to their parent. Skills that shell out to another agent
# (e.g. /create-pr calling codex) land here.
owner_cmd=$(ps -o command= -p "$owner_pid" 2>/dev/null || true)
# match the binary itself, not any ancestor that merely mentions these words
# in its command line (a shell running this very script would qualify)
case "$owner_cmd" in
  (*/claude" -p "*|*/claude" --print "*|*/claude" -p"|*/claude" --print") exit 0 ;;
  (claude" -p "*|claude" --print "*) exit 0 ;;
  (*/codex" exec "*|codex" exec "*) exit 0 ;;
esac

# tty of the agent process — Terminal.app fallback driver uses it
claude_tty=$(ps -o tty= -p "$owner_pid" 2>/dev/null | tr -d ' ' || true)
[ "$claude_tty" = "??" ] && claude_tty=""

# classify the owning process so phantom sessions (spawned by agents-view
# TUIs / the spare pool) can be told apart from real clients after death
case "$owner_cmd" in
  *bg-spare*|*bg-pty-host*|*"claude agents"*) owner="pool" ;;
  *) owner="client" ;;
esac

# VSCode-spawned sessions have no terminal env but can be jumped to via the app
app=""
if [ "${TERM_PROGRAM:-}" = "vscode" ] || [ -n "${VSCODE_GIT_ASKPASS_MAIN:-}" ] || [ "${__CFBundleIdentifier:-}" = "com.microsoft.VSCode" ]; then
  app="vscode"
fi

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
  | .status = (if $status == "" then (.status // "running")
               # an explicit cst end already marked it ended — the SessionEnd
               # from the dying client must not resurrect it as resumable
               elif $event == "SessionEnd" and .status == "ended" then "ended"
               else $status end)
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
