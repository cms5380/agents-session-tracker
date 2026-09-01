# agents-session-tracker

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
- **포크 계보** — `/fork`로 갈라진 세션은 부모 밑에 들여쓰기로 표시(`⑂ 부모이름` 칩),
  상태와 조작은 각각 독립
- **한 대화 = 한 줄** — `claude agents`로 백그라운드에 넘기면 같은 대화가 새 ID로
  복사되는데, 복사된 히스토리를 인식해 **마지막으로 사용한 쪽만** 목록에 남긴다
- **정렬 축 전환 (⌘S)** — 기본 / 최근순 / 상태별 / 폴더별 / 이름순. 축마다 구분
  라벨이 붙고(오늘·어제·지난 7일, 실행 중·유휴·종료됨, 폴더명) 선택은 유지된다
- **⌃X 라이프사이클** — 한 번: 턴 중지(Esc 주입, resume 가능 💤) → 두 번: 완전 종료
  (프로세스 + 터미널 탭 + 데몬 잡 레지스트리까지 정리, 트랜스크립트는 보존)
- **그룹 + 핀** — 드래그로 그룹핑·정렬, 그룹 칩 필터(칩별 핀 스코프), 인라인 이름 변경
  (⌃R). ⌃⌘R은 트랜스크립트를 읽어 **AI가 짧은 이름을 지어준다** — 살아 있는 claude
  세션이면 `/rename`까지 동기화돼 `claude --resume <이름>`으로도 열린다
- **알림** — 승인 필요·답변 대기·작업 완료 시 macOS 알림(소리 포함, 설정에서 개별 토글).
  클릭하면 해당 세션으로 점프하고, 세션을 확인하면 남은 배너는 자동으로 사라진다.
  해당 세션의 터미널 탭을 이미 보고 있으면 유휴 핑은 울리지 않는다
- **세션은 스스로 사라지지 않는다** — 자동 만료 없음. 터미널을 닫거나 재부팅해도
  목록 아래쪽에 흐리게 남아 언제든 resume 되고, ⌃X 두 번으로 지울 때까지 유지된다
  (헤드리스 일회성 실행 `claude -p`·`codex exec`은 애초에 목록에 잡히지 않는다)

### 검색·명령
- **전문 검색** — 제목·경로뿐 아니라 Claude/Codex **대화 내용 전체**를 검색.
  라이브 세션은 "내용 일치", 종료된 세션은 ARCHIVE 섹션으로 표시 후 바로 resume
- **커스텀 커맨드** — Raycast식 키워드 명령. 패널 안에서 생성/편집(⌘↩), 폴더 자동완성
- **`/` 스킬 팔레트** — 유저·플러그인·내장 스킬을 골라 **새 세션에서 실행**.
  `/review 이 PR 봐줘`처럼 뒤에 쓴 프롬프트도 함께 전달된다. 폴더는 선택한 세션의
  작업 폴더를 따라가고, ⌘↩는 다른 에이전트로 시작
- **New Session** — 최근 폴더별로 ↩(메인 에이전트) / ⌘↩(다른 에이전트) 새 세션
- **Tidy (Arc식 자동 그룹)** — `tidy`: 미분류 세션을 저장소/폴더별로 그룹,
  `tidy ai`: claude가 주제별로 묶고 한국어 그룹명 생성. 기본은 미분류만
  (수동 그룹 보호), ⌘↩ 또는 `ast tidy ai all`은 전체 재그룹

### 설정
- **설정 창** (메뉴바 아이콘 우클릭 → 설정…) — 시스템 설정 스타일 탭 4개
- **단축키** — ⌥Space·어텐션 점프 같은 전역 키와, 패널 안 동작(⌃X 중지/종료, ⌃R 이름,
  ⌃P 핀, ⌃C resume 복사, ⌃⌫ 그룹 해제, ⌃⌘R AI 이름, ⌘R 새로고침, ⌘S 정렬)을 모두
  원하는 조합으로 재지정. 구조적인 키(↩·↑↓·Tab·⌘1–9·Esc)만 고정
- **일반** — 새 세션 기본 에이전트(claude/codex), 새 탭을 열 기본 터미널
  (자동 / iTerm2 / Terminal / Ghostty)
- **알림** — 상태별 알림과 소리 on/off

### 꾸미기
- **마스코트 아이콘** — 메뉴바·검색창 아이콘을 우클릭 카드 픽커에서 선택
  (Claude/Codex). 메뉴바는 세션 상태 따라 바운스·`!!` 애니메이션
- **아이콘은 CLI로도** — AI 에이전트에게 시키기 좋게 한 줄이면 됨 (앱이 자동 감지):

  ```sh
  ast icon codex          # 마스코트 (claude | codex)
  ast icon 🦖             # 아무 이모지
  ast icon ~/pikachu.gif  # 이미지 — gif는 프레임 애니메이션, png는 바운스
  ```

## 요구 사항

- macOS (Apple Silicon/Intel), Xcode Command Line Tools (`xcode-select --install`)
- `jq` (`brew install jq`)
- [Claude Code](https://claude.com/claude-code) — Codex는 선택 (0.147+)
- 점프·탭 제어는 iTerm2에서 가장 완전함 (Terminal.app / VS Code / cmux / tmux도 지원)

## 설치

### Homebrew

```sh
brew install cms5380/tap/agents-session-tracker
agents-session-tracker-setup          # Codex도 쓰면: agents-session-tracker-setup --codex
```

### 소스에서

```sh
git clone https://github.com/cms5380/agents-session-tracker.git
cd agents-session-tracker
./install.sh          # Codex도 쓰면: ./install.sh --codex
```

설치 내용:

1. `~/.claude/session-tracker/`에 CLI(`ast`, 구버전 호환 `cst` 심링크)와 훅 스크립트 복사
2. `~/.claude/settings.json`에 훅 7종 등록 (기존 설정은 `.bak-cst`로 백업)
3. 메뉴바 앱을 소스에서 빌드 (`AgentsSessionTracker.app`) + 로그인 자동 시작 등록
4. 시작용 커스텀 커맨드 시드 (`commands.json` 없을 때만)
5. `--codex`: `~/.codex/hooks.json` 생성 — 이후 codex를 한 번 실행해 훅 신뢰
   프롬프트를 승인해야 추적이 시작된다

첫 실행 시 알림 권한과 iTerm2 자동화(Automation) 권한을 승인하면 된다.

### AI 에이전트에게 설치 시키기

Claude Code 등 AI 에이전트에 이 저장소 URL을 주고 "설치해줘"라고 하면 된다.
에이전트를 위한 정확한 절차:

```sh
# 1. 설치 (brew 또는 소스 — 위 참조)
brew install cms5380/tap/agents-session-tracker
agents-session-tracker-setup            # Codex 사용자는 --codex 추가

# 2. 검증
~/.claude/session-tracker/ast sessions-json | jq 'type'   # "array" 나오면 정상
pgrep -f MacOS/AgentsSessionTracker                        # 앱 프로세스 존재 확인 (/Applications 설치)
jq '.hooks | keys' ~/.claude/settings.json                 # 훅 7종 등록 확인
```

**사람(사용자)의 GUI 승인이 필요한 단계** — 에이전트는 아래를 사용자에게 안내할 것:
1. 첫 알림 시 macOS **알림 권한** 허용
2. 첫 점프 시 **iTerm2 자동화(Automation)** 권한 허용
3. `--codex` 사용 시: `codex`를 한 번 실행해 **훅 신뢰(trust) 프롬프트** 승인

문제 해결: 패널이 안 뜨면 `open "/Applications/Agents Session Tracker.app"`,
세션이 안 보이면 새 claude 세션을 하나 시작해 훅이 레코드를 쓰는지
`ls ~/.local/state/claude-session-tracker/sessions/`로 확인.

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
| ⌃⌘R | AI로 이름 짓기 (트랜스크립트를 읽어 짧은 제목 생성, 터미널 불필요) |
| ⌘R / ⌘S | 새로고침 / 정렬 전환 (기본→최근순→상태별→폴더별→이름순, 선택은 유지됨) |
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
bin/ast          # CLI — jump/send/stop/end/검색/그룹/핀/tidy/이름짓기 등 전부
menubar/         # SwiftUI 메뉴바 앱 (단일 파일, swiftc로 빌드)
install.sh       # 설치 스크립트
```

상태 저장: `~/.local/state/claude-session-tracker/`

## 제거

```sh
pkill -f MacOS/AgentsSessionTracker
rm -rf ~/.claude/session-tracker "/Applications/Agents Session Tracker.app" \
       ~/Library/LaunchAgents/com.dean.claude-sessions.plist \
       ~/.local/state/claude-session-tracker      # 그룹·핀·이름 등 상태 (트랜스크립트는 무관)
# ~/.claude/settings.json 의 hooks에서 track.sh 항목 제거 (백업: settings.json.bak-cst)
# Codex를 연결했다면 ~/.codex/hooks.json 도 제거
```
