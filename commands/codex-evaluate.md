---
description: Codex(GPT-5.4)로 코드를 평가하고 Claude가 교차 검증합니다 (세션 필수)
argument-hint: <target — file path, function name, or description of code to evaluate>
---

# Codex Evaluate

Codex가 코드를 평가하고, Claude(`cross-verifier`)가 필수 교차 검증을 수행합니다. 구조화된 결과를 반환합니다.

## Workflow

1. `workflow-orchestrator`에게 라우팅합니다
2. Orchestrator가 활성 세션을 확인합니다
   - 세션 없으면: "활성 세션이 없습니다. `/codex-session start <이름>`으로 시작하세요." 안내
3. 평가 대상을 파악합니다:
   - `$ARGUMENTS`에서 파일 경로, 함수명, 또는 설명 추출
   - 대상 파일을 읽어 컨텍스트 수집
4. `codex-delegator`가 `--output-schema`와 함께 Codex CLI를 호출합니다
5. `cross-verifier`가 Codex 결과를 **필수** 교차 검증합니다
6. 구조화된 리포트를 세션 이력에 기록합니다
7. 결과를 표시합니다

## Evaluation Output Schema

Codex에게 전달되는 `--output-schema`:

```json
{
  "type": "object",
  "properties": {
    "issues": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "severity": {"type": "string", "enum": ["low", "medium", "high", "critical"]},
          "category": {"type": "string", "enum": ["bug", "security", "performance", "style", "logic"]},
          "file": {"type": "string"},
          "line": {"type": "integer"},
          "description": {"type": "string"},
          "suggestion": {"type": "string"}
        },
        "required": ["severity", "category", "description"]
      }
    },
    "confidence": {"type": "number", "minimum": 0, "maximum": 1},
    "summary": {"type": "string"},
    "strengths": {"type": "array", "items": {"type": "string"}},
    "overall_quality": {"type": "string", "enum": ["excellent", "good", "acceptable", "needs_improvement", "poor"]}
  },
  "required": ["issues", "confidence", "summary", "overall_quality"]
}
```

## Cross-Verification Report Format

교차 검증 후 최종 리포트:

```
## 평가 리포트 (Evaluation Report)

### Codex 평가 (Codex Evaluation)
- **전체 품질**: [overall_quality]
- **신뢰도**: [confidence]
- **요약**: [summary]

### 발견된 이슈 (Issues Found)
| Severity | Category | File:Line | Description |
|----------|----------|-----------|-------------|
| ...      | ...      | ...       | ...         |

### 교차 검증 (Cross-Verification)
- **합의**: [Claude와 Codex가 동의하는 부분]
- **불일치**: [Codex가 놓쳤거나 Claude가 추가 발견한 부분]
- **최종 판정**: Confirmed / Needs Review / Issues Found
```

## Session History Tracking

세션 이력에 구조화된 결과가 저장되어 이전 평가와 비교 가능:

```
이전 평가: high 이슈 3개, confidence 0.7
현재 평가: high 이슈 1개, confidence 0.9 → 개선됨!
```

## Examples

```
/codex-evaluate src/auth/middleware.ts
/codex-evaluate "handlePayment 함수의 에러 처리"
/codex-evaluate --base main
```

## Error Handling

- 세션 없음 → `/codex-session start` 안내
- Codex CLI 실패 → 1회 재시도, 실패 시 에러 보고
- 교차 검증 실패 → Codex 결과만 표시 (검증 없음 경고)
