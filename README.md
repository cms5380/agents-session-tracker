# claude-session-tracker

macOS용 Claude Code / Codex 세션 트래커. Raycast 스타일 플로팅 패널(⌥Space)로 모든
터미널의 AI 코딩 세션을 한눈에 보고, 키 하나로 해당 터미널 탭으로 점프한다.

터미널 레이어(cmux 등)가 아니라 **에이전트 훅 레이어**에서 추적하므로 어떤 터미널을
쓰든 동작한다. iTerm2, Terminal.app, VS Code, cmux, tmux 지원.

## 기능

### 세션 관리
- **하이브리드 리스트** — 승인·답변·완료 대기만 ATTENTION으로 끌어올리고, 나머지는
  위치가 고정된 SESSIONS 리스트에 유지 (실행 중/유휴는 마스코트 애니메이션으로 구분)
- **원클릭 점프** — 세션이 열린 터미널 탭/윈도우로 포커스 이동. 죽은 세션은
  `claude --resume` / `codex resume` 탭을 자동으로 연다
- **포크·연속 세션 계보** — `/fork`·백그라운드 전환으로 갈라진 세션은 부모 밑에
  들여쓰기로 표시(`⑂ 부모이름` 칩), 상태와 조작은 각각 독립
- **⌃X 라이프사이클** — 한 번: 턴 중지(Esc 주입, resume 가능 💤) → 두 번: 완전 종료
  (프로세스 + 터미널 탭 + 데몬 잡 레지스트리까지 정리, 트랜스크립트는 보존)
- **그룹 + 핀** — 드래그로 그룹핑·정렬, 그룹 칩 필터(칩별 핀 스코프), 인라인 이름 변경
- **알림** — 승인 필요·작업 완료 시 macOS 알림, 클릭하면 해당 세션으로 점프

### 검색·명령
- **전문 검색** — 제목·경로뿐 아니라 Claude/Codex **대화 내용 전체**를 검색.
  라이브 세션은 "내용 일치", 종료된 세션은 ARCHIVE 섹션으로 표시 후 바로 resume
- **커스텀 커맨드** — Raycast식 키워드 명령. 패널 안에서 생성/편집(⌘↩), 폴더 자동완성
- **`/` 스킬 팔레트** — 유저·플러그인·내장 스킬을 선택해 세션에 주입.
  ↩ = 헤드리스 턴, **⌘↩ = 해당 세션 터미널에 직접 타이핑** (TUI 명령 `/resume` 등도 동작)
- **New Session** — 최근 폴더별로 ↩(메인 에이전트) / ⌘↩(다른 에이전트) 새 세션

### 사용량·통계
- **쿼터 게이지 (CodexBar식)** — Claude는 공식 OAuth usage API의 5시간/주간 사용률,
  Codex는 rollout에 기록되는 공식 주간 사용률. 리셋 카운트다운 + 색상 게이지,
  푸터에 상시 요약
- **stats 카드** — `stats` 타이핑: 총 세션 수, 오늘/7일 활성, 14일 활동 차트,
  모델별 최근 5시간 토큰
- **모델 뱃지** — 각 세션 행에 사용 모델 표시 (`opus 5`, `gpt-5.6` …)

### 꾸미기
- **픽셀 캐릭터 아이콘** — 메뉴바·검색창 아이콘을 우클릭 카드 픽커에서 선택
  (터미널/Claude/Codex/고양이/고스트/로봇/슬라임). 메뉴바는 세션 상태 따라
  바운스·`!!` 애니메이션
- **커스텀 이미지** — `~/.local/state/claude-session-tracker/icon.png`(바운스) 또는
  `icon.gif`(프레임 애니메이션)를 넣으면 "이미지" 카드가 생긴다

## 요구 사항

- macOS (Apple Silicon/Intel), Xcode Command Line Tools (`xcode-select --install`)
- `jq` (`brew install jq`)
- [Claude Code](https://claude.com/claude-code) — Codex는 선택 (0.147+)
- 점프·탭 제어는 iTerm2에서 가장 완전함 (Terminal.app / VS Code / cmux / tmux도 지원)

## 설치

```sh
git clone https://github.com/cms5380/claude-session-tracker.git
cd claude-session-tracker
./install.sh          # Codex도 쓰면: ./install.sh --codex
```

설치 내용:

1. `~/.claude/session-tracker/`에 CLI(`cst`)와 훅 스크립트 복사
2. `~/.claude/settings.json`에 훅 6개 등록 (기존 설정은 `.bak-cst`로 백업)
3. 메뉴바 앱을 소스에서 빌드 (`ClaudeSessions.app`) + 로그인 자동 시작 등록
4. 시작용 커스텀 커맨드 시드 (`commands.json` 없을 때만)
5. `--codex`: `~/.codex/hooks.json` 생성 — 이후 codex를 한 번 실행해 훅 신뢰
   프롬프트를 승인해야 추적이 시작된다

첫 실행 시 알림 권한과 iTerm2 자동화(Automation) 권한을 승인하면 된다.

## 단축키

| 키 | 동작 |
|---|---|
| ⌥Space | 패널 열기/닫기 (닫으면 원래 앱으로 포커스 복귀) |
| ↑↓ / ↩ | 세션 선택 / 점프 |
| ⌘1–9 | n번째 세션으로 점프 |
| Tab | 선택 세션 퀵 프롬프트 · 팔레트에선 명령 자동완성 |
| ⌘↩ | 상황별 대체 동작 — 새 세션: 다른 에이전트 · 퀵 프롬프트: 터미널에 직접 입력 · 커맨드: 편집 |
| ⌃X | 세션 중지 → 한 번 더: 완전 종료 |
| ⌃R / ⌃P / ⌃C / ⌃⌫ | 이름 변경 / 핀 / resume 명령 복사 / 그룹 해제 |
| ⌘R | 새로고침 |
| `/` | 스킬 팔레트 |

## 커스텀 커맨드

패널에서 이름을 타이핑하면 실행되는 사용자 명령. 두 가지 방법으로 만든다:

- **패널에서**: `new` 타이핑 → "New Command" → 이름/명령 입력. 기존 커맨드는 ⌘↩로 편집
- **파일로**: `~/.local/state/claude-session-tracker/commands.json` 편집
  (Claude에게 시켜도 됨 — 저장 즉시 반영):

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
bin/cst          # CLI — jump/send/stop/end/검색/그룹/핀/사용량 등 전부
menubar/         # SwiftUI 메뉴바 앱 (단일 파일, swiftc로 빌드)
install.sh       # 설치 스크립트
```

상태 저장: `~/.local/state/claude-session-tracker/`

참고: Claude 쿼터 게이지는 키체인의 Claude Code OAuth 토큰을 `cst` 프로세스 안에서만
읽어 Anthropic usage 엔드포인트에만 보낸다 — 어디에도 기록되지 않는다.

## 제거

```sh
pkill -f MacOS/ClaudeSessions
rm -rf ~/.claude/session-tracker ~/Library/LaunchAgents/com.dean.claude-sessions.plist
# ~/.claude/settings.json 의 hooks에서 track.sh 항목 제거 (백업: settings.json.bak-cst)
# Codex를 연결했다면 ~/.codex/hooks.json 도 제거
```
