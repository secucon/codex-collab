---
name: schema-builder
description: Use when constructing --output-schema JSON Schemas for Codex CLI structured responses. Provides pre-built schemas for evaluation, debate, and custom schema construction patterns.
---

# Schema Builder Guide

Codex CLI의 `--output-schema` 플래그에 전달할 JSON Schema를 커맨드 유형별로 동적 생성합니다.

## Pre-built Schemas

> **Canonical schema files** are the single source of truth. Do **not** duplicate schema content here.
> Read the file directly when you need to pass a schema to `--output-schema`.

### Evaluation Schema

`/codex-evaluate`에서 사용. 코드 품질 평가 결과를 구조화합니다.

**Canonical file:** [`schemas/evaluation.json`](../../schemas/evaluation.json)

Key fields: `issues[]` (severity, category, description), `confidence`, `summary`, `overall_quality`.
To inline for CLI use, read the file at runtime:

```bash
SCHEMA=$(cat schemas/evaluation.json)
```

### Debate Schema

`/codex-debate`에서 사용 (Phase 4). 각 라운드의 입장을 구조화합니다.

**Canonical file:** [`schemas/debate.json`](../../schemas/debate.json)

Key fields: `position`, `confidence`, `key_arguments[]`, `agrees_with_opponent`, `counterpoints[]`.
To inline for CLI use, read the file at runtime:

```bash
SCHEMA=$(cat schemas/debate.json)
```

## Schema Construction Pattern

커스텀 스키마가 필요한 경우:

1. **응답에 필요한 필드를 정의**합니다
2. **각 필드의 타입과 제약**을 JSON Schema로 표현합니다
3. **`required` 필드**를 명시하여 빈 응답을 방지합니다
4. **`enum`을 활용**하여 값을 제한하고 파싱을 용이하게 합니다

### Example: Custom Analysis Schema

```json
{
  "type": "object",
  "properties": {
    "recommendation": {"type": "string", "enum": ["approve", "revise", "reject"]},
    "rationale": {"type": "string"},
    "alternatives": {"type": "array", "items": {"type": "string"}},
    "risk_level": {"type": "string", "enum": ["low", "medium", "high"]}
  },
  "required": ["recommendation", "rationale", "risk_level"]
}
```

## CLI Usage

```bash
CODEX=$(command -v codex)
OUTPUT=/tmp/codex-collab-$(date +%s).md

# Load canonical schema from file (no duplication)
SCHEMA=$(cat schemas/evaluation.json)

$CODEX exec \
  -o "$OUTPUT" \
  -C "$(pwd)" \
  -s read-only \
  --output-schema "$SCHEMA" \
  "Your evaluation prompt"
```

## Result Parsing

`--output-schema` 응답은 JSON으로 반환됩니다. Read tool로 출력 파일을 읽은 후 JSON으로 파싱하여 구조화된 표시에 활용합니다.

## Comparison Tracking

구조화된 결과는 세션 이력의 `structured_result` 필드에 저장됩니다. 이전 결과와 비교하려면:

1. `session-manager`에서 이전 evaluate 이력 조회
2. `issues` 배열의 severity 분포 비교
3. `confidence` 변화 추적
4. 변화를 요약하여 표시:
   ```
   이전 → 현재: high 이슈 3→1, confidence 0.7→0.9 (개선)
   ```
