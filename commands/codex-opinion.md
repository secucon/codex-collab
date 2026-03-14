---
description: Codex(GPT-5.4)에게 설계/코드/기술 질문에 대한 세컨드 오피니언을 요청합니다
argument-hint: <question or topic for second opinion>
---

# Codex Second Opinion

설계 결정, 코드 접근법, 기술적 질문에 대해 Codex로부터 독립적인 의견을 받습니다.

## Workflow

1. 관련 컨텍스트를 수집합니다:
   - `$ARGUMENTS`에서 질문/주제 파악
   - 관련 파일이 언급되었으면 해당 파일을 읽어 컨텍스트에 포함

2. **중립적 프롬프트를 작성합니다** (핵심!):
   - Claude 자신의 결론이나 의견을 Codex에 노출하지 않습니다
   - 이렇게 해야 진정한 독립적 세컨드 오피니언을 얻을 수 있습니다
   - 사실과 제약사항만 전달하고, 어떤 방향이 좋다는 암시를 하지 않습니다

3. Codex를 호출합니다:

```bash
CODEX=$(command -v codex)
OUTPUT=/tmp/codex-collab-opinion-$(date +%s).md
$CODEX exec --ephemeral -o "$OUTPUT" -C "$(pwd)" -s read-only "관련 컨텍스트와 중립적 질문"
```

4. 출력 파일을 Read tool로 읽습니다

5. **두 관점을 나란히 비교합니다**:

```
## Claude 관점
[Claude의 분석/의견]

## Codex (GPT-5.4) 관점
[Codex의 분석/의견]

## 비교
- **합의**: [두 모델이 동의하는 부분]
- **차이**: [의견이 다른 부분과 각각의 근거]
- **종합**: [사용자가 고려할 포인트]
```

## Anti-Pattern: Anchoring Bias

다음과 같은 프롬프트는 피합니다:
- "Claude는 X가 좋다고 했는데 어떻게 생각해?" → 앵커링 발생
- "X와 Y 중 X가 낫지 않아?" → 유도 질문

올바른 프롬프트:
- "X와 Y 접근법의 장단점을 분석해줘"
- "이 설계에서 고려해야 할 트레이드오프는?"
