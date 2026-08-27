#!/bin/bash
# QA suite for claude-session-tracker (cst + track.sh).
# Runs against a sandbox HOME with stubbed claude/codex CLIs — no real
# sessions, terminals or daemons are touched.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d /tmp/cst-qa.XXXXXX)"
export HOME="$SANDBOX"
export CST_STATE_DIR="$SANDBOX/state"
STATE="$CST_STATE_DIR/sessions"
mkdir -p "$STATE" "$SANDBOX/.local/bin" "$SANDBOX/.claude/projects/-tmp-qa" \
         "$SANDBOX/.codex/sessions/2026/08/27"

# stub agent CLIs — cst puts $HOME/.local/bin first in PATH
cat >"$SANDBOX/.local/bin/claude" <<'EOF'
#!/bin/bash
[ "${1:-}" = "agents" ] && { echo '[]'; exit 0; }
exit 0
EOF
cat >"$SANDBOX/.local/bin/codex" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$SANDBOX/.local/bin/claude" "$SANDBOX/.local/bin/codex"

CST="$REPO/bin/cst"
TRACK="$REPO/hooks/track.sh"
PASS=0; FAIL=0; FAILED=()

t() { # t <name> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); FAILED+=("$1: expected [$2] got [$3]"); fi
}

hook() { # hook <json> [KEY=V ...]
  local payload="$1"; shift
  env "$@" bash "$TRACK" <<<"$payload" 2>/dev/null
}

rec() { jq -r "$2" "$STATE/$1.json" 2>/dev/null; }

NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
OLD_ISO="2020-01-01T00:00:00.000Z"

# ── fixtures ─────────────────────────────────────────────────────
CLT="$SANDBOX/.claude/projects/-tmp-qa/aaaaaaaa-0000-0000-0000-000000000001.jsonl"
cat >"$CLT" <<EOF
{"type":"user","message":{"content":"<system-hint>ignored</system-hint>"},"timestamp":"$NOW_ISO"}
{"type":"user","message":{"content":"첫 프롬프트: QA 테스트"},"timestamp":"$NOW_ISO"}
{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":200}},"timestamp":"$NOW_ISO"}
{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":1}},"timestamp":"$OLD_ISO"}
EOF

CXT="$SANDBOX/.codex/sessions/2026/08/27/rollout-2026-08-27T10-00-00-bbbbbbbb-0000-0000-0000-000000000002.jsonl"
cat >"$CXT" <<EOF
{"type":"session_meta","payload":{"session_id":"bbbbbbbb-0000-0000-0000-000000000002","cwd":"/tmp/qa"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<recommended_plugins> noise QA-MAGIC-CODEX </recommended_plugins>"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"코덱스 QA 프롬프트"}]}}
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42.5,"window_minutes":10080,"resets_at":9999999999}}}}
EOF

# ══ track.sh: event → status mapping ═════════════════════════════
SID1="aaaaaaaa-0000-0000-0000-000000000001"
P1="{\"session_id\":\"$SID1\",\"cwd\":\"/tmp/qa\",\"transcript_path\":\"$CLT\",\"hook_event_name\":"

hook "${P1}\"SessionStart\"}" ITERM_SESSION_ID=w0t1p0:QA-UUID TERM_PROGRAM=iTerm.app
t "T01 SessionStart→done"        "done"    "$(rec "$SID1" .status)"
t "T02 agent=claude"             "claude"  "$(rec "$SID1" .agent)"
t "T03 iterm env captured"       "w0t1p0:QA-UUID" "$(rec "$SID1" .terminal.iterm_session_id)"
t "T04 title=first real prompt"  "첫 프롬프트: QA 테스트" "$(rec "$SID1" .title)"
t "T05 model from transcript"    "claude-opus-5" "$(rec "$SID1" .model)"

hook "${P1}\"UserPromptSubmit\"}"
t "T06 UserPromptSubmit→running" "running" "$(rec "$SID1" .status)"

hook "${P1}\"Notification\",\"message\":\"Claude needs your permission to use Bash\"}"
t "T07 permission→waiting"       "waiting" "$(rec "$SID1" .status)"

hook "${P1}\"Notification\",\"message\":\"Claude is waiting for your input\"}"
t "T08 input-wait→input"         "input"   "$(rec "$SID1" .status)"

hook "${P1}\"UserPromptSubmit\"}"
hook "${P1}\"Notification\",\"message\":\"task finished elsewhere\"}"
t "T09 other notification keeps status" "running" "$(rec "$SID1" .status)"

hook "${P1}\"Stop\"}"
t "T10 Stop→finished"            "finished" "$(rec "$SID1" .status)"

hook "${P1}\"PermissionRequest\"}"
t "T11 PermissionRequest→waiting" "waiting" "$(rec "$SID1" .status)"

hook "${P1}\"SessionEnd\"}"
t "T12 SessionEnd→ended"         "ended"   "$(rec "$SID1" .status)"

hook "${P1}\"UserPromptSubmit\"}"
t "T13 title sticky"             "첫 프롬프트: QA 테스트" "$(rec "$SID1" .title)"

# codex detection
SID2="bbbbbbbb-0000-0000-0000-000000000002"
hook "{\"session_id\":\"$SID2\",\"cwd\":\"/tmp/qa\",\"transcript_path\":\"$CXT\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-sol\"}"
t "T14 agent=codex"              "codex"   "$(rec "$SID2" .agent)"
t "T15 codex title skips <blocks>" "코덱스 QA 프롬프트" "$(rec "$SID2" .title)"
t "T16 codex model from payload" "gpt-5.6-sol" "$(rec "$SID2" .model)"

# corrupt record self-heal
SID3="cccccccc-0000-0000-0000-000000000003"
printf '{"broken json' >"$STATE/$SID3.json"
hook "{\"session_id\":\"$SID3\",\"cwd\":\"/tmp/qa\",\"hook_event_name\":\"SessionStart\"}"
t "T17 corrupt record self-heals" "done"   "$(rec "$SID3" .status)"

# no session_id → no new file
before=$(ls "$STATE" | wc -l | tr -d ' ')
hook "{\"cwd\":\"/tmp\",\"hook_event_name\":\"SessionStart\"}"
after=$(ls "$STATE" | wc -l | tr -d ' ')
t "T18 no sid → no record"       "$before" "$after"

# ══ sessions-json filtering ══════════════════════════════════════
NOW=$(date +%s)
mkrec() { jq -n "{session_id: \"$1\", updated_at: $NOW} + $2" >"$STATE/$1.json"; }
rm -f "$STATE"/*.json

sleep 600 </dev/null >/dev/null 2>&1 & LIVE1=$!
sleep 600 </dev/null >/dev/null 2>&1 & LIVE2=$!

mkrec "s-ended"   '{status:"ended", owner:"client", pid:99999}'
mkrec "s-old"     "{status:\"done\", owner:\"client\", pid:$LIVE1, updated_at: $((NOW - 90000))}"
mkrec "s-deadcli" '{status:"running", owner:"client", pid:99999, title:"t"}'
mkrec "s-deadpool" '{status:"running", owner:"pool", pid:99999, title:"t"}'
mkrec "s-legacy-titled" '{status:"done", pid:99999, title:"legacy"}'
mkrec "s-legacy-untitled" '{status:"done", pid:99999}'
mkrec "s-alive"   "{status:\"running\", owner:\"client\", pid:$LIVE1, title:\"alive\"}"
mkrec "s-cx-stale" "{status:\"running\", owner:\"client\", pid:$LIVE2, agent:\"codex\", transcript_path:\"$CXT\"}"
touch -t 202001010000 "$CXT"
printf 'not json' >"$STATE/s-corrupt.json"

SJ=$("$CST" sessions-json 2>/dev/null)
sjq() { jq -r "$1" <<<"$SJ"; }
t "T20 ended excluded"     ""        "$(sjq '.[] | select(.session_id=="s-ended") | .session_id')"
t "T21 24h+ old excluded"  ""        "$(sjq '.[] | select(.session_id=="s-old") | .session_id')"
t "T22 dead client → gone" "gone"    "$(sjq '.[] | select(.session_id=="s-deadcli") | .status')"
t "T23 dead pool dropped"  ""        "$(sjq '.[] | select(.session_id=="s-deadpool") | .session_id')"
t "T24 legacy titled → gone" "gone"  "$(sjq '.[] | select(.session_id=="s-legacy-titled") | .status')"
t "T25 legacy untitled dropped" ""   "$(sjq '.[] | select(.session_id=="s-legacy-untitled") | .session_id')"
t "T26 alive kept running" "running" "$(sjq '.[] | select(.session_id=="s-alive") | .status')"
t "T27 codex stale → done" "done"    "$(sjq '.[] | select(.session_id=="s-cx-stale") | .status')"
t "T28 corrupt file skipped, list survives" "ok" "$(jq -e 'length >= 4' <<<"$SJ" >/dev/null && echo ok)"

touch "$CXT"
SJ=$("$CST" sessions-json 2>/dev/null)
t "T29 codex fresh stays running" "running" "$(sjq '.[] | select(.session_id=="s-cx-stale") | .status')"

# ══ group / pin / rename state ═══════════════════════════════════
"$CST" group s-alive "QA그룹" >/dev/null 2>&1
SJ=$("$CST" sessions-json 2>/dev/null)
t "T30 group assign"  "QA그룹"  "$(sjq '.[] | select(.session_id=="s-alive") | .group')"

"$CST" title s-alive "새이름" >/dev/null 2>&1
SJ=$("$CST" sessions-json 2>/dev/null)
t "T31 rename override" "새이름" "$(sjq '.[] | select(.session_id=="s-alive") | .title')"

"$CST" pin s-alive >/dev/null 2>&1
SJ=$("$CST" sessions-json 2>/dev/null)
t "T32 pin sets pin_order" "0" "$(sjq '.[] | select(.session_id=="s-alive") | .pin_order')"
"$CST" pin s-alive >/dev/null 2>&1
SJ=$("$CST" sessions-json 2>/dev/null)
t "T33 pin toggles off" "null" "$(sjq '.[] | select(.session_id=="s-alive") | .pin_order')"

"$CST" group-color "QA그룹" blue >/dev/null 2>&1
SJ=$("$CST" sessions-json 2>/dev/null)
t "T34 group color" "blue" "$(sjq '.[] | select(.session_id=="s-alive") | .group_color')"

"$CST" group s-alive - >/dev/null 2>&1
SJ=$("$CST" sessions-json 2>/dev/null)
t "T35 group unassign" "null" "$(sjq '.[] | select(.session_id=="s-alive") | .group')"

# ══ stop-session / end lifecycle ═════════════════════════════════
sleep 600 </dev/null >/dev/null 2>&1 & SP1=$!
mkrec "s-stop-run" "{status:\"running\", owner:\"client\", pid:$SP1, title:\"x\"}"
"$CST" stop-session s-stop-run >/dev/null 2>&1
t "T40 stop running → done"  "done" "$(rec s-stop-run .status)"
kill -0 "$SP1" 2>/dev/null && ALIVE=yes || ALIVE=no
t "T41 stop keeps process"   "yes"  "$ALIVE"

"$CST" stop-session s-stop-run >/dev/null 2>&1
t "T42 stop idle → gone"     "gone" "$(rec s-stop-run .status)"
kill -0 "$SP1" 2>/dev/null && ALIVE=yes || ALIVE=no
t "T43 shelve keeps process" "yes"  "$ALIVE"

"$CST" end s-stop-run >/dev/null 2>&1
sleep 0.3
t "T44 end → ended"          "ended" "$(rec s-stop-run .status)"
kill -0 "$SP1" 2>/dev/null && ALIVE=yes || ALIVE=no
t "T45 end kills process"    "no"   "$ALIVE"

sleep 600 </dev/null >/dev/null 2>&1 & SP2=$!
mkrec "s-cx-stop" "{status:\"running\", owner:\"client\", pid:$SP2, agent:\"codex\", transcript_path:\"$CXT\"}"
"$CST" stop-session s-cx-stop >/dev/null 2>&1
t "T46 codex stop → done"    "done" "$(rec s-cx-stop .status)"
"$CST" end s-cx-stop >/dev/null 2>&1
sleep 0.3
kill -0 "$SP2" 2>/dev/null && ALIVE=yes || ALIVE=no
t "T47 codex end kills proc" "no"   "$ALIVE"

# ══ archive-search ═══════════════════════════════════════════════
AS=$("$CST" archive-search "QA 테스트" 2>/dev/null)
t "T50 claude transcript hit" "aaaaaaaa-0000-0000-0000-000000000001" \
  "$(jq -r '.[0].session_id // ""' <<<"$AS")"
AS=$("$CST" archive-search "QA-MAGIC-CODEX" 2>/dev/null)
t "T51 codex rollout hit"    "bbbbbbbb-0000-0000-0000-000000000002" \
  "$(jq -r '.[0].session_id // ""' <<<"$AS")"
t "T52 codex hit agent tag"  "codex" "$(jq -r '.[0].agent // ""' <<<"$AS")"
t "T53 codex title extracted" "코덱스 QA 프롬프트" "$(jq -r '.[0].title // ""' <<<"$AS")"
AS=$("$CST" archive-search "zzz-no-match-zzz" 2>/dev/null)
t "T54 no match → []"        "0" "$(jq 'length' <<<"$AS")"

# ══ usage-json ═══════════════════════════════════════════════════
rm -f "$CST_STATE_DIR/usage-cache.json"
touch "$CXT" "$CLT"
UJ=$("$CST" usage-json 2>/dev/null)
t "T60 codex used_percent"   "42.5" "$(jq -r '.codex.primary.used_percent' <<<"$UJ")"
t "T61 claude 5h input sum"  "100"  "$(jq -r '.claude.input' <<<"$UJ")"
t "T62 claude 5h output sum (old excluded)" "200" "$(jq -r '.claude.output' <<<"$UJ")"
t "T63 usage cache written"  "yes"  "$([ -f "$CST_STATE_DIR/usage-cache.json" ] && echo yes)"

# ══ clean ════════════════════════════════════════════════════════
mkrec "s-clean-ended" '{status:"ended", owner:"client"}'
mkrec "s-clean-old"   "{status:\"done\", owner:\"client\", updated_at: $((NOW - 90000))}"
mkrec "s-clean-keep"  '{status:"done", owner:"client", title:"keep"}'
"$CST" clean 24 >/dev/null 2>&1
t "T70 clean drops ended" "no"  "$([ -f "$STATE/s-clean-ended.json" ] && echo yes || echo no)"
t "T71 clean drops old"   "no"  "$([ -f "$STATE/s-clean-old.json" ] && echo yes || echo no)"
t "T72 clean keeps fresh" "yes" "$([ -f "$STATE/s-clean-keep.json" ] && echo yes || echo no)"

# ══ fork lineage: hide/nest ══════════════════════════════════════
PSID="dddddddd-0000-0000-0000-000000000004"
FSID="eeeeeeee-0000-0000-0000-000000000005"
sleep 600 </dev/null >/dev/null 2>&1 & PP=$!
sleep 600 </dev/null >/dev/null 2>&1 & FP=$!
# a live process whose cmdline carries the fork markers. The loop form
# keeps bash from exec-replacing itself (which would drop the argv) and
# leaves no long-lived orphan child when killed.
bash -c 'while :; do sleep 1; done' qa-fork --session-id "$FSID" --fork-session --resume "/tmp/qa/$PSID.jsonl" </dev/null >/dev/null 2>&1 &
FORKPROC=$!
sleep 0.2
mkrec "$PSID" "{status:\"running\", owner:\"client\", pid:$PP, title:\"parent\"}"
mkrec "$FSID" "{status:\"running\", owner:\"client\", pid:$FP, title:\"child\", updated_at: $((NOW + 100))}"
SJ=$("$CST" sessions-json 2>/dev/null)
t "T80 fork newer → parent hidden" "" "$(sjq ".[] | select(.session_id==\"$PSID\") | .session_id")"
t "T81 fork visible"               "$FSID" "$(sjq ".[] | select(.session_id==\"$FSID\") | .session_id")"

# parent newer again → both visible, child annotated with parent
jq ".updated_at = $((NOW + 500))" "$STATE/$PSID.json" >"$STATE/$PSID.json.n" \
  && mv "$STATE/$PSID.json.n" "$STATE/$PSID.json"
SJ=$("$CST" sessions-json 2>/dev/null)
t "T82 parent newer → shown"       "$PSID" "$(sjq ".[] | select(.session_id==\"$PSID\") | .session_id")"
t "T83 child carries parent id"    "$PSID" "$(sjq ".[] | select(.session_id==\"$FSID\") | .parent")"
kill "$PP" "$FP" "$FORKPROC" 2>/dev/null

# ══ send routing (stubs log their argv) ══════════════════════════
cat >"$SANDBOX/.local/bin/claude" <<EOF
#!/bin/bash
[ "\${1:-}" = "agents" ] && { echo '[]'; exit 0; }
echo "claude \$*" >>"$SANDBOX/calls.log"
EOF
cat >"$SANDBOX/.local/bin/codex" <<EOF
#!/bin/bash
echo "codex \$*" >>"$SANDBOX/calls.log"
EOF
chmod +x "$SANDBOX/.local/bin/claude" "$SANDBOX/.local/bin/codex"

mkrec "s-send-cl" '{status:"done", owner:"client", cwd:"/tmp"}'
mkrec "s-send-cx" '{status:"done", owner:"client", cwd:"/tmp", agent:"codex"}'
"$CST" send s-send-cl "hello cl" >/dev/null 2>&1
"$CST" send s-send-cx "hello cx" >/dev/null 2>&1
sleep 1
t "T90 send routes claude" "1" "$(grep -c 'claude -p --resume s-send-cl' "$SANDBOX/calls.log" 2>/dev/null)"
t "T91 send routes codex"  "1" "$(grep -c 'codex exec resume s-send-cx' "$SANDBOX/calls.log" 2>/dev/null)"

# ── teardown ─────────────────────────────────────────────────────
kill "$LIVE1" "$LIVE2" 2>/dev/null
echo
echo "PASS: $PASS  FAIL: $FAIL"
for f in "${FAILED[@]:-}"; do [ -n "$f" ] && echo "  ✗ $f"; done
rm -rf "$SANDBOX"
[ "$FAIL" -eq 0 ]
