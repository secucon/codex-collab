---
description: Codex(GPT-5.4)로 코드를 평가하고 Claude가 교차 검증합니다 (세션 필수)
argument-hint: <target — file path, function name, or description of code to evaluate>
---

# Codex Evaluate

Codex가 코드를 평가하고, Claude(`cross-verifier`)가 필수 교차 검증을 수행합니다. 구조화된 결과를 반환합니다.

## Workflow

1. `workflow-orchestrator`에게 라우팅합니다
2. Orchestrator가 활성 세션을 확인합니다
   - 세션 없으면: config의 `session.auto_create`에 따라 자동 생성 (기본: `true`)
   - 자동 생성 시: `[codex-collab] 세션 자동 생성: <name> (ID: <id>)` 알림 표시
   - `session.auto_create: false`인 경우: "활성 세션이 없습니다. `/codex-session start <이름>`으로 시작하세요." 안내
3. 평가 대상을 파악합니다:
   - `$ARGUMENTS`에서 파일 경로, 함수명, 또는 설명 추출
   - 대상 파일을 읽어 컨텍스트 수집
4. `codex-delegator`가 `--output-schema`와 함께 Codex CLI를 호출합니다
5. `cross-verifier`가 Codex 결과를 **필수** 교차 검증합니다
6. 구조화된 리포트를 세션 이력에 기록합니다
7. 결과를 표시합니다
8. **자동 상태 요약**: config의 `status.auto_summary`가 `true`(기본값)이면, 커맨드 완료 후 자동으로 상태 요약을 출력합니다:

```
[codex-collab] ✓ Codex Evaluate completed — quality: good, confidence: 0.85
[codex-collab] Status Summary
─────────────────────────────
📋 Session: "작업명" (active) | Participants: Claude + Codex (GPT-5.4) | Interactions: N
⚡ Last action: /codex-evaluate [read-only] — src/auth/middleware.ts
📊 Total: N interactions | 1 active, 0 ended sessions
```

## Evaluation Output Schema

Codex에게 전달되는 `--output-schema`는 별도의 정규 스키마 파일에서 관리됩니다:

- **평가 스키마**: [`schemas/evaluation.json`](../schemas/evaluation.json)
- **토론 스키마** (관련 명령어): [`schemas/debate.json`](../schemas/debate.json)

`schemas/evaluation.json` 핵심 필드:

| 필드 | 타입 | 설명 |
|------|------|------|
| `issues` | array | 발견된 이슈 목록 (severity, category, description 필수) |
| `confidence` | number (0–1) | 평가 신뢰도 |
| `summary` | string | 전체 요약 |
| `strengths` | array | 코드 강점 목록 |
| `overall_quality` | string | `excellent` / `good` / `acceptable` / `needs_improvement` / `poor` |

스키마 전체 내용은 [`schemas/evaluation.json`](../schemas/evaluation.json)을 참조하세요.

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
```

## Error Handling

- 세션 없음 → `session.auto_create: true`이면 자동 생성, `false`이면 `/codex-session start` 안내
- Codex CLI 실패 → 1회 재시도, 실패 시 에러 보고
- 교차 검증 실패 → Codex 결과만 표시 (검증 없음 경고)

## Failure Modes

Known failure scenarios and mitigation strategies for `codex-evaluate`.

### 1. No Active Session

**Scenario**: `/codex-evaluate` is invoked without a prior `/codex-session start`.

**Symptoms**: Orchestrator cannot locate session context.

**Mitigation** (v2.1.0+):
- If `session.auto_create` is `true` (default): Orchestrator automatically creates a session using config defaults (`session.auto_name_prefix` + timestamp). Displays: *"[codex-collab] 세션 자동 생성: auto-<timestamp> (ID: codex-...)"*
- If `session.auto_create` is `false`: Display a clear prompt: *"활성 세션이 없습니다. `/codex-session start <이름>`으로 시작하세요."*
- Do **not** attempt a partial evaluation without session context — results cannot be tracked or compared.

---

### 2. Codex CLI Timeout / Unavailability

**Scenario**: The Codex CLI process does not respond within the expected time window, or the API endpoint is unreachable.

**Symptoms**: `codex-delegator` hangs or returns a non-zero exit code; no JSON output is produced.

**Mitigation**:
- Perform **one automatic retry** after a short back-off (≈5 s).
- If the retry also fails, surface the raw error message and suggest checking API credentials and network connectivity.
- Abort the evaluation cleanly — do **not** proceed to cross-verification with empty data.

---

### 3. Codex Output Fails Schema Validation

**Scenario**: Codex returns a response that is missing required fields (`issues`, `confidence`, `summary`, `overall_quality`) or contains values outside defined enums.

**Symptoms**: JSON parse succeeds, but schema validation rejects the payload.

**Mitigation**:
- Log the raw Codex response for debugging.
- Report validation errors field-by-field (e.g., *"'severity' must be one of low | medium | high | critical"*).
- Skip cross-verification and return a `SCHEMA_ERROR` status so the session history records the failed attempt rather than corrupt data.

---

### 4. Cross-Verifier Failure

**Scenario**: The `cross-verifier` (Claude) is unavailable, times out, or produces an irreconcilable internal error during cross-verification.

**Symptoms**: Cross-verification step returns an error or empty result after the Codex evaluation has succeeded.

**Mitigation**:
- Display Codex-only results with a visible warning banner: *"⚠ 교차 검증 실패 — Codex 단독 결과입니다. 신뢰도를 낮추어 해석하세요."*
- Record `cross_verified: false` in the session history entry so downstream comparisons can filter unverified results.
- Do **not** block delivery of Codex results; partial output is better than no output.

---

### 5. Conflicting Codex / Claude Verdicts

**Scenario**: Codex and `cross-verifier` reach opposite conclusions on the same code issue (e.g., Codex rates severity `critical`, Claude rates it `low`).

**Symptoms**: Cross-verification 불일치 list is non-empty; overall verdict cannot be auto-resolved.

**Mitigation**:
- Surface both verdicts side-by-side under the **불일치** heading without silently picking one.
- Set the final verdict to `Needs Review` and annotate which items are disputed.
- Optionally invoke `/codex-debate` for a structured resolution of high-severity conflicts.

---

### 6. Evaluation Target Not Found

**Scenario**: The file path or function name provided in `$ARGUMENTS` does not resolve to readable content (file missing, wrong path, binary file).

**Symptoms**: File read operation fails or returns empty/unreadable content before Codex is invoked.

**Mitigation**:
- Validate the target immediately after argument parsing, before calling `codex-delegator`.
- Return a descriptive error: *"대상 파일을 찾을 수 없습니다: `<path>`"* or *"이진(binary) 파일은 평가할 수 없습니다."*
- Suggest using a glob pattern or correcting the path.

---

### 7. Evaluation Target Too Large

**Scenario**: The target file exceeds a size threshold that makes meaningful evaluation impractical (e.g., auto-generated files, minified bundles, files > 2 000 lines).

**Symptoms**: Codex response latency spikes, confidence drops significantly, or the CLI returns a context-limit error.

**Mitigation**:
- Warn the user if the target exceeds a configurable line limit (default: 1 000 lines) and recommend scoping the evaluation to a specific function or range.
- If the limit is exceeded silently, include a `truncation_warning` note in the session history entry.

---

### 8. Session History Write Failure

**Scenario**: The structured evaluation result cannot be appended to the session history (e.g., disk full, permission denied, session store corrupted).

**Symptoms**: Evaluation completes successfully, but the history-write step errors out.

**Mitigation**:
- Display evaluation results to the user regardless — results must not be withheld due to a storage error.
- Emit a distinct warning: *"⚠ 세션 이력 저장 실패 — 결과가 기록되지 않았습니다."*
- Provide the structured JSON result in the chat so the user can manually archive it if needed.

---

### 9. Stale / Corrupt Session State

**Scenario**: An existing session file is present but contains malformed data (e.g., truncated JSON from a previous crash), preventing history comparison.

**Symptoms**: Orchestrator fails to read previous evaluation entries; session appears active but history is inaccessible.

**Mitigation**:
- Attempt to recover by reading only the last valid entry; skip corrupt entries with a warning.
- If recovery is impossible, prompt the user to run `/codex-session start <이름>` to begin a clean session, offering to archive the corrupt file rather than delete it.

---

### Quick-Reference Summary

| # | Failure Mode | Detected At | Fallback Behavior |
|---|---|---|---|
| 1 | No active session | Orchestrator pre-check | Auto-create session (if `session.auto_create: true`) or guide to `/codex-session start` |
| 2 | Codex CLI timeout | `codex-delegator` | 1 retry → error report |
| 3 | Schema validation error | Post-Codex validation | `SCHEMA_ERROR` status, skip cross-verification |
| 4 | Cross-verifier failure | `cross-verifier` step | Codex-only results + `cross_verified: false` |
| 5 | Conflicting verdicts | Cross-verification merge | `Needs Review` + side-by-side display |
| 6 | Target not found | Argument parsing | Descriptive error + path hint |
| 7 | Target too large | Pre-delegation check | Warning + scoping suggestion |
| 8 | History write failure | Post-evaluation write | Display results + storage warning |
| 9 | Corrupt session state | Session read | Partial recovery or re-init prompt |
