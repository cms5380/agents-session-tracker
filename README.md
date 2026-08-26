# claude-session-tracker

터미널 무관하게 Claude Code 세션을 추적하고, 클릭 한 번으로 해당 터미널 세션으로 점프하는 도구.

cmux처럼 터미널 레이어가 아니라 **Claude Code hook 레이어**에서 추적하므로 어떤 터미널을 쓰든 동작한다.
점프(포커스)는 터미널별 드라이버로 처리: **cmux → iTerm2 → tmux → Terminal.app** 순으로 시도.

## 구성

```
hooks/track.sh                 # Claude Code 훅 — 세션 상태 + 터미널 식별자 기록
bin/cst                        # CLI — list / jump / clean
swiftbar/claude-sessions.5s.sh # SwiftBar menubar 플러그인 (선택)
```

상태 저장: `~/.local/state/claude-session-tracker/sessions/<session_id>.json`

## 설치

### 1. 훅 등록

`~/.claude/settings.json`의 `hooks`에 추가:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "$HOME/Documents/GitHub/claude-session-tracker/hooks/track.sh" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "$HOME/Documents/GitHub/claude-session-tracker/hooks/track.sh" }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "$HOME/Documents/GitHub/claude-session-tracker/hooks/track.sh" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "$HOME/Documents/GitHub/claude-session-tracker/hooks/track.sh" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "$HOME/Documents/GitHub/claude-session-tracker/hooks/track.sh" }] }
    ]
  }
}
```

### 2. CLI

```bash
ln -s "$PWD/bin/cst" /usr/local/bin/cst
```

### 3. SwiftBar (menubar UI, 선택)

```bash
brew install --cask swiftbar
ln -s "$PWD/swiftbar/claude-sessions.5s.sh" "<SwiftBar plugin folder>/"
```

menubar 표시: `🟡 N` = 입력 대기 중인 세션 N개(최우선), `🟢 N` = 실행 중 N개.
항목 클릭 → 해당 터미널 세션으로 점프.

## 사용

```bash
cst list          # 세션 목록 (🟢 running / 🟡 waiting / ⚪ done)
cst jump <id>     # 세션으로 점프 (id 프리픽스 매칭 지원)
cst clean [hours] # ended + N시간(기본 24) 이상 방치된 세션 정리
```

## 점프 드라이버

| 우선순위 | 대상 | 식별자 | 방법 |
|---|---|---|---|
| 1 | cmux | `CMUX_WORKSPACE_ID` | `cmux workspace-action --action focus` (실패 시 `cmux rpc workspace.focus`) |
| 2 | iTerm2 | `ITERM_SESSION_ID` | AppleScript로 세션 UUID 매칭 → select |
| 3 | tmux | `TMUX_PANE` | `tmux switch-client -t <pane>` + 터미널 앱 activate |
| 4 | Terminal.app | claude 프로세스 tty | AppleScript로 tty 매칭해 탭 선택 |
| 폴백 | — | cwd | 알림으로 cwd 표시, `claude --resume` 안내 |

식별자는 훅 실행 시점의 환경변수에서 수집한다 (훅은 claude 프로세스의 자식이라 터미널이 심은 env를 상속).

## 알려진 한계

- cmux `focus` 명령 시그니처는 cmux-tips 문서 기반 추정 — cmux 설치 환경에서 `cmux workspace-action --help`로 확인 후 필요 시 `bin/cst`의 `jump_cmux` 수정.
- cmux는 surface(탭) 단위 포커스 미구현 — workspace까지만 점프.
- Terminal.app tty 매칭은 재부팅 후 stale 가능 → 폴백 알림으로 처리.
- 헤드리스/백그라운드 세션(`claude -p`, bg job)은 점프 대상 터미널이 없으므로 폴백 경로로 감.
