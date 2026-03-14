---
description: Codex CLI(GPT-5.4)에게 작업을 위임하고 결과를 받아옵니다
argument-hint: <prompt describing the task to delegate>
---

# Codex Task Delegation

사용자의 요청을 Codex CLI에 위임하여 결과를 가져옵니다.

## Workflow

1. `$ARGUMENTS`를 Codex 프롬프트로 사용합니다
2. 작업 성격을 판단합니다:
   - **분석/질문/리뷰** → `-s read-only` (기본)
   - **파일 생성/수정 요청** → `--full-auto` (sandboxed workspace-write, 사용자에게 확인 후)
3. Codex를 호출합니다:

```bash
CODEX=$(command -v codex)
OUTPUT=/tmp/codex-collab-$(date +%s).md
$CODEX exec --ephemeral -o "$OUTPUT" -C "$(pwd)" -s read-only "$ARGUMENTS"
```

4. 출력 파일을 Read tool로 읽습니다
5. 결과를 다음 형식으로 표시합니다:

```
**Codex (GPT-5.4) 응답:**

[Codex 출력 내용]
```

6. 필요하면 Claude의 코멘트를 추가합니다

## Error Handling

- 종료 코드가 0이 아니면 stderr를 확인하고 사용자에게 보고합니다
- 인증 오류가 감지되면 `codex login` 실행을 안내합니다
- 출력이 비어있으면 프롬프트를 단순화하여 재시도를 제안합니다

## Timeout

Bash timeout을 300000ms(5분)로 설정합니다.
