---
description: Codex CLI(GPT-5.4)로 현재 변경사항에 대한 독립적 코드 리뷰를 받습니다
argument-hint: [--base <branch>] [--commit <sha>] [custom instructions]
---

# Codex Code Review

Codex의 내장 코드 리뷰 기능을 활용하여 독립적인 코드 리뷰를 받습니다.

## Workflow

1. 현재 git 상태를 확인합니다 (`git status`, `git diff --stat`)
2. 리뷰 대상을 결정합니다:
   - `$ARGUMENTS`가 비어있으면 → uncommitted 변경사항 리뷰
   - `--base <branch>` 지정 시 → 해당 브랜치와 비교 리뷰
   - `--commit <sha>` 지정 시 → 특정 커밋 리뷰

3. Codex review를 실행합니다:

```bash
CODEX=$(command -v codex)
OUTPUT=/tmp/codex-collab-review-$(date +%s).md

# Uncommitted changes (default)
$CODEX exec review --uncommitted -o "$OUTPUT" -C "$(pwd)"

# Branch comparison
$CODEX exec review --base main -o "$OUTPUT" -C "$(pwd)"
```

4. 출력 파일을 Read tool로 읽습니다
5. 결과를 다음 형식으로 표시합니다:

```
**Codex (GPT-5.4) 코드 리뷰:**

[리뷰 내용]
```

6. 사용자의 커스텀 지시사항이 있으면 프롬프트에 포함합니다

## Notes

- Codex review는 `-s read-only`가 기본이므로 파일을 수정하지 않습니다
- git 저장소가 아닌 디렉토리에서는 동작하지 않습니다
