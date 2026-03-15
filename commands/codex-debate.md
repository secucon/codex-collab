---
description: Claude↔Codex(GPT-5.4) 자동 토론 — 최대 default_rounds+2 라운드, 조기 합의 종료 (세션 필수)
argument-hint: <topic — question or design decision to debate>
---

# Codex Debate

Claude와 Codex가 주어진 주제에 대해 자동으로 토론합니다. 각 라운드에서 구조화된 JSON으로 입장을 교환하며, 합의에 도달하거나 최대 라운드 수에 도달할 때까지 진행합니다.

### Round Limit Calculation

최대 라운드 수는 config에서 동적으로 결정됩니다:

```
effective_max_rounds = default_rounds + max_additional_rounds
```

- `default_rounds`: config의 `debate.default_rounds` (기본: 3, 범위: 1-7)
- `max_additional_rounds`: config의 `debate.max_additional_rounds` (기본: 2, **하드캡: 2**)
- 기본 설정 시: 3 + 2 = **최대 5라운드**
- `max_additional_rounds`는 config에서 어떤 값을 설정하더라도 **절대 2를 초과할 수 없음** (load-config.sh에서 강제)

예시:
| default_rounds | max_additional_rounds (설정) | max_additional_rounds (적용) | effective_max |
|:-:|:-:|:-:|:-:|
| 3 | 2 | 2 | 5 |
| 5 | 2 | 2 | 7 |
| 3 | 0 | 0 | 3 |
| 1 | 5 | 2 (하드캡) | 3 |

## Workflow

1. `workflow-orchestrator`에게 라우팅합니다
2. Orchestrator가 활성 세션을 확인합니다
   - 세션 없으면: config의 `session.auto_create`에 따라 자동 생성 (기본: `true`)
   - 자동 생성 시: `[codex-collab] 세션 자동 생성: <name> (ID: <id>)` 알림 표시
   - `session.auto_create: false`인 경우: "활성 세션이 없습니다. `/codex-session start <이름>`으로 시작하세요." 안내
3. 토론이 시작됩니다:

```
[Round 1] Codex 입장 요청 → Codex 응답 (구조화 JSON)
          Claude 반론 생성 (구조화 JSON) → Codex에 전달
[Round 2] Codex 재반론 (구조화 JSON)
          Claude 재반론 (구조화 JSON) → Codex에 전달
          ...합의 확인 (agrees_with_opponent)...
[Round N] 합의 도달 또는 최대 라운드(default_rounds + max_additional_rounds) → 최종 리포트
```

> ⚠️ **Round Cap**: `max_additional_rounds`는 하드캡 2를 초과할 수 없습니다. config에서 3 이상을 설정해도 2로 클램핑됩니다.

4. 세션 이력에 토론 결과를 기록합니다
5. 최종 리포트를 표시합니다
6. **합의 결과 표시 (Consensus Result Display)**: `scripts/display-consensus-result.sh`를 통해 구조화된 결과 UI를 표시합니다:
   - **Diff 섹션**: 합의된 코드 변경 사항 — 코드 토론의 경우 `diff` 형식으로 제안된 변경 표시
   - **Rationale 섹션**: 양측의 논거를 종합한 추론 요약 — 합의에 이른 논리적 경로 표시
   - **승인 프롬프트**: `debate.auto_apply_result: true`인 경우, 변경 적용 전 사용자 승인 요청
   - 합의 미도달 시에도 양측 입장과 핵심 논점을 rationale로 표시
7. **자동 상태 요약**: config의 `status.auto_summary`가 `true`(기본값)이면, 커맨드 완료 후 자동으로 상태 요약을 출력합니다:

```
[codex-collab] ✓ Codex Debate completed — 3 round(s), consensus reached
[codex-collab] Status Summary
─────────────────────────────
📋 Session: "작업명" (active) | Participants: Claude + Codex (GPT-5.4) | Interactions: N
⚡ Last action: /codex-debate — REST vs GraphQL for this project
📊 Total: N interactions | 1 active, 0 ended sessions
```

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
- 최대 라운드(default_rounds + max_additional_rounds, 추가 라운드 하드캡: 2) → 합의 미도달 시 양쪽 입장 나란히 제시

### Non-Consensus Detection (`scripts/detect-non-consensus.sh`)

합의에 도달하지 못한 경우, `detect-non-consensus.sh`가 양측 제안의 발산 상태를 분석합니다:

```bash
source scripts/detect-non-consensus.sh
detection_result=$(detect_non_consensus "$paired_rounds_json" "$topic")
# Returns JSON with:
#   consensus_state: "non-consensus"
#   codex_proposal: { position, confidence, key_arguments }
#   claude_proposal: { position, confidence, key_arguments }
#   divergence_score: 0.0-1.0
#   convergence_trend: "converging" | "diverging" | "stable"

# Display formatted non-consensus result
format_non_consensus_display "$detection_result"
```

**Non-consensus 판단 기준:**
- 모든 라운드에서 `agrees_with_opponent: false` → 비합의 상태
- `divergence_score`가 높을수록 양측 입장이 멀리 발산
- `convergence_trend`로 추가 라운드 시 합의 가능성 판단 가능

**Non-consensus 결과 표시:**

```
┌─────────────────────────────────────────────────────────────┐
│  ⚖️  Non-Consensus Detected — Both Proposals Diverge        │
├─────────────────────────────────────────────────────────────┤
│  📌 Topic:       Microservices vs Monolith                   │
│  🔄 Rounds:      3                                           │
│  📊 Divergence:  0.72 (stable)                               │
└─────────────────────────────────────────────────────────────┘

### 🤖 Codex Proposal (GPT-5.4)
**Position:** Microservices remain the right choice...
**Confidence:** 0.75
**Key Arguments:**
  - Product roadmap indicates 3x team growth

### 🧠 Claude Proposal
**Position:** Modular monolith is more appropriate...
**Confidence:** 0.78
**Key Arguments:**
  - Team of 5 cannot maintain 12+ services

### 📈 Convergence Path
  Round 1: Codex (0.85) / Claude (0.80)
  Round 2: Codex (0.75) / Claude (0.78)
  Round 3: Codex (0.70) / Claude (0.75)

⚖️  **No consensus was reached.** Both proposals are presented above.
```

## Final Report Format

The complete debate report is composed by `scripts/compose-report.sh`, combining all 6 elements into a structured markdown document:

```
## Debate Report (토론 리포트)

### Topic (주제)
> [토론 주제]

### Trigger (트리거)
- **Source:** Manual | Safety Hook | Rule Engine

### Participants (참여 모델)
| Model | Role |
|-------|------|
| Claude (Anthropic) | Counter-position, independent analysis |
| Codex GPT-5.4 (OpenAI) | Initial position, structured debate |

### Round Summaries (라운드 요약)
| Round | Codex Position | Claude Position | Consensus |
|:-----:|:---------------|:----------------|:---------:|
| 1     | [요약] (0.80)  | [요약] (0.75)   | No        |
| 2     | [요약] (0.82)  | [요약] (0.78)   | No        |
| 3     | [요약] (0.85)  | [요약] (0.85)   | Yes       |

### Final Result (최종 결과)
**Status:** Consensus Reached / No Consensus
[합의 내용 또는 각 측의 최종 입장, 핵심 논점, 사용자 권고]

### Chosen Action (선택된 조치)
- **Decision:** [사용자 선택 — Claude/Codex 적용, 추가 라운드, 폐기]
- **Apply Status:** [적용 결과]
```

### Report Generation (Shell)

```bash
source scripts/compose-report.sh

# Full markdown report (console + auto-save to .codex-collab/reports/)
compose_and_save_report "$result_json" "apply_claude" "manual" "applied"

# Compact one-liner for status displays
compose_compact_report "$result_json" "apply_claude" "manual"
# → [codex-collab] Debate: "REST vs GraphQL" | 3 round(s) | consensus | action=applied:claude | trigger=manual

# JSON format for programmatic use
compose_report_json "$result_json" "apply_claude" "manual" "applied"
```

### Report Output Formats

| Format | Function | Use Case |
|--------|----------|----------|
| `text` (markdown) | `compose_final_report` | Console display, file reports |
| `json` | `compose_report_json` | Session history, API integration |
| `compact` | `compose_compact_report` | Status summary one-liners |
| `save` | `compose_and_save_report` | Console + auto-save to reports dir |

## Consensus Result Display

토론 완료 후, `scripts/display-consensus-result.sh`가 생성하는 구조화된 결과 UI:

```
┌─────────────────────────────────────────────────────────────┐
│  ✅ Consensus Reached                                       │
├─────────────────────────────────────────────────────────────┤
│  📌 Topic:      이 모듈을 클래스로 리팩토링해야 할까?         │
│  🔄 Rounds:     3                                           │
│  📊 Confidence: 0.85                                        │
└─────────────────────────────────────────────────────────────┘

### 📝 Proposed Changes (Diff)

\`\`\`diff
- const handler = (req) => { ... }
+ class RequestHandler {
+   handle(req) { ... }
+ }
\`\`\`

### 💡 Rationale (Reasoning Summary)

**Agreed Position:**
> A hybrid approach using functional core with class wrappers...

**Supporting Arguments:**

_From Codex (GPT-5.4):_
  - Pure functions for business logic ensure testability
  - Class wrappers for I/O provide clean interfaces

_From Claude:_
  - Current codebase is 80% functional — consistency matters
  - Only 2 modules genuinely benefit from class encapsulation

**Convergence Path:**
  Round 1: Codex — Classes are superior (confidence: 0.80)
  Round 2: Claude — Functional patterns offer stronger composability (confidence: 0.65)
  Round 3: Codex — Hybrid approach is optimal ✓ (confidence: 0.85)

---

💬 **Review the consensus result above.**
  → To apply changes, use: `/codex-ask apply the debate consensus`
  → The full debate is saved in your session history
```

### Display Configuration

| Field | Source | Description |
|-------|--------|-------------|
| Diff | `result.diff` or `result.code_changes` | 합의된 코드 변경 사항 (없으면 "No code changes" 메시지) |
| Rationale | `result.final_position` + `result.*_arguments` | 양측 논거 종합 요약 |
| Approval | `debate.auto_apply_result` config | `true`이면 적용 전 사용자 승인 프롬프트 표시 |

### Usage (Shell)

```bash
# Source and use programmatically
source scripts/display-consensus-result.sh
display_consensus_result "$debate_result_json"

# Build consensus result from raw round data
consensus_json=$(extract_consensus_from_rounds "$rounds_json" "$topic")
display_consensus_result "$consensus_json"

# CLI usage
./scripts/display-consensus-result.sh --result '{"topic":"REST vs GraphQL","rounds":3,"consensus_reached":true,...}'
```

## User Approval Flow

토론 결과가 코드 변경을 제안하는 경우, 변경 적용 전 **반드시** 사용자 승인이 필요합니다 (`safety.require_approval: true` — 재정의 불가).

### 4-Choice Result Handler Pipeline

```
토론 완료 → 결과 리포트 표시 (display-consensus-result.sh)
  → scripts/debate-result-handler.sh로 4가지 선택지 표시:
    [1] Apply Claude's proposal  — Claude의 제안 적용
    [2] Apply Codex's proposal   — Codex (GPT-5.4)의 제안 적용
    [3] Continue debate           — 추가 라운드 실행 (라운드 캡 범위 내)
    [4] Discard both              — 양측 제안 모두 폐기
  → 사용자 선택 처리:
    [1/2] → 선택 측의 코드 변경 추출 → 미리보기 → 승인 → 적용 (apply-changes.sh)
    [3]   → 라운드 캡 확인 (debate-round-cap.sh) → 추가 라운드 실행
    [4]   → 변경 없음, 양측 입장 세션 이력에 기록
  → 결정 기록 (session history에 debate_result_handler 항목)
```

### Choice Handler Details

| Choice | Input Variants | Action | Status |
|--------|---------------|--------|--------|
| [1] Apply Claude | `1`, `claude`, `apply_claude` | Claude 측 코드 변경 추출 + 미리보기 + 승인 후 적용 | `applied` / `informational` |
| [2] Apply Codex | `2`, `codex`, `apply_codex`, `gpt` | Codex 측 코드 변경 추출 + 미리보기 + 승인 후 적용 | `applied` / `informational` |
| [3] Continue | `3`, `continue`, `more` | 라운드 캡 확인 후 추가 라운드 실행 (캡 도달 시 재선택 요청) | `authorized` / `blocked_cap` |
| [4] Discard | `4`, `discard`, `reject`, `no` | 양측 제안 폐기, 세션 이력에 기록 | `discarded` |

> ⚠️ **Choice [3] 제한**: 추가 라운드는 `effective_max` (default_rounds + max_additional_rounds, 하드캡 2)까지만 가능합니다. 캡에 도달하면 선택지 1/2/4만 사용 가능합니다.

### Approval Prompt 구성 (Choice 1/2 선택 시)

| Section | Content |
|---------|---------|
| Topic & Summary | 토론 주제, 라운드 수, 합의 상태, 신뢰도 |
| Rationale | 최종 입장을 뒷받침하는 근거 목록 |
| Proposed Changes | 선택한 측의 파일별 diff 표시 (생성/수정/삭제), 컬러 diff 출력 |
| Key Arguments | 선택한 측의 핵심 논거 |
| Approval Gate | 코드 적용 전 반드시 사용자 확인 필요 (`safety.require_approval: true`) |

### Auto-Triggered Debate Approval

안전 훅 또는 규칙 엔진이 자동 트리거한 토론의 경우, `debate.auto_apply_result` 설정과 관계없이 **항상** 승인 프롬프트가 표시됩니다:

```
[codex-collab] ⚡ This debate was auto-triggered by: <trigger_source>
[codex-collab] ℹ️  User approval is required before any changes can be applied
```

### Approval Record Schema

승인 결정은 `schemas/approval-result.json` 스키마에 따라 세션 이력에 기록됩니다:

```json
{
  "type": "debate_approval",
  "session_id": "<session-id>",
  "timestamp": "2026-03-15T10:30:00Z",
  "decision": "accepted",
  "topic": "REST vs GraphQL",
  "applied": true,
  "trigger_source": "manual"
}
```

### Shell Usage

```bash
# Source and present approval prompt
source scripts/debate-result-approval.sh
present_approval_prompt "$debate_result_json" "$session_id"

# Parse user response
decision=$(parse_approval_decision "$user_response")
# Returns: "accepted", "rejected", "modify", or "unknown"

# Create session history record
record=$(create_approval_record "$session_id" "$decision" "$topic" "$modifications")

# Get status line for summary
status=$(approval_status_line "$decision")
```

## Code Change Application

사용자가 토론 결과의 코드 변경을 **승인(ACCEPT)**하면, `scripts/apply-changes.sh`를 통해 변경 사항이 실제 코드베이스에 적용됩니다.

### Application Flow

```
사용자 ACCEPT → apply-changes.sh 실행
  1. 토론 결과 파일에서 코드 변경 추출 (extract_code_changes)
     - Unified diff (--- a/file, +++ b/file)
     - 파일 경로 주석이 달린 코드 블록 (```lang:path/to/file)
     - 구조화된 JSON changes 배열
  2. 변경 미리보기 표시 (preview_changes)
  3. Git 백업 생성 (stash 또는 HEAD ref 저장)
  4. 변경 적용 (apply_all_changes)
     - Diff → git apply 또는 patch -p1
     - 파일 내용 → 직접 파일 쓰기
  5. 결과 보고 (Applied: N/M, Failed: F)
  6. 실패 시 롤백 제안 (execute_rollback)
```

### Shell Usage

```bash
source scripts/apply-changes.sh

# Step 1: Extract and preview changes
apply_debate_result "/tmp/codex-collab-debate-<timestamp>.md" "$(pwd)"
# Outputs: CHANGE_COUNT, CHANGE_DIR, WORKING_DIR

# Step 2: Apply after user approval
execute_approved_changes "$CHANGE_DIR" "$(pwd)"
# Outputs: APPLY_STATUS (success | partial_failure)

# Step 3: Rollback on failure (if user requests)
execute_rollback "$(pwd)" "$BACKUP_REF"

# Dry-run mode (preview only, no application)
apply_debate_result "/tmp/codex-collab-debate-<timestamp>.md" "$(pwd)" "dry-run"
```

### Safety Guarantees

| Guarantee | Enforcement |
|-----------|-------------|
| 사용자 승인 필수 | `safety.require_approval: true` (재정의 불가) |
| Git 백업 | 적용 전 stash 또는 HEAD ref 자동 저장 |
| 롤백 가능 | 부분 실패 시 `execute_rollback` 제공 |
| 로그 기록 | `/tmp/codex-collab-apply/apply-<id>/apply-log.json` |
| 적용 상태 추적 | 세션 이력에 `apply_status` 필드 기록 |

## Error Handling

- 세션 없음 → `session.auto_create: true`이면 자동 생성, `false`이면 `/codex-session start` 안내
- Codex CLI 실패 → 1회 재시도, 실패 시 현재까지 결과로 부분 완료
- 빈 응답 → 해당 라운드 건너뛰고 부분 완료

## Examples

```
/codex-debate 이 모듈을 클래스로 리팩토링해야 할까?
/codex-debate REST vs GraphQL for this project
/codex-debate 모노레포 vs 멀티레포 전략
```
