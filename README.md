# codex-collab v2

**Claude Code에서 OpenAI Codex CLI(GPT-5.4)를 호출하여 세션 기반 크로스 모델 협업을 구현하는 플러그인**

A Claude Code plugin for session-based cross-model collaboration with OpenAI Codex CLI (GPT-5.4) — task delegation, evaluation, and automated debate.

---

## What's New in v2 / v2 변경사항

v2는 v1의 클린 브레이크입니다. 주요 변경:

- **세션 필수**: 모든 커맨드가 세션 안에서만 동작 (이력 추적)
- **커맨드 재설계**: 행위 기반 4개 커맨드 (`ask`, `evaluate`, `debate`, `session`)
- **에이전트 계층화**: `workflow-orchestrator` 중심 계층 구조
- **구조화 응답**: `--output-schema`로 JSON 구조화 결과
- **자동 토론**: Claude↔Codex 간 최대 5라운드 자동 토론

---

## Upgrading from v1 / v1에서 업그레이드

v2는 v1의 **클린 브레이크(breaking change)** 입니다. 기존 커맨드가 변경되었습니다.

v2 is a **breaking change** from v1. All commands have been redesigned.

```bash
# 플러그인 업데이트
claude plugin update codex-collab
```

### Command Migration / 커맨드 변경 대응표

| v1 (제거됨) | v2 (대체) | 비고 |
|------------|-----------|------|
| `/codex <prompt>` | `/codex-ask <prompt>` | 세션 필수. 먼저 `/codex-session start` 실행 |
| `/codex-opinion <question>` | `/codex-ask <question>` | ask로 통합, read-only 자동 판단 |
| `/codex-review` | `/codex-evaluate` | 교차 검증 필수 포함, 구조화 결과 |
| `/codex-verify` | `/codex-evaluate` | review와 통합 |
| *(없음)* | `/codex-session` | **신규** — 세션 관리 (필수) |
| *(없음)* | `/codex-debate` | **신규** — 자동 토론 |

### Key Difference / 핵심 차이

v1에서는 바로 `/codex`를 실행할 수 있었지만, v2에서는 **반드시 세션을 먼저 시작**해야 합니다:

```bash
# v1 (바로 실행)
/codex 이 코드를 분석해줘

# v2 (세션 먼저)
/codex-session start 분석 작업
/codex-ask 이 코드를 분석해줘
/codex-session end
```

---

## Prerequisites / 사전 요구사항

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI 설치 및 인증
- [OpenAI Codex CLI](https://github.com/openai/codex) 설치 및 인증 (`codex login`)

Codex CLI must be in your `PATH`. Authentication is handled via OAuth (ChatGPT mode) — no API key needed.

## Installation / 설치

```bash
claude plugin add codex-collab
```

또는 로컬 설치 (Or install locally):

```bash
cd /path/to/codex-collab
claude plugin add ./
```

---

## Quick Start / 빠른 시작

```bash
# 1. 세션 시작
/codex-session start 리팩토링 작업

# 2. Codex에게 질문
/codex-ask 이 함수의 시간 복잡도를 분석해줘

# 3. 코드 평가
/codex-evaluate src/auth.ts

# 4. 자동 토론
/codex-debate 이 모듈을 클래스로 리팩토링해야 할까?

# 5. 세션 종료
/codex-session end
```

---

## Commands / 명령어

### `/codex-session <start|end|delete|list>`

세션 생명주기를 관리합니다. Manages session lifecycle.

| Subcommand | Description |
|------------|-------------|
| `start <name>` | 새 세션 시작. Start a new session. |
| `end` | 활성 세션 종료. End active session. |
| `delete <id>` | 세션 영구 삭제. Permanently delete a session. |
| `list` | 현재 프로젝트 세션 목록. List sessions for current project. |

### `/codex-ask <prompt>`

Codex에게 질문하거나 작업을 위임합니다. Ask Codex a question or delegate a task.

- read/write 모드 자동 판단 (Auto-detects read-only vs write mode)
- write 모드 시 사용자 확인 필수 (Write mode requires user confirmation)

### `/codex-evaluate <target>`

Codex가 코드를 평가하고 Claude가 교차 검증합니다. Codex evaluates code, Claude cross-verifies.

- `--output-schema`로 구조화된 결과 (Structured results via --output-schema)
- 세션 내 이전 평가와 추이 비교 (Trend comparison within session)

### `/codex-debate <topic>`

Claude↔Codex 자동 토론. Automated debate between Claude and Codex.

- 최대 5라운드, 조기 합의 시 종료 (Max 5 rounds, early consensus exit)
- 구조화 JSON으로 입장 교환 (Structured JSON position exchange)
- 앵커링 방지 프로토콜 적용 (Anti-anchoring protocol)

---

## Architecture / 아키텍처

### Agents / 에이전트

| Agent | Role |
|-------|------|
| `workflow-orchestrator` | 모든 커맨드의 상위 오케스트레이터. Top-level orchestrator. |
| `session-manager` | 세션 CRUD, 프로젝트별 필터링. Session lifecycle management. |
| `codex-delegator` | 순수 CLI 호출 + 응답 파싱. Pure CLI invocation + response parsing. |
| `cross-verifier` | 교차 검증 (evaluate 필수 단계). Cross-verification. |
| `rule-engine` | 조건-액션 규칙 평가, 자동 후속 커맨드. Condition-action rules. |

### Skills / 스킬

| Skill | Role |
|-------|------|
| `codex-invocation` | CLI 호출 패턴, 플래그, 에러 처리. CLI patterns and error handling. |
| `session-management` | 세션 저장소, 스키마, CRUD 로직. Session storage and CRUD logic. |
| `schema-builder` | output-schema 동적 생성. JSON Schema construction. |

### Schemas / 스키마

| Schema | Location |
|--------|----------|
| Evaluation | [`schemas/evaluation.json`](schemas/evaluation.json) — 코드 평가 결과 구조 |
| Debate | [`schemas/debate.json`](schemas/debate.json) — 토론 라운드 입장 구조 |

### Validation / 검증

```bash
bash scripts/validate-plugin.sh
```

플러그인 구조 무결성을 검증합니다 (plugin.json, 파일 참조, 스키마, hooks).
Validates plugin structural integrity (37 checks).

---

## Rules Configuration / 규칙 설정

`rule-engine` agent는 커맨드 실행 결과에 따라 자동으로 후속 액션을 트리거합니다.
The `rule-engine` agent triggers automatic follow-up actions based on command results.

### Rule Files / 규칙 파일 위치

| 위치 | 경로 | 우선순위 |
|------|------|----------|
| 글로벌 (전체 프로젝트 적용) | `~/.claude/codex-rules.yaml` | 낮음 |
| 프로젝트 (현재 프로젝트만 적용) | `.codex-collab/rules.yaml` | 높음 |

같은 `name`의 규칙은 프로젝트 규칙이 글로벌 규칙을 완전히 덮어씁니다.
Project rules with the same `name` entirely replace global rules.

로딩 우선순위 (Loading priority):
```
기본 내장 규칙 ← 글로벌 규칙 ← 프로젝트 규칙
Built-in defaults ← Global ← Project
```

### Quickstart / 빠른 설정

```bash
# 예제 파일을 프로젝트 규칙으로 복사
mkdir -p .codex-collab
cp docs/rules.yaml.example .codex-collab/rules.yaml

# 또는 글로벌 규칙으로 복사
cp docs/rules.yaml.example ~/.claude/codex-rules.yaml
```

전체 규칙 스키마와 예제는 [`docs/rules.yaml.example`](docs/rules.yaml.example)을 참조하세요.
For the full rule schema and examples, see [`docs/rules.yaml.example`](docs/rules.yaml.example).

### Rule Example / 규칙 예시

```yaml
rules:
  # 신뢰도가 낮으면 자동 재평가 / Re-evaluate when confidence is low
  - name: "low-confidence-reeval"
    when:
      command: "codex-evaluate"
      field: "confidence"
      operator: "<"
      value: 0.5
    then:
      action: "run"
      command: "codex-evaluate"
      message: "신뢰도가 낮아 재평가합니다 (confidence: {confidence})"

  # Critical 이슈 발견 시 토론 시작 / Start debate on critical issues
  - name: "critical-issue-debate"
    when:
      command: "codex-evaluate"
      field: "issues[].severity"
      operator: "contains"
      value: "critical"
    then:
      action: "run"
      command: "codex-debate"
      args: "Critical issue: {issues[0].description}"
      message: "심각한 이슈가 발견되어 토론을 시작합니다"
```

---

## Safety / 안전장치

4개의 PreToolUse 안전 훅이 Codex CLI 호출을 감시합니다:

Four PreToolUse safety hooks guard Codex CLI invocations:

| Hook | Action |
|------|--------|
| `--full-auto` 감지 | 경고 메시지 표시 (Warning) |
| `--dangerously-*` 감지 | **차단 — exit 2** (Blocked) |
| write 모드 감지 | 파일 변경 인지 경고 (Write-mode awareness) |
| 세션 없이 Codex 호출 | 프로젝트별 세션 확인 후 경고 (Session warning, project-scoped) |

추가 안전장치 (Additional safeguards):
- write 모드 자동 판단 시 사용자 확인 필수 (Write mode requires confirmation)
- 세션 데이터는 `~/.claude/codex-sessions/`에 저장 (프로젝트 트리 외부)
- 규칙 엔진 자동 액션 체인 최대 깊이: **3** (Rule engine auto-action chain max depth: 3)

---

## Roadmap

- [x] Phase 1: 세션 시스템 + `/codex-ask`
- [x] Phase 2: `/codex-evaluate` + 구조화 응답 (`--output-schema`)
- [x] Phase 3: 규칙 엔진 + 자동 액션
- [x] Phase 4: `/codex-debate` + 자동 토론

---

## License / 라이선스

[MIT](LICENSE)
