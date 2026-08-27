# claude-session-tracker

macOS용 Claude Code / Codex 세션 트래커. Raycast 스타일 플로팅 패널로 모든 터미널의
AI 코딩 세션을 한눈에 보고, 키 하나로 해당 터미널 탭으로 점프한다.

터미널 레이어(cmux 등)가 아니라 **에이전트 훅 레이어**에서 추적하므로 어떤 터미널을
쓰든 동작한다. iTerm2, Terminal.app, VS Code, cmux, tmux 지원.

## 기능

- **⌥Space 플로팅 패널** — 상태별 섹션(NEEDS INPUT / REPLY WAITING / FINISHED / RUNNING / IDLE)으로 세션 정리
- **원클릭 점프** — 세션이 열린 터미널 탭/윈도우로 포커스 이동 (죽은 세션은 resume 탭 자동 오픈)
- **상태 추적** — 실행 중 / 승인 대기 / 입력 대기 / 완료 / 유휴, 픽셀 마스코트 애니메이션으로 표시
- **알림** — 승인 필요·작업 완료 시 macOS 알림, 클릭하면 해당 세션으로 점프
- **그룹 + 핀** — 드래그로 그룹핑·정렬, 그룹 칩 필터, 그룹별 핀 고정
- **키보드 우선** — 방향키 탐색, ⌘1–9 점프, ⌃X 중지/종료, ⌃R 이름 변경, ⌘R 새로고침
- **커맨드 팔레트** — 키워드 커스텀 명령(`{query}`/`{prompt}` 치환), `/` 스킬 팔레트, 폴더 자동완성
- **아카이브 검색** — 종료된 세션 검색 후 resume
- **Codex 지원** — OpenAI Codex CLI(0.147+) 세션도 동일하게 추적 (파란 원형 `>_` 아이콘)
- **메뉴바** — 승인 대기 카운트 + 마스코트 (running이면 바운스, 우클릭으로 Claude/Codex 선택)

## 요구 사항

- macOS (Apple Silicon/Intel), Xcode Command Line Tools (`xcode-select --install`)
- `jq` (`brew install jq`)
- [Claude Code](https://claude.com/claude-code) — Codex는 선택
- 점프 기능은 iTerm2에서 가장 완전함 (Terminal.app / VS Code / cmux / tmux도 지원)

## 설치

```sh
git clone https://github.com/cms5380/claude-session-tracker.git
cd claude-session-tracker
./install.sh          # Codex도 쓰면: ./install.sh --codex
```

설치 내용:

1. `~/.claude/session-tracker/`에 CLI(`cst`)와 훅 스크립트 복사
2. `~/.claude/settings.json`에 훅 5개 등록 (기존 설정은 `.bak-cst`로 백업)
3. 메뉴바 앱을 소스에서 빌드 (`ClaudeSessions.app`)
4. 로그인 시 자동 시작 LaunchAgent 등록
5. `--codex`: `~/.codex/hooks.json` 생성 — 이후 codex를 한 번 실행해 훅 신뢰 프롬프트를 승인해야 함

첫 실행 시 알림 권한과 iTerm2 자동화(Automation) 권한을 승인하면 된다.

## 단축키

| 키 | 동작 |
|---|---|
| ⌥Space | 패널 열기/닫기 |
| ↑↓ / Enter | 세션 선택 / 점프 |
| ⌘1–9 | n번째 세션으로 점프 |
| ⌃X | 세션 중지 (두 번 누르면 종료 + 탭 닫기) |
| ⌃R / ⌃P / ⌃C | 이름 변경 / 핀 / resume 명령 복사 |
| ⌘R | 새로고침 |
| `>` / `/` | 커맨드 팔레트 / 스킬 팔레트 |

## 커스텀 커맨드

Raycast처럼 패널에서 이름을 타이핑하면 실행되는 사용자 명령. 두 가지 방법으로 만든다:

- **패널에서**: `new` 타이핑 → "New Command" → 이름/명령 입력. 기존 커맨드는 ⌘↩로 편집.
- **파일로**: `~/.local/state/claude-session-tracker/commands.json` 편집 (Claude에게 시켜도 됨 — 저장 즉시 반영):

```json
{
  "g": "@open 'https://www.google.com/search?q={query}'",
  "c": "cd ~/Documents/GitHub/{query} && claude {prompt}",
  "github 열기": "@open ~/Documents/GitHub"
}
```

| 문법 | 의미 |
|---|---|
| `{query}` | 이름 뒤 첫 인자로 치환 (`g 검색어`) |
| `{prompt}` | 인자 뒤 나머지 문장 (`c 폴더명 프롬프트…`) |
| `@` 접두사 | 새 탭 없이 백그라운드 실행 |
| (접두사 없음) | 새 터미널 탭에서 실행 |
| `cd <경로>/{query}` | 해당 경로 아래 폴더명 자동완성 + Tab 지원 |

## 구조

```
hooks/track.sh   # Claude/Codex 훅 — 세션 상태 + 터미널 식별자 기록
bin/cst          # CLI — jump/stop/end/그룹/핀/아카이브 등 전부
menubar/         # SwiftUI 메뉴바 앱 (단일 파일, swiftc로 빌드)
install.sh       # 설치 스크립트
```

상태 저장: `~/.local/state/claude-session-tracker/`

## 제거

```sh
pkill -f MacOS/ClaudeSessions
rm -rf ~/.claude/session-tracker ~/Library/LaunchAgents/com.dean.claude-sessions.plist
# ~/.claude/settings.json 의 hooks에서 track.sh 항목 제거 (백업: settings.json.bak-cst)
```
