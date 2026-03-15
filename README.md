# codex-collab

**Claude Code에서 OpenAI Codex CLI(GPT-5.4)를 호출하여 세션 기반 크로스 모델 협업을 구현하는 플러그인**

A Claude Code plugin for session-based cross-model collaboration with OpenAI Codex CLI (GPT-5.4) — task delegation, evaluation, and automated debate.

---

## Why codex-collab? / 왜 이 플러그인인가?

AI 코딩 어시스턴트를 하나만 쓰면 **단일 모델의 편향과 사각지대**에 갇힙니다. codex-collab은 Claude와 Codex(GPT-5.4), 두 AI 모델이 서로의 작업을 검증하고 토론하게 하여 이 문제를 해결합니다.

Using a single AI coding assistant means being trapped in **one model's biases and blind spots**. codex-collab solves this by having Claude and Codex (GPT-5.4) verify each other's work and debate solutions.

### 해결하는 문제 (Problems Solved)

| 문제 | codex-collab의 해결 방식 |
|------|------------------------|
| **단일 모델 편향** — AI가 자신의 코드를 자신이 리뷰하면 같은 실수를 놓침 | `/codex-evaluate`: Codex가 코드를 평가하면 Claude가 독립 교차 검증 |
| **설계 결정의 확신 부족** — "이 접근이 정말 최선인가?" | `/codex-debate`: 두 모델이 자동 토론 후 합의 또는 양측 입장을 제시 |
| **앵커링 바이어스** — "Claude가 좋다고 했으니 Codex도 동의하겠지" | 앵커링 방지 프로토콜: Codex에게 Claude의 결론을 노출하지 않음 |
| **검증 이력 부재** — 검증 결과가 휘발되어 추적 불가 | 세션 기반 이력 추적 + 리포트 자동 저장 |

### 활용 시나리오 (Use Cases)

- **코드 리뷰 강화**: PR 전에 `/codex-evaluate`로 두 모델의 교차 검증을 받아 리뷰 품질 향상
- **아키텍처 결정**: `/codex-debate`로 "REST vs GraphQL" 같은 설계 결정에 두 모델의 독립적 의견 확보
- **보안 검증**: 보안이 중요한 코드에 대해 크로스 모델 검증으로 취약점 발견 확률 증가
- **학습/탐색**: `/codex-ask`로 같은 질문에 대한 두 모델의 다른 관점을 비교
- **자동 품질 게이트**: 규칙 엔진으로 "confidence < 0.5이면 자동 재평가" 같은 자동화된 품질 관리

---

## What's New in v2.1 / v2.1 변경사항

- **세션 자동 생성**: `/debate`, `/evaluate`, `/ask` 실행 시 세션이 없으면 자동 생성 (v2.0에서는 수동 필수)
- **프로젝트 설정 파일**: `.codex-collab/config.yaml`로 프로젝트별 기본값 설정 가능
- **Safety 자동 트리거**: safety hook이 위험을 감지하면 cross-model debate를 자동 제안
- **Debate 결과 처리**: 합의 시 코드 자동 적용, 비합의 시 4개 선택지, 리포트 자동 저장
- **자동 상태 요약**: 매 커맨드 실행 후 세션/debate/safety 상태를 3-5줄로 자동 출력
- **행동적 QA**: Fake Codex mock, 4개 시나리오 자동 테스트, 수동 체크리스트

전체 변경 이력은 [CHANGELOG.md](CHANGELOG.md)를 참조하세요.

---

## Prerequisites / 사전 요구사항

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI 설치 및 인증
- [OpenAI Codex CLI](https://github.com/openai/codex) 설치 및 인증 (`codex login`)

Codex CLI must be in your `PATH`. Authentication is handled via OAuth (ChatGPT mode) — no API key needed.

## Installation / 설치

### GitHub 마켓플레이스에서 설치 (From GitHub Marketplace)

```bash
# 1. 마켓플레이스 등록 (최초 1회)
claude plugin marketplace add secucon/codex-collab

# 2. 플러그인 설치
claude plugin install codex-collab@codex-collab
```

### 로컬 설치 (Local Install — for development)

```bash
git clone https://github.com/secucon/codex-collab.git
cd codex-collab
claude plugin add ./
```

---

## Quick Start / 빠른 시작

```bash
# Codex에게 질문 (세션이 없으면 자동 생성됨)
/codex-ask 이 함수의 시간 복잡도를 분석해줘

# 코드 평가 + 교차 검증
/codex-evaluate src/auth.ts

# 자동 토론
/codex-debate 이 모듈을 클래스로 리팩토링해야 할까?

# 세션 종료
/codex-session end
```

> v2.1부터 `/codex-session start`를 먼저 실행하지 않아도 됩니다. 세션이 자동 생성됩니다.
> 명시적으로 세션을 설정하려면 `/codex-session start <이름>`을 사용하세요.

---

## Commands / 명령어

### `/codex-session <start|end|delete|list>`

세션 생명주기를 관리합니다. Manages session lifecycle.

| Subcommand | Description |
|------------|-------------|
| `start <name>` | 새 세션 시작 (고급 사용). Start a new session (advanced). |
| `end` | 활성 세션 종료. End active session. |
| `delete <id>` | 세션 영구 삭제. Permanently delete a session. |
| `list` | 현재 프로젝트 세션 목록. List sessions for current project. |

### `/codex-ask <prompt>`

Codex에게 질문하거나 작업을 위임합니다. Ask Codex a question or delegate a task.

- read/write 모드 자동 판단 (Auto-detects read-only vs write mode)
- write 모드 시 사용자 확인 필수 (Write mode requires user confirmation)
- 세션 없으면 자동 생성 (Auto-creates session if none active)

### `/codex-evaluate <target>`

Codex가 코드를 평가하고 Claude가 교차 검증합니다. Codex evaluates code, Claude cross-verifies.

- `--output-schema`로 구조화된 결과 (Structured results via --output-schema)
- 세션 내 이전 평가와 추이 비교 (Trend comparison within session)
- 세션 없으면 자동 생성 (Auto-creates session if none active)

### `/codex-debate <topic>`

Claude↔Codex 자동 토론. Automated debate between Claude and Codex.

- 최대 5라운드 + 추가 2라운드, 조기 합의 시 종료 (Max 5+2 rounds, early consensus exit)
- 합의 시 diff + 근거 표시 → 코드 자동 적용 (Consensus: auto-apply code with approval)
- 비합의 시 4개 선택지: Claude안 / Codex안 / 추가라운드 / 버리기 (Non-consensus: 4 choices)
- 리포트 자동 저장 `.codex-collab/reports/` (Auto-save reports)
- 앵커링 방지 프로토콜 적용 (Anti-anchoring protocol)

---

## Configuration / 설정

v2.1부터 프로젝트별 설정 파일을 지원합니다. 2-tier config hierarchy with project override.

| 위치 | 경로 | 우선순위 |
|------|------|----------|
| 글로벌 (Global) | `~/.claude/codex-collab-config.yaml` | 낮음 |
| 프로젝트 (Project) | `.codex-collab/config.yaml` | 높음 |

```yaml
# .codex-collab/config.yaml
session:
  auto_create: true            # 세션 없으면 자동 생성 (default: true)
  auto_name_prefix: "auto"     # 자동 생성 세션 이름 접두사

debate:
  default_rounds: 3            # 기본 토론 라운드 수
  max_additional_rounds: 2     # 비합의 시 추가 가능 라운드

safety:
  auto_trigger: true           # safety hook 감지 시 debate 자동 제안
  require_approval: true       # 자동 트리거 시 사용자 승인 필수 (invariant)

status:
  auto_summary: true           # 커맨드 실행 후 자동 상태 요약
```

---

## Architecture / 아키텍처

### Agents / 에이전트

| Agent | Role |
|-------|------|
| `workflow-orchestrator` | 모든 커맨드의 상위 오케스트레이터. Top-level orchestrator. |
| `session-manager` | 세션 CRUD, 자동 생성, 프로젝트별 필터링. Session lifecycle + auto-create. |
| `codex-delegator` | 순수 CLI 호출 + 응답 파싱 + session ID 캡처. CLI invocation + session capture. |
| `cross-verifier` | 교차 검증 (evaluate 필수 단계). Cross-verification. |
| `rule-engine` | 조건-액션 규칙 평가, 자동 후속 커맨드. Condition-action rules. |

### Skills / 스킬

| Skill | Role |
|-------|------|
| `codex-invocation` | CLI 호출 패턴, 플래그, 에러 처리. CLI patterns and error handling. |
| `session-management` | 세션 저장소, 스키마, CRUD 로직. Session storage and CRUD logic. |
| `schema-builder` | output-schema 동적 생성. JSON Schema construction. |

### Schemas / 스키마

| Schema | Description |
|--------|-------------|
| [`evaluation.json`](schemas/evaluation.json) | 코드 평가 결과. Code evaluation results. |
| [`debate.json`](schemas/debate.json) | 토론 라운드 입장. Debate round positions. |
| [`config.json`](schemas/config.json) | 설정 파일 스키마. Config file schema. |
| [`debate-report.json`](schemas/debate-report.json) | 토론 리포트. Debate report structure. |
| [`approval-result.json`](schemas/approval-result.json) | 합의 승인 결과. Approval result. |

### Scripts / 스크립트

| Category | Scripts |
|----------|---------|
| Config | `load-config.sh` |
| Session | `session-auto-create.sh` |
| Safety | `safety-hook-topic.sh` |
| Debate | `debate-result-handler.sh`, `detect-non-consensus.sh`, `detect-exhaustion.sh`, `debate-round-cap.sh`, `display-consensus-result.sh`, `display-non-consensus-choices.sh`, `debate-result-approval.sh`, `apply-changes.sh` |
| Reports | `compose-report.sh`, `debate-report.sh` |
| Status | `status-summary.sh` |

### Validation / 검증

```bash
bash scripts/validate-plugin.sh
```

플러그인 구조 무결성을 검증합니다 (37 checks).
Validates plugin structural integrity.

---

## Rules Configuration / 규칙 설정

`rule-engine` agent는 커맨드 실행 결과에 따라 자동으로 후속 액션을 트리거합니다.
The `rule-engine` agent triggers automatic follow-up actions based on command results.

### Rule Files / 규칙 파일

| 위치 | 경로 | 우선순위 |
|------|------|----------|
| 글로벌 | `~/.claude/codex-rules.yaml` | 낮음 |
| 프로젝트 | `.codex-collab/rules.yaml` | 높음 |

로딩 우선순위: `기본 내장 ← 글로벌 ← 프로젝트`

```bash
# 예제 파일을 프로젝트 규칙으로 복사
mkdir -p .codex-collab
cp docs/rules.yaml.example .codex-collab/rules.yaml
```

전체 규칙 스키마와 예제는 [`docs/rules.yaml.example`](docs/rules.yaml.example)을 참조하세요.

---

## Safety / 안전장치

5개의 안전 훅이 Codex CLI 호출을 감시합니다. Five safety hooks guard Codex CLI invocations:

| Hook | Type | Action |
|------|------|--------|
| `--full-auto` 감지 | PreToolUse | 경고 메시지 (Warning) |
| `--dangerously-*` 감지 | PreToolUse | **차단 — exit 2** (Blocked) |
| write 모드 감지 | PreToolUse | 파일 변경 경고 (Write-mode awareness) |
| 세션 없이 Codex 호출 | PreToolUse | 프로젝트별 세션 경고 (Session warning) |
| Codex 실행 완료 | PostToolUse | 자동 상태 요약 출력 (Auto status summary) |

추가 안전장치:
- Safety hook `caution+` 감지 시 cross-model debate 자동 제안 (사용자 승인 필수)
- write 모드 자동 판단 시 사용자 확인 필수
- 규칙 엔진 자동 액션 체인 최대 깊이: **3**

---

## Testing / 테스트

### 구조적 검증 (Structural Validation)

```bash
bash scripts/validate-plugin.sh
```

### 행동적 테스트 (Behavioral Testing)

```bash
# 4개 시나리오 자동 테스트 (Fake Codex mock 사용)
bash tests/run-scenarios.sh
```

시나리오: happy path E2E, debate resume chain, rule engine cascade, error recovery.

### 수동 체크리스트 (Manual QA)

[`tests/manual-checklist.md`](tests/manual-checklist.md) — 실제 Codex CLI로 시나리오별 검증.

---

## Upgrading / 업그레이드

### v2.0 → v2.1

비파괴적 업그레이드. 기존 v2.0 워크플로우가 그대로 동작합니다.

```bash
claude plugin update codex-collab
```

새 기능: 세션 자동 생성 (`session.auto_create: true` 기본값). 비활성화하려면:

```yaml
# .codex-collab/config.yaml
session:
  auto_create: false
```

### v1 → v2

v2는 v1의 **클린 브레이크(breaking change)** 입니다.

| v1 (제거됨) | v2 (대체) | 비고 |
|------------|-----------|------|
| `/codex <prompt>` | `/codex-ask <prompt>` | 세션 자동 생성 (v2.1+) |
| `/codex-opinion <question>` | `/codex-ask <question>` | ask로 통합 |
| `/codex-review` | `/codex-evaluate` | 교차 검증 필수 |
| `/codex-verify` | `/codex-evaluate` | review와 통합 |
| *(없음)* | `/codex-session` | 세션 관리 |
| *(없음)* | `/codex-debate` | 자동 토론 |

---

## License / 라이선스

[MIT](LICENSE) | [CHANGELOG](CHANGELOG.md)
