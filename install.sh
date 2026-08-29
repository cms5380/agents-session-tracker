#!/bin/bash
# claude-session-tracker installer
#   ./install.sh          install / update everything
#   ./install.sh --codex  also wire up OpenAI Codex hooks (~/.codex/hooks.json)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/session-tracker"
APP="/Applications/Agents Session Tracker.app"
SETTINGS="$HOME/.claude/settings.json"
TRACK="$DEST/track.sh"

err() { echo "error: $*" >&2; exit 1; }

# ── prerequisites ────────────────────────────────────────────────
command -v jq >/dev/null || err "jq is required (brew install jq)"
command -v swiftc >/dev/null || err "swiftc is required (xcode-select --install)"
command -v claude >/dev/null || echo "warn: claude CLI not found — install Claude Code first" >&2

# ── scripts ──────────────────────────────────────────────────────
mkdir -p "$DEST"
cp "$REPO_DIR/bin/ast" "$DEST/ast"
cp "$REPO_DIR/hooks/track.sh" "$TRACK"
chmod +x "$DEST/ast" "$TRACK"
# the CLI used to be called cst — keep the old name working for anything
# (older app builds, user scripts, muscle memory) that still calls it
rm -f "$DEST/cst"
ln -s "$DEST/ast" "$DEST/cst"
echo "installed: $DEST/{ast,track.sh}"

# ── claude hooks (merged into ~/.claude/settings.json) ───────────
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-cst"
jq --arg cmd "/bin/bash $TRACK" '
  .hooks = (.hooks // {})
  | reduce ("SessionStart","UserPromptSubmit","PreToolUse","PermissionRequest","Notification","Stop","SessionEnd") as $ev (.;
      .hooks[$ev] = (
        ((.hooks[$ev] // []) | map(select((.hooks // []) | any(.command == $cmd) | not)))
        + [{hooks: [{type: "command", command: $cmd}]}]))
' "$SETTINGS" >"$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
echo "registered claude hooks (backup: $SETTINGS.bak-cst)"

# ── menubar app ──────────────────────────────────────────────────
mkdir -p "$APP/Contents/MacOS"
cp "$REPO_DIR/menubar/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "$REPO_DIR/menubar/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
echo "building AgentsSessionTracker.app (first build takes ~30s)…"
swiftc -O -o "$APP/Contents/MacOS/AgentsSessionTracker" "$REPO_DIR/menubar/AgentsSessionTracker.swift"
# ad-hoc signature — notification registration doesn't stick without one
codesign --force --deep -s - "$APP" 2>/dev/null || true
echo "built: $APP"

# ── starter custom commands (kept if one already exists) ─────────
CMDS="$HOME/.local/state/claude-session-tracker/commands.json"
if [ ! -f "$CMDS" ]; then
  mkdir -p "$(dirname "$CMDS")"
  cat >"$CMDS" <<'JSON'
{
  "g": "@open 'https://www.google.com/search?q={query}'",
  "c": "cd ~/Documents/GitHub/{query} && claude {prompt}"
}
JSON
  echo "starter commands: $CMDS"
fi

# ── login autostart ──────────────────────────────────────────────
LA="$HOME/Library/LaunchAgents/com.dean.claude-sessions.plist"
mkdir -p "$(dirname "$LA")"
cat >"$LA" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.dean.claude-sessions</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
echo "login autostart: $LA"



# ── codex hooks (optional) ───────────────────────────────────────
if [ "${1:-}" = "--codex" ]; then
  CODEX_HOOKS="$HOME/.codex/hooks.json"
  mkdir -p "$HOME/.codex"
  [ -f "$CODEX_HOOKS" ] && cp "$CODEX_HOOKS" "$CODEX_HOOKS.bak-cst"
  # NOTE: codex trust keys embed positional indices — never REORDER this
  # event list (append only), or every user gets re-prompted to trust
  jq -n --arg cmd "/bin/bash $TRACK" '
    {hooks: (reduce ("SessionStart","UserPromptSubmit","PreToolUse","PermissionRequest","Stop","SessionEnd") as $ev ({};
      .[$ev] = [{hooks: [{type: "command", command: $cmd}]}]))}
  ' >"$CODEX_HOOKS"
  echo "codex hooks written: $CODEX_HOOKS"
  echo "  → run codex once and approve the hook-trust prompt"
fi

# ── launch ───────────────────────────────────────────────────────
pkill -f "MacOS/AgentsSessionTracker" 2>/dev/null || true
sleep 0.5
open "$APP"

cat <<'EOM'

done. next steps:
  1. press ⌥Space to open the panel (menubar mascot also toggles it)
  2. grant the permission prompts on first use:
     - notifications (session status alerts)
     - iTerm2 / System Events automation (jump-to-session)
  3. start a claude session in any terminal — it appears in the panel
EOM
