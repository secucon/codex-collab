---
description: Claude↔Codex(GPT-5.4) 자동 토론 — 최대 5라운드, 조기 합의 종료 (세션 필수)
argument-hint: <topic — question or design decision to debate>
---

# Codex Debate

Claude와 Codex가 주어진 주제에 대해 자동으로 토론합니다. 각 라운드에서 구조화된 JSON으로 입장을 교환하며, 합의에 도달하거나 최대 5라운드까지 진행합니다.

## Workflow

1. `workflow-orchestrator`에게 라우팅합니다
2. Orchestrator가 활성 세션을 확인합니다
3. 토론이 시작됩니다:

```
[Round 1] Codex 입장 요청 → Codex 응답 (구조화 JSON)
          Claude 반론 생성 (구조화 JSON) → Codex에 전달
[Round 2] Codex 재반론 (구조화 JSON)
          Claude 재반론 (구조화 JSON) → Codex에 전달
          ...합의 확인 (agrees_with_opponent)...
[Round N] 합의 도달 또는 최대 5라운드 → 최종 리포트
```

4. 세션 이력에 토론 결과를 기록합니다
5. 최종 리포트를 표시합니다

## Debate Output Schema

각 라운드에서 양측이 사용하는 구조화 형식:

```json
{
  "position": "핵심 입장 요약",
  "confidence": 0.85,
  "key_arguments": ["근거 1", "근거 2"],
  "agrees_with_opponent": false,
  "counterpoints": ["반론 1", "반론 2"]
}
```

## Consensus Detection

- `agrees_with_opponent: true` → 합의 도달, 조기 종료
- 최대 5라운드 → 합의 미도달 시 양쪽 입장 나란히 제시

## Final Report Format

```
## 토론 리포트 (Debate Report)

### 주제
[토론 주제]

### 라운드 요약
| Round | Codex Position | Claude Position | Consensus |
|-------|---------------|-----------------|-----------|
| 1     | [요약]         | [요약]           | No        |
| 2     | [요약]         | [요약]           | No        |
| 3     | [요약]         | [요약]           | Yes ✓     |

### 최종 합의 / 양측 입장
[합의 내용 또는 각 측의 최종 입장]

### 핵심 논점
- [토론에서 나온 주요 논점들]

### 사용자를 위한 권고
[사용자가 판단할 때 고려할 포인트]
```

## Error Handling

- 세션 없음 → `/codex-session start` 안내
- Codex CLI 실패 → 1회 재시도, 실패 시 현재까지 결과로 부분 완료
- 빈 응답 → 해당 라운드 건너뛰고 부분 완료

## Examples

```
/codex-debate 이 모듈을 클래스로 리팩토링해야 할까?
/codex-debate REST vs GraphQL for this project
/codex-debate 모노레포 vs 멀티레포 전략
```
