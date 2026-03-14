---
description: Codex(GPT-5.4)에게 질문하거나 작업을 위임합니다 (세션 필수)
argument-hint: <prompt — question or task to delegate>
---

# Codex Ask

Codex에게 질문하거나 작업을 위임합니다. read/write 모드를 자동 판단합니다.

## Workflow

1. `workflow-orchestrator`에게 라우팅합니다
2. Orchestrator가 활성 세션을 확인합니다
   - 세션 없으면: "활성 세션이 없습니다. `/codex-session start <이름>`으로 시작하세요." 안내
3. Orchestrator가 `$ARGUMENTS` 프롬프트를 분석하여 모드를 결정합니다:
   - **read-only** (기본): 분석, 질문, 의견 요청
   - **write**: 코드 생성, 수정, 리팩토링 → 사용자 확인 필수
4. `codex-delegator`가 Codex CLI를 호출합니다
5. 결과를 세션 이력에 기록합니다
6. 결과를 표시합니다:

```
**Codex (GPT-5.4) 응답:**

[Codex 출력 내용]
```

## Examples

```
/codex-ask 이 함수의 시간 복잡도를 분석해줘
/codex-ask auth 모듈을 JWT 기반으로 리팩토링해줘
/codex-ask React와 Svelte 중 이 프로젝트에 더 적합한 것은?
```

## Error Handling

- 세션 없음 → `/codex-session start` 안내
- Codex CLI 실패 → 1회 재시도, 실패 시 에러 보고
- 빈 응답 → 프롬프트 단순화 제안
