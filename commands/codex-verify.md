---
description: Claude의 최근 작업을 Codex(GPT-5.4)로 독립 검증합니다
argument-hint: [what to verify - defaults to recent code changes]
---

# Codex Cross-Verification

Claude가 작성한 코드, 설계, 분석을 Codex에게 독립적으로 검증받습니다.

## Workflow

1. 검증 대상을 파악합니다:
   - `$ARGUMENTS`가 있으면 해당 내용을 검증
   - 없으면 최근 변경 파일 (`git diff`로 확인) 을 검증 대상으로 사용

2. 검증 대상 파일/코드를 읽습니다

3. Codex에게 검증 요청을 보냅니다:

```bash
CODEX=$(command -v codex)
OUTPUT=/tmp/codex-collab-verify-$(date +%s).md
$CODEX exec --ephemeral -o "$OUTPUT" -C "$(pwd)" -s read-only \
  "다음 코드/설계를 독립적으로 검증해줘. 정확성, 완전성, 잠재적 문제를 확인해:
   [검증 대상 컨텍스트]"
```

4. 출력 파일을 Read tool로 읽습니다

5. 구조화된 검증 리포트를 작성합니다:

```
## 크로스 검증 리포트

### 합의 (Claude ∩ Codex)
- [두 모델이 동의하는 부분]

### 불일치
- [Codex가 지적한 문제점]
- [Claude가 놓친 부분]

### 주의사항
- [추가 검토가 필요한 부분]

### 결론
[전체 검증 결과 요약]
```

## When to Use

- 보안이 중요한 코드 작성 후
- 복잡한 알고리즘 구현 후
- 아키텍처 결정 후 확인
- 프로덕션 배포 전 최종 점검
