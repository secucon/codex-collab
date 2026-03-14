# codex-collab

**Claude Code에서 OpenAI Codex CLI(GPT-5.4)를 호출하여 두 AI 모델 간 협업을 구현하는 플러그인**

A Claude Code plugin that invokes OpenAI Codex CLI (GPT-5.4) for cross-model collaboration — task delegation, code review, verification, and second opinions.

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

## Commands / 명령어

### `/codex <prompt>`

Codex CLI에 작업을 위임하고 결과를 받아옵니다.
Delegates a task to Codex CLI and returns the result.

- 분석/리뷰 → read-only 모드 (기본)
- 파일 생성/수정 → `--full-auto` 모드 (사용자 확인 후)

### `/codex-review [--base <branch>] [--commit <sha>]`

Codex의 내장 코드 리뷰 기능으로 독립적인 코드 리뷰를 받습니다.
Gets an independent code review from Codex's built-in review feature.

- 인자 없음 → uncommitted 변경사항 리뷰
- `--base main` → 브랜치 비교 리뷰

### `/codex-verify [what to verify]`

Claude가 작성한 코드/설계를 Codex에게 독립 검증받습니다.
Cross-verifies Claude's work with an independent Codex assessment.

구조화된 리포트 출력: 합의 / 불일치 / 주의사항 / 결론

### `/codex-opinion <question>`

설계/코드/기술 질문에 대해 Codex로부터 세컨드 오피니언을 받습니다.
Gets a second opinion from Codex on design, code, or technical questions.

Claude와 Codex의 관점을 나란히 비교하여 제시합니다. 앵커링 바이어스를 방지하기 위해 Claude의 결론을 Codex에 노출하지 않습니다.

---

## Agents / 에이전트

| Agent | Description |
|-------|-------------|
| `codex-delegator` | 작업을 Codex에 위임하고 결과를 해석합니다. Orchestrates task delegation to Codex CLI. |
| `cross-verifier` | Claude의 작업을 Codex로 독립 검증합니다. Cross-verifies Claude's output with Codex. |

## Skills / 스킬

| Skill | Description |
|-------|-------------|
| `codex-invocation` | Codex CLI 호출 패턴, 플래그, 출력 처리, 에러 복구 가이드. Invocation patterns, flags, output handling, and error recovery. |

---

## Safety / 안전장치

이 플러그인은 PreToolUse 훅을 통해 안전장치를 제공합니다:

This plugin provides safety guards via PreToolUse hooks:

- `--full-auto` 사용 시 경고 메시지 표시 (파일 수정 가능성 알림)
- `--dangerously-bypass-approvals-and-sandbox` 사용 차단 (exit code 2)
- 모든 Codex 출력은 `/tmp/`에만 저장 — 프로젝트 트리 오염 방지

---

## License / 라이선스

[MIT](LICENSE)
