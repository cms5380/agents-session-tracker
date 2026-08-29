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
t "T12 SessionEnd→gone (resumable)" "gone" "$(rec "$SID1" .status)"

# an explicit end (record already ended) survives the dying client's hook
jq '.status = "ended"' "$STATE/$SID1.json" >"$STATE/$SID1.json.t" && mv "$STATE/$SID1.json.t" "$STATE/$SID1.json"
hook "${P1}\"SessionEnd\"}"
t "T12b explicit ended not resurrected" "ended" "$(rec "$SID1" .status)"
jq '.status = "gone"' "$STATE/$SID1.json" >"$STATE/$SID1.json.t" && mv "$STATE/$SID1.json.t" "$STATE/$SID1.json"

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
t "T20a fresh tombstone kept" "yes"  "$([ -f "$STATE/s-ended.json" ] && echo yes)"
touch -t 202001010000 "$STATE/s-ended.json"
"$CST" sessions-json >/dev/null 2>&1
t "T20b old tombstone reaped" ""     "$([ -f "$STATE/s-ended.json" ] && echo yes)"
mkrec "s-ended"   '{status:"ended", owner:"client", pid:99999}'
SJ=$("$CST" sessions-json 2>/dev/null)
t "T21 old sessions stay (no expiry)" "done" "$(sjq '.[] | select(.session_id=="s-old") | .status')"
t "T22 dead client → gone" "gone"    "$(sjq '.[] | select(.session_id=="s-deadcli") | .status')"
t "T23 dead pool dropped"  ""        "$(sjq '.[] | select(.session_id=="s-deadpool") | .session_id')"
t "T23b dead pool record deleted" "" "$([ -f "$STATE/s-deadpool.json" ] && echo yes)"
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

# ══ tidy (Arc-style auto grouping) ═══════════════════════════════
mkrec "s-tidy-gh"  "{status:\"done\", owner:\"client\", pid:$LIVE1, title:\"t\", cwd:\"/Users/x/Documents/GitHub/myrepo/.claude/worktrees/b\"}"
mkrec "s-tidy-dir" "{status:\"done\", owner:\"client\", pid:$LIVE1, title:\"t\", cwd:\"/tmp/projx\"}"
"$CST" group s-alive "수동그룹" >/dev/null 2>&1
"$CST" tidy >/dev/null 2>&1
SJ=$("$CST" sessions-json 2>/dev/null)
t "T36 tidy repo group"   "myrepo"  "$(sjq '.[] | select(.session_id=="s-tidy-gh") | .group')"
t "T37 tidy dir fallback" "projx"   "$(sjq '.[] | select(.session_id=="s-tidy-dir") | .group')"
t "T38 tidy keeps manual" "수동그룹" "$(sjq '.[] | select(.session_id=="s-alive") | .group')"
"$CST" tidy all >/dev/null 2>&1
SJ=$("$CST" sessions-json 2>/dev/null)
t "T39 tidy all regroups manual" "기타" "$(sjq '.[] | select(.session_id=="s-alive") | .group')"
"$CST" group s-alive - >/dev/null 2>&1
rm -f "$STATE/s-tidy-gh.json" "$STATE/s-tidy-dir.json"

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

# ══ fork lineage: pin/name/order handover ════════════════════════
# both rows visible (parent is newer, from T82) → no handover
echo "[\"$PSID\"]" >"$CST_STATE_DIR/pins.json"
echo "{\"$PSID\":\"my name\"}" >"$CST_STATE_DIR/names.json"
"$CST" sessions-json >/dev/null 2>&1
t "T84 both visible → pin stays" "$PSID" "$(jq -r '.[0]' "$CST_STATE_DIR/pins.json")"

# fork newer again → parent hidden → assets move to the fork
jq ".updated_at = $((NOW + 900))" "$STATE/$FSID.json" >"$STATE/$FSID.json.n" \
  && mv "$STATE/$FSID.json.n" "$STATE/$FSID.json"
echo "[\"x-other\",\"$PSID\"]" >"$CST_STATE_DIR/session-order.json"
SJ=$("$CST" sessions-json 2>/dev/null)
t "T85 pin moves to fork"    "$FSID"    "$(jq -r '.[0]' "$CST_STATE_DIR/pins.json")"
t "T86 pin has no dup"       "1"        "$(jq 'length' "$CST_STATE_DIR/pins.json")"
t "T87 name moves to fork"   "my name"  "$(jq -r ".[\"$FSID\"] // \"\"" "$CST_STATE_DIR/names.json")"
t "T88 parent name dropped"  "0"        "$(jq "has(\"$PSID\") | if . then 1 else 0 end" "$CST_STATE_DIR/names.json")"
t "T89 order slot kept"      "1"        "$(jq "index(\"$FSID\")" "$CST_STATE_DIR/session-order.json")"
t "T8A fork row shows pinned" "0"       "$(sjq ".[] | select(.session_id==\"$FSID\") | .pin_order")"
kill "$PP" "$FP" "$FORKPROC" 2>/dev/null

# ══ gc: assets of vanished sessions ══════════════════════════════
mkrec "s-gc-live" '{status:"done", owner:"client", title:"live"}'
echo "[\"s-gc-live\",\"s-gc-dead\"]" >"$CST_STATE_DIR/pins.json"
echo "[\"s-gc-dead\"]" >"$CST_STATE_DIR/session-order.json"
echo "{\"s-gc-dead\":\"ghost\"}" >"$CST_STATE_DIR/names.json"
echo "{\"s-gc-live\":\"keep\",\"s-gc-dead\":\"drop\"}" >"$CST_STATE_DIR/groups.json"
echo '{"keep":"blue","drop":"red"}' >"$CST_STATE_DIR/colors.json"
echo '["keep","drop"]' >"$CST_STATE_DIR/group-order.json"
"$CST" clean 24 >/dev/null 2>&1
# s-corrupt.json (fixture from T28) used to abort the sweep under set -e
t "T91b clean survives torn record" "yes" "$([ -f "$STATE/s-corrupt.json" ] && echo yes || echo no)"
t "T92 gc keeps live pin"    "[\"s-gc-live\"]" "$(jq -c . "$CST_STATE_DIR/pins.json")"
t "T93 gc empties order"     "[]"              "$(jq -c . "$CST_STATE_DIR/session-order.json")"
t "T94 gc drops dead name"   "{}"              "$(jq -c . "$CST_STATE_DIR/names.json")"
t "T95 gc drops dead group"  "{\"s-gc-live\":\"keep\"}" "$(jq -c . "$CST_STATE_DIR/groups.json")"
t "T96 gc prunes group color" "{\"keep\":\"blue\"}"    "$(jq -c . "$CST_STATE_DIR/colors.json")"
t "T97 gc prunes group order" "[\"keep\"]"            "$(jq -c . "$CST_STATE_DIR/group-order.json")"
# an empty state dir must not wipe assignments (misconfigured CST_STATE_DIR)
EMPTY_STATE="$SANDBOX/empty-state"
mkdir -p "$EMPTY_STATE/sessions"
echo '["s-gc-live"]' >"$EMPTY_STATE/pins.json"
CST_STATE_DIR="$EMPTY_STATE" "$CST" clean 24 >/dev/null 2>&1
t "T98 empty state dir → no wipe" "[\"s-gc-live\"]" "$(jq -c . "$EMPTY_STATE/pins.json")"
rm -f "$CST_STATE_DIR/pins.json" "$CST_STATE_DIR/names.json" \
      "$CST_STATE_DIR/session-order.json" "$CST_STATE_DIR/groups.json" \
      "$CST_STATE_DIR/colors.json" "$CST_STATE_DIR/group-order.json"

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

# ══ exception layers: ended dismissal · continuation lineage ·
# ══ codex stale decay (the newest special-case rules) ════════════
rm -f "$STATE"/*.json "$CST_STATE_DIR/agents-cache.json" "$CST_STATE_DIR/agents-all-cache.json"

# stub daemon now returns an --all list including a completed session
cat >"$SANDBOX/.local/bin/claude" <<EOF
#!/bin/bash
if [ "\${1:-}" = "agents" ]; then
  case "\$*" in
    (*--all*) echo '[{"sessionId":"qa-ended-01","kind":"interactive","cwd":"/tmp","name":"tmp-qa"}]' ;;
    (*)       echo '[]' ;;
  esac
  exit 0
fi
exit 0
EOF
chmod +x "$SANDBOX/.local/bin/claude"

# T92: a completed daemon session with NO record synthesizes as gone
out=$("$CST" sessions-json)
t "T92 completed daemon session appears" "gone" \
  "$(jq -r '.[] | select(.session_id=="qa-ended-01") | .status' <<<"$out")"

# T93: once its record says ended, it must stay dismissed
mkrec "qa-ended-01" '{status:"ended", owner:"client", pid:99999}'
out=$("$CST" sessions-json)
t "T93 ended record suppresses resurrection" "0" \
  "$(jq -r '[.[] | select(.session_id=="qa-ended-01")] | length' <<<"$out")"

# T94: continuation lineage — child transcript cites the parent's path
PDIR="$SANDBOX/.claude/projects/-tmp-qa"
PSID="aaaa1111-2222-3333-4444-555566667777"
CSID="bbbb1111-2222-3333-4444-555566667777"
printf '{"type":"user","sessionId":"%s","message":{"content":"parent work"}}\n' "$PSID" >"$PDIR/$PSID.jsonl"
{
  printf '{"type":"user","sessionId":"%s","message":{"content":"This session is being continued from a previous conversation. read the full transcript at: %s/%s.jsonl"}}\n' "$CSID" "$PDIR" "$PSID"
} >"$PDIR/$CSID.jsonl"
mkrec "$PSID" "{status:\"done\", owner:\"client\", pid:$LIVE1, transcript_path:\"$PDIR/$PSID.jsonl\"}"
mkrec "$CSID" "{status:\"done\", owner:\"client\", pid:$LIVE2, transcript_path:\"$PDIR/$CSID.jsonl\"}"
out=$("$CST" sessions-json)
t "T94 continuation parent resolved" "$PSID" \
  "$(jq -r --arg s "$CSID" '.[] | select(.session_id==$s) | .parent // "none"' <<<"$out")"
t "T95 continuation flag set" "true" \
  "$(jq -r --arg s "$CSID" '.[] | select(.session_id==$s) | .continuation // false' <<<"$out")"

# T96: codex running decays to done when the rollout is stale
CXSID="cccc1111-2222-3333-4444-555566667777"
CXT="$SANDBOX/.codex/sessions/2026/08/27/rollout-2026-08-27T09-00-00-$CXSID.jsonl"
printf '{"type":"session_meta","payload":{"cwd":"/tmp"}}\n' >"$CXT"
touch -t 202608270900 "$CXT"
mkrec "$CXSID" "{status:\"running\", owner:\"client\", pid:$LIVE1, agent:\"codex\", transcript_path:\"$CXT\"}"
out=$("$CST" sessions-json)
t "T96 stale codex running decays" "done" \
  "$(jq -r --arg s "$CXSID" '.[] | select(.session_id==$s) | .status' <<<"$out")"

# T98: a child keeps its inherited group after the parent record is reaped
rm -f "$STATE"/*.json
mkrec "gp-parent" "{status:\"done\", owner:\"client\", pid:$LIVE1, title:\"p\", parent_resolved:true}"
mkrec "gp-child"  "{status:\"done\", owner:\"client\", pid:$LIVE2, title:\"c\", parent:\"gp-parent\", parent_resolved:true}"
"$CST" group gp-parent "상속그룹" >/dev/null 2>&1
"$CST" end gp-parent >/dev/null 2>&1
sleep 0.3
"$CST" sessions-json >/dev/null 2>&1
touch -t 202001010000 "$STATE/gp-parent.json" 2>/dev/null
out=$("$CST" sessions-json 2>/dev/null)
t "T98 inherited group survives parent reap" "상속그룹" \
  "$(jq -r '.[] | select(.session_id=="gp-child") | .group // "null"' <<<"$out")"
t "T99 group promoted to the child's own entry" "상속그룹" \
  "$(jq -r '.["gp-child"] // "null"' "$CST_STATE_DIR/groups.json")"

# T9A-T9C: the memo cache must not serve a stale list
rm -f "$STATE"/*.json
sleep 600 </dev/null >/dev/null 2>&1 & LIVE3=$!
mkrec "sc-one" "{status:\"done\", owner:\"client\", pid:$LIVE3, title:\"c\", parent_resolved:true}"
out=$("$CST" sessions-json 2>/dev/null)
t "T9A cached list is correct first" "done" \
  "$(jq -r '.[] | select(.session_id=="sc-one") | .status' <<<"$out")"
mkrec "sc-two" "{status:\"waiting\", owner:\"client\", pid:$LIVE3, title:\"d\", parent_resolved:true}"
out=$("$CST" sessions-json 2>/dev/null)
t "T9B new record invalidates cache" "waiting" \
  "$(jq -r '.[] | select(.session_id=="sc-two") | .status' <<<"$out")"
"$CST" group sc-one "캐시그룹" >/dev/null 2>&1
out=$("$CST" sessions-json 2>/dev/null)
t "T9C asset write invalidates cache" "캐시그룹" \
  "$(jq -r '.[] | select(.session_id=="sc-one") | .group' <<<"$out")"

# ── teardown ─────────────────────────────────────────────────────
kill "$LIVE1" "$LIVE2" "${LIVE3:-}" 2>/dev/null
echo
echo "PASS: $PASS  FAIL: $FAIL"
for f in "${FAILED[@]:-}"; do [ -n "$f" ] && echo "  ✗ $f"; done
rm -rf "$SANDBOX"
[ "$FAIL" -eq 0 ]
