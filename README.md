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
- **자동 토론**: Claude↔Codex 간 최대 5라운드 자동 토론 (Phase 4)

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

# 3. 코드 평가 (Phase 2)
/codex-evaluate src/auth.ts

# 4. 자동 토론 (Phase 4)
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

### `/codex-evaluate <target>` *(Phase 2)*

Codex가 코드를 평가하고 Claude가 교차 검증합니다. Codex evaluates code, Claude cross-verifies.

### `/codex-debate <topic>` *(Phase 4)*

Claude↔Codex 자동 토론. Automated debate between Claude and Codex.

- 최대 5라운드, 조기 합의 시 종료 (Max 5 rounds, early consensus exit)

---

## Architecture / 아키텍처

### Agents / 에이전트

| Agent | Role |
|-------|------|
| `workflow-orchestrator` | 모든 커맨드의 상위 오케스트레이터. Top-level orchestrator. |
| `session-manager` | 세션 CRUD, 프로젝트별 필터링. Session lifecycle management. |
| `codex-delegator` | 순수 CLI 호출 + 응답 파싱. Pure CLI invocation + response parsing. |
| `cross-verifier` | 교차 검증 (evaluate 필수 단계). Cross-verification. |

### Skills / 스킬

| Skill | Role |
|-------|------|
| `codex-invocation` | CLI 호출 패턴, 플래그, 에러 처리. CLI patterns and error handling. |
| `session-management` | 세션 저장소, 스키마, CRUD 로직. Session storage and CRUD logic. |

---

## Safety / 안전장치

- `--full-auto` 사용 시 경고 (Warns on full-auto mode)
- `--dangerously-bypass-approvals-and-sandbox` 차단 (Blocks dangerous mode)
- write 모드 자동 판단 시 사용자 확인 필수 (Write mode requires confirmation)
- 세션 데이터는 `~/.claude/codex-sessions/`에 저장 (프로젝트 트리 외부)

---

## Roadmap

- [x] Phase 1: 세션 시스템 + `/codex-ask`
- [ ] Phase 2: `/codex-evaluate` + 구조화 응답 (`--output-schema`)
- [ ] Phase 3: 규칙 엔진 + 자동 액션
- [ ] Phase 4: `/codex-debate` + 자동 토론

---

## License / 라이선스

[MIT](LICENSE)
