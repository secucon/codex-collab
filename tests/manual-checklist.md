# codex-collab v2.1.0 — Manual QA Checklist

> **Version:** 2.1.0
> **Date:** 2026-03-15
> **Scope:** Behavioral QA for UX improvements and existing features
> **Prerequisites:** Claude Code with codex-collab plugin loaded, codex CLI available (or fake-codex.sh mock)

---

## How to Use This Checklist

1. Run each scenario in order within its section
2. Check the box when the scenario **passes**
3. Mark `[FAIL]` next to any failing scenario with a brief note
4. Sections marked ★ are **new in v2.1.0**; unmarked sections cover existing v2.0.0 behavior

### Using fake-codex.sh for Offline Testing

```bash
# Shadow real codex binary with mock
export PATH="/path/to/codex-collab/tests:$PATH"
ln -sf fake-codex.sh tests/codex   # create alias matching binary name

# Set scenario before each test
export FAKE_CODEX_SCENARIO=session-start
export FAKE_CODEX_SESSION_ID=fake-session-001
```

---

## 1. Plugin Loading & Validation

- [ ] **1.1** Plugin loads in Claude Code without errors (no "plugin failed to load" messages)
- [ ] **1.2** `bash scripts/validate-plugin.sh` exits with code 0 and all 37 checks pass
- [ ] **1.3** All 4 commands appear in Claude Code: `/codex-session`, `/codex-ask`, `/codex-evaluate`, `/codex-debate`
- [ ] **1.4** All 5 agents are registered: workflow-orchestrator, session-manager, codex-delegator, cross-verifier, rule-engine
- [ ] **1.5** All 3 skills are available: codex-invocation, session-management, schema-builder
- [ ] **1.6** All 4 safety hooks are active in `hooks/hooks.json`

---

## 2. Configuration Loading ★

> **Config hierarchy:** global (`~/.claude/codex-collab-config.yaml`) → project (`.codex-collab/config.yaml`)

- [ ] **2.1** With no config files present, plugin uses built-in defaults without error
- [ ] **2.2** Create `~/.claude/codex-collab-config.yaml` with custom settings → values are picked up
- [ ] **2.3** Create `.codex-collab/config.yaml` with overlapping keys → project values override global
- [ ] **2.4** Project config with unique keys merges with (does not replace) global config
- [ ] **2.5** Malformed YAML in global config → plugin warns but continues with defaults
- [ ] **2.6** Malformed YAML in project config → plugin warns but falls back to global config

---

## 3. Session Management

### 3.1 Basic Session CRUD

- [ ] **3.1.1** `/codex-session start "test session"` creates session file in `~/.claude/codex-sessions/`
- [ ] **3.1.2** Session file JSON contains: `id`, `name`, `project`, `codex_session_id`, `created_at`, `status: "active"`, `history: []`
- [ ] **3.1.3** `project` field matches current working directory (absolute path)
- [ ] **3.1.4** `/codex-session list` shows only sessions for current project
- [ ] **3.1.5** `/codex-session end` sets `status: "ended"` and populates `ended_at`
- [ ] **3.1.6** `/codex-session delete <id>` removes the session file entirely
- [ ] **3.1.7** Starting a second session while one is active → error: "이미 활성 세션이 있습니다" (or English equivalent)

### 3.2 Session Auto-Creation ★

- [ ] **3.2.1** Run `/codex-ask` with no active session → prompted to auto-create a session
- [ ] **3.2.2** Accepting auto-creation starts session transparently, then executes the original command
- [ ] **3.2.3** Declining auto-creation aborts with guidance: "Use `/codex-session start` to begin"
- [ ] **3.2.4** Run `/codex-evaluate` with no active session → same auto-creation prompt appears
- [ ] **3.2.5** Run `/codex-debate` with no active session → same auto-creation prompt appears
- [ ] **3.2.6** Auto-created session has a default name (e.g., "auto-<timestamp>")
- [ ] **3.2.7** `/codex-session start` still works for users who prefer manual session creation

### 3.3 Session Data Integrity

- [ ] **3.3.1** After running 3+ commands, session `history` array has matching entries
- [ ] **3.3.2** Each history entry contains: `command`, `timestamp`, `prompt_summary`, `mode`, `codex_response_summary`
- [ ] **3.3.3** `prompt_summary` is truncated to ≤ 100 characters
- [ ] **3.3.4** `codex_response_summary` is truncated to ≤ 200 characters
- [ ] **3.3.5** Multiple sessions in different project directories are isolated correctly

---

## 4. `/codex-ask` Command

### 4.1 Read-Only Mode (Default)

- [ ] **4.1.1** Prompt without write keywords → auto-detected as read-only
- [ ] **4.1.2** Codex invoked with `-s read-only` flag
- [ ] **4.1.3** Response displayed with `**Codex (GPT-5.4) 응답:**` header
- [ ] **4.1.4** History entry recorded with `mode: "read-only"`

### 4.2 Write-Mode Detection

- [ ] **4.2.1** Prompt containing "수정" → detected as write mode
- [ ] **4.2.2** Prompt containing "refactor" → detected as write mode
- [ ] **4.2.3** Prompt containing "create" → detected as write mode
- [ ] **4.2.4** Prompt containing "delete" → detected as write mode
- [ ] **4.2.5** Write mode requires user confirmation before execution
- [ ] **4.2.6** User confirms → Codex invoked with write mode
- [ ] **4.2.7** User declines → command aborted, no Codex invocation

### 4.3 Error Handling

- [ ] **4.3.1** `FAKE_CODEX_SCENARIO=error-auth` → authentication error message displayed
- [ ] **4.3.2** `FAKE_CODEX_SCENARIO=error-timeout` → timeout error with retry suggestion
- [ ] **4.3.3** `FAKE_CODEX_SCENARIO=error-empty` → empty response warning, suggests retry or simpler prompt
- [ ] **4.3.4** `FAKE_CODEX_SCENARIO=error-crash` → crash error displayed with stderr content

---

## 5. `/codex-evaluate` Command

### 5.1 Basic Evaluation Flow

- [ ] **5.1.1** `/codex-evaluate src/auth.ts` invokes Codex with `--output-schema evaluation.json`
- [ ] **5.1.2** Structured result contains: `issues[]`, `confidence`, `summary`
- [ ] **5.1.3** Each issue has: `severity`, `file`, `line`, `description`
- [ ] **5.1.4** Cross-verifier agent runs automatically after Codex response
- [ ] **5.1.5** Cross-verification report shows: Agreements, Disagreements, Additional Findings
- [ ] **5.1.6** Final verdict is one of: Confirmed / Needs Review / Issues Found

### 5.2 History Comparison

- [ ] **5.2.1** Evaluating the same target twice → trend shown (e.g., "이슈 3→1, confidence 0.7→0.9")
- [ ] **5.2.2** First evaluation of a target → no trend comparison (handled gracefully)

### 5.3 Edge Cases

- [ ] **5.3.1** `/codex-evaluate nonexistent-file.ts` → descriptive error with path hint
- [ ] **5.3.2** Evaluating file > 1000 lines → warning with scoping suggestion
- [ ] **5.3.3** Cross-verifier failure → Codex-only results displayed with warning banner
- [ ] **5.3.4** Schema validation error in Codex output → marked SCHEMA_ERROR, skip verification

---

## 6. `/codex-debate` Command

### 6.1 Basic Debate Flow

- [ ] **6.1.1** `/codex-debate "REST vs GraphQL"` starts multi-round debate
- [ ] **6.1.2** Each round: Codex position → Claude counter-position → displayed to user
- [ ] **6.1.3** Each Codex turn returns structured JSON matching `debate.json` schema
- [ ] **6.1.4** Debate positions include: `position`, `confidence`, `key_arguments`, `agrees_with_opponent`
- [ ] **6.1.5** Full debate report compiled and displayed at conclusion

### 6.2 Consensus & Termination

- [ ] **6.2.1** `FAKE_CODEX_SCENARIO=debate-consensus` → debate exits early when `agrees_with_opponent: true`
- [ ] **6.2.2** Consensus message clearly indicates which round consensus was reached
- [ ] **6.2.3** Debate terminates after maximum 5 rounds if no consensus
- [ ] **6.2.4** Maximum rounds cap is enforced (no round 6+ possible)

### 6.3 Anti-Anchoring Protocol

- [ ] **6.3.1** Round 1: Claude does NOT share opinion before Codex responds
- [ ] **6.3.2** Each round: Claude generates independent position before analyzing Codex's response in detail
- [ ] **6.3.3** Counterpoints address specific Codex arguments (not generic disagreements)

### 6.4 Debate Result Handling ★

- [ ] **6.4.1** Debate result is stored in session history with full round data
- [ ] **6.4.2** Result passed to rule-engine for triggered rules evaluation
- [ ] **6.4.3** Consensus result triggers different rule path than deadlock result
- [ ] **6.4.4** Maximum 2 additional rounds beyond default when rules request extension
- [ ] **6.4.5** Debate summary includes final positions from both models

### 6.5 Selection = Approval for Non-Consensus (No Secondary Confirmation) ★

> When the user selects [1] or [2] from the 4-choice prompt, changes are previewed and applied immediately. No "Are you sure?" secondary confirmation is shown.

- [ ] **6.5.1** Non-consensus debate presents 4-choice prompt ([1] Claude, [2] Codex, [3] Continue, [4] Discard)
- [ ] **6.5.2** Selecting [1] (Claude) previews code changes AND applies them without secondary confirmation
- [ ] **6.5.3** Selecting [2] (Codex) previews code changes AND applies them without secondary confirmation
- [ ] **6.5.4** `HANDLER_APPROVAL_REQUIRED=false` is emitted (not `true`) when [1] or [2] is selected
- [ ] **6.5.5** Applied changes show `HANDLER_RESULT=applied` on success
- [ ] **6.5.6** Failed application shows `HANDLER_RESULT=partial_failure` and handle_choice returns exit 1
- [ ] **6.5.7** Informational-only proposals (no code changes) still return exit 4 without apply attempt
- [ ] **6.5.8** Selecting [3] (Continue) still checks round cap — no change from prior behavior
- [ ] **6.5.9** Selecting [4] (Discard) still records rejection — no change from prior behavior
- [ ] **6.5.10** Git backup is still created before applying changes (safety guarantee preserved)
- [ ] **6.5.11** Rollback is still available if partial application fails
- [ ] **6.5.12** Session history records the choice with correct `status` and `applied` fields
- [ ] **6.5.13** Auto-triggered debates still require user approval to START (selection=approval only applies to the 4-choice result, not debate initiation)

### 6.6 3-Choice QuickPick When Max Rounds Exhausted ★

> When a debate exhausts its maximum rounds, the "additional round" / "Continue debate" option is **completely excluded** from the choice menu. The user sees exactly 3 choices: [1] Apply Claude, [2] Codex, [3] Discard. The numbering is renumbered so [3] = Discard (not the old [4]).

- [ ] **6.6.1** Debate hitting max rounds (e.g., 5/5) → QuickPick shows exactly 3 choices (no "Continue debate" option)
- [ ] **6.6.2** 3-choice menu shows: [1] Apply Claude, [2] Apply Codex, [3] Discard both
- [ ] **6.6.3** 3-choice mode header reads "Max Rounds Exhausted" (not "Choose How to Proceed")
- [ ] **6.6.4** Reply hint reads "Reply with: 1, 2, or 3" (not "1, 2, 3, or 4")
- [ ] **6.6.5** Typing "3" in 3-choice mode → maps to "Discard" (not "Continue")
- [ ] **6.6.6** Typing "discard" in 3-choice mode → correctly parsed as discard
- [ ] **6.6.7** Typing "continue" or "another round" in 3-choice mode → returns notice + maps to discard
- [ ] **6.6.8** `HANDLER_CHOICES_COUNT` output shows "3" when max rounds exhausted
- [ ] **6.6.9** `HANDLER_MAX_ROUNDS_EXHAUSTED` output shows "true" when max rounds exhausted
- [ ] **6.6.10** Debate finishing before max rounds (e.g., consensus at 3/5) → shows 4 choices (including Continue)
- [ ] **6.6.11** In 4-choice mode, [3] still maps to "Continue debate" and [4] to "Discard"
- [ ] **6.6.12** Non-consensus display also shows exactly 3 choices when max rounds exhausted (display-non-consensus-choices.sh)

### 6.7 Forced Summary on Max-Round Exhaustion ★

> When a debate exhausts its maximum rounds, a summary report is **always** generated regardless of the user's choice. This ensures an audit trail for every exhaustion event.

- [ ] **6.7.1** Debate hitting max rounds (e.g., 5/5) → forced summary report generated after user selects [1] Apply Claude
- [ ] **6.7.2** Debate hitting max rounds → forced summary report generated after user selects [2] Apply Codex
- [ ] **6.7.3** Debate hitting max rounds → forced summary report generated after user selects [3] Discard (renumbered from [4])
- [ ] **6.7.4** Summary header shows "⚠ Max-Round Exhaustion Summary" with separator lines
- [ ] **6.7.5** Summary includes: topic, round count with "(maximum reached)", consensus status, decision with icon
- [ ] **6.7.6** Report auto-saved to `.codex-collab/reports/codex-debate-exhaustion-<timestamp>.txt`
- [ ] **6.7.7** Report saved even when `status.auto_save: false` in config (forced for exhaustion events)
- [ ] **6.7.8** Report metadata includes `max_round_exhausted: true`, effective_max, user_choice, choice_status
- [ ] **6.7.9** Debate finishing before max rounds (e.g., consensus at round 3/5) does NOT trigger forced exhaustion summary
- [ ] **6.7.10** Verbose mode (`status.verbosity: verbose`) includes divergence_score and convergence_trend in summary

### 6.8 Max-Round Exhaustion Detection Logic ★

> `scripts/detect-exhaustion.sh` — Detects when a debate has reached its configured maximum rounds and triggers the exhaustion flow. Used by the orchestrator's round guard (step 4f).

- [ ] **6.8.1** `is_exhausted 5` returns exit 0 when `effective_max=5` (round == max → exhausted)
- [ ] **6.8.2** `is_exhausted 4` returns exit 1 when `effective_max=5` (round < max → not exhausted)
- [ ] **6.8.3** `is_exhausted 6` returns exit 0 when `effective_max=5` (round > max → exhausted)
- [ ] **6.8.4** `check_exhaustion 5 "false"` returns JSON with `next_action: "present_non_consensus_choices"` (exhausted, no consensus)
- [ ] **6.8.5** `check_exhaustion 5 "true"` returns JSON with `next_action: "present_consensus"` (exhausted, consensus reached)
- [ ] **6.8.6** `check_exhaustion 2 "true"` returns JSON with `next_action: "present_consensus"` and `exhausted: false` (early consensus)
- [ ] **6.8.7** `check_exhaustion 2 "false"` returns JSON with `next_action: "continue_round"` (mid-debate, not exhausted)
- [ ] **6.8.8** `detect_round_exhaustion` returns exit 0 when exhausted OR consensus (signals: exit round loop)
- [ ] **6.8.9** `detect_round_exhaustion` returns exit 1 when neither exhausted nor consensus (signals: continue loop)
- [ ] **6.8.10** `detect_round_exhaustion` preserves topic and session_id in JSON output
- [ ] **6.8.11** `format_exhaustion_notice` outputs `EXHAUSTION_DETECTED=true` and box UI when exhausted without consensus
- [ ] **6.8.12** `format_exhaustion_notice` outputs `EXHAUSTION_CONSENSUS=true` when consensus reached at max round
- [ ] **6.8.13** Additional rounds tracking: `additional_rounds_used` and `additional_rounds_remaining` correct at each round
- [ ] **6.8.14** CLI `--check` mode returns correct exit codes (0=exhausted, 1=not)
- [ ] **6.8.15** CLI `--notice` mode renders formatted exhaustion notice with markers
- [ ] **6.8.16** Orchestrator round guard (step 4f) uses `detect_round_exhaustion` instead of raw comparison

---

## 7. Safety Hooks

### 7.1 Hook Triggers

- [ ] **7.1.1** `--full-auto` flag in Codex invocation → warning about file modification risk
- [ ] **7.1.2** `--dangerously-bypass-approvals-and-sandbox` → **blocked** with exit code 2
- [ ] **7.1.3** Write-mode Codex invocation → alert before file modifications
- [ ] **7.1.4** Codex invoked without active session → session warning displayed

### 7.2 Safety-Hook Auto-Trigger ★

- [ ] **7.2.1** Safety hooks fire automatically on relevant operations (no manual setup needed)
- [ ] **7.2.2** Hook warnings always require user approval before proceeding
- [ ] **7.2.3** User can approve the warned operation → continues normally
- [ ] **7.2.4** User can reject the warned operation → operation is cancelled
- [ ] **7.2.5** Multiple hooks can fire on a single operation (e.g., write-mode + no-session)

### 7.3 Debate Topic Auto-Derivation from Hook Content ★

> **Script:** `scripts/safety-hook-topic.sh` — derives debate topics from safety hook detection content

- [ ] **7.3.1** Write-mode enforcement hook → topic contains "이 작업에서 파일 수정이 안전한가?" with user prompt summary
- [ ] **7.3.2** Full-auto mode warning hook → topic contains "Codex full-auto 모드의 위험성 평가" with operation context
- [ ] **7.3.3** Write flag hook (--write/--edit/-w) → topic contains "파일 변경 작업의 범위와 안전성 검토" with target files
- [ ] **7.3.4** Unknown/generic hook → topic falls back to "안전성 검토가 필요한 작업 (Safety review required)"
- [ ] **7.3.5** Prompt longer than 100 characters → truncated with "..." in derived topic
- [ ] **7.3.6** Command with file paths (e.g., `src/auth.py`) → file names included in topic (max 3 files)
- [ ] **7.3.7** Severity correctly detected from `[SEVERITY:level]` tags in hook output
- [ ] **7.3.8** Severity correctly detected from content patterns when tags absent (BLOCKED→critical, WRITE-MODE→caution)
- [ ] **7.3.9** Only caution and warning severities trigger debate proposals (not info or critical)
- [ ] **7.3.10** `safety.auto_trigger_hooks: false` in config → no debate proposals even on caution/warning hooks
- [ ] **7.3.11** Debate proposal display includes: severity, hook warning, topic, round info, Y/N/C options
- [ ] **7.3.12** `bash tests/test-safety-hook-topic.sh` passes all tests (59/59)

---

## 8. Rule Engine

### 8.1 Rule Loading

- [ ] **8.1.1** Rules load from `~/.claude/codex-rules.yaml` (global)
- [ ] **8.1.2** Rules load from `.codex-collab/rules.yaml` (project)
- [ ] **8.1.3** Project rule with same `name` overrides global rule entirely
- [ ] **8.1.4** Rules with unique names merge from both sources

### 8.2 Rule Evaluation

- [ ] **8.2.1** `notify` action displays message to user (no command execution)
- [ ] **8.2.2** `run` action executes the specified follow-up command
- [ ] **8.2.3** `run` action in write-mode requires user confirmation
- [ ] **8.2.4** Template variables interpolated correctly: `{confidence}`, `{summary}`, `{overall_quality}`
- [ ] **8.2.5** Array access works: `{issues[0].description}`, `{issues[?severity=='critical']}`

### 8.3 Recursion Guard

- [ ] **8.3.1** Rule chain at depth 1 → executes normally
- [ ] **8.3.2** Rule chain at depth 2 → executes normally
- [ ] **8.3.3** Rule chain at depth 3 → executes (max allowed depth)
- [ ] **8.3.4** Rule chain at depth 4 → **blocked** with "최대 깊이(3)에 도달했습니다" message

---

## 9. Auto Status Summary ★

- [ ] **9.1** After session end, a status summary is automatically generated
- [ ] **9.2** Summary includes: total commands run, evaluation findings, debate outcomes
- [ ] **9.3** Summary includes: session duration (created_at → ended_at)
- [ ] **9.4** Summary shows confidence trend across evaluations (if multiple)
- [ ] **9.5** Summary shows rule trigger count and actions taken
- [ ] **9.6** Summary is displayed to user (not just stored silently)
- [ ] **9.7** Empty session (no commands) → summary indicates "No activity recorded"

---

## 10. Fake Codex Mock (QA Infrastructure) ★

> Tests the `tests/fake-codex.sh` mock itself to ensure reliable test infrastructure.

### 10.1 Scenario Routing

- [ ] **10.1.1** `FAKE_CODEX_SCENARIO=session-start` → JSONL with session_id emitted, exit 0
- [ ] **10.1.2** `FAKE_CODEX_SCENARIO=session-resume` → output file written, no JSONL, exit 0
- [ ] **10.1.3** `FAKE_CODEX_SCENARIO=debate-round` → structured position JSON in output, exit 0
- [ ] **10.1.4** `FAKE_CODEX_SCENARIO=debate-consensus` → `agrees_with_opponent: true` in output, exit 0
- [ ] **10.1.5** `FAKE_CODEX_SCENARIO=evaluate` → structured evaluation JSON in output, exit 0
- [ ] **10.1.6** `FAKE_CODEX_SCENARIO=ask-readonly` → text response in output, exit 0
- [ ] **10.1.7** `FAKE_CODEX_SCENARIO=ask-write` → file modification summary in output, exit 0

### 10.2 Error Scenarios

- [ ] **10.2.1** `FAKE_CODEX_SCENARIO=error-auth` → stderr error message, exit 2
- [ ] **10.2.2** `FAKE_CODEX_SCENARIO=error-timeout` → delays then exits with error
- [ ] **10.2.3** `FAKE_CODEX_SCENARIO=error-empty` → empty output file, exit 0
- [ ] **10.2.4** `FAKE_CODEX_SCENARIO=error-crash` → stderr stack trace, exit 1

### 10.3 Argument Parsing

- [ ] **10.3.1** `-o /tmp/out.md` flag → output written to specified file
- [ ] **10.3.2** `--json` flag → JSONL emitted to stdout
- [ ] **10.3.3** `--output-schema` flag → schema-aware output
- [ ] **10.3.4** `--dangerously-bypass-approvals-and-sandbox` → blocked with exit 2
- [ ] **10.3.5** `FAKE_CODEX_SESSION_ID=custom-id` → session ID substituted in JSONL fixtures
- [ ] **10.3.6** `FAKE_CODEX_DELAY=2` → artificial 2-second delay before response

### 10.4 Fixture Files

- [ ] **10.4.1** `fixtures/session-start.jsonl` exists and contains valid JSONL
- [ ] **10.4.2** `fixtures/debate-round.jsonl` exists and contains valid JSONL
- [ ] **10.4.3** `fixtures/debate-consensus.jsonl` exists and contains valid JSONL
- [ ] **10.4.4** All fixtures use `{{SESSION_ID}}` placeholder for dynamic substitution

---

## 11. Integration Scenarios

> End-to-end flows combining multiple features.

### 11.1 Full Evaluate → Rule → Debate Flow

- [ ] **11.1.1** Start session → evaluate code → rule triggers auto-debate → debate completes → session history has both entries
- [ ] **11.1.2** Rule-triggered debate respects the 2 additional rounds maximum ★
- [ ] **11.1.3** Auto-triggered debate requires user approval before starting ★

### 11.2 Session Lifecycle with Auto-Creation

- [ ] **11.2.1** No session → `/codex-ask "question"` → auto-create prompt → accept → answer received → `/codex-session end` → summary shown
- [ ] **11.2.2** Session persists across multiple commands within same project
- [ ] **11.2.3** After session end, starting new session works correctly

### 11.3 Config + Rules Integration

- [ ] **11.3.1** Project config overrides debate max rounds → respected during debate
- [ ] **11.3.2** Global rules + project rule overrides → correct merged rule set evaluated
- [ ] **11.3.3** Config change (edit YAML) → picked up on next command (no restart needed)

### 11.4 Error Recovery Flows

- [ ] **11.4.1** Codex timeout on evaluate → 1 retry → still fails → error report displayed
- [ ] **11.4.2** Codex crash mid-debate round 3 → partial results (rounds 1-2) preserved and displayed
- [ ] **11.4.3** Corrupt session file → graceful recovery or re-init prompt

### 11.5 Caution+ Hook → Debate Proposal → User Confirmation → Debate Execution (E2E) ★

> End-to-end flow verifying that safety hooks automatically trigger debate proposals,
> user approval is always required, and the debate executes correctly after confirmation.

#### 11.5.1 Happy Path: Hook Fires → User Approves → Debate Completes

- [ ] **11.5.1.1** Trigger a write-mode `/codex-ask` with action keywords (e.g., "refactor auth module") → PreToolUse write-mode hook fires with caution+ warning
- [ ] **11.5.1.2** Hook warning message is displayed to user before any Codex invocation occurs
- [ ] **11.5.1.3** Workflow-orchestrator proposes a cross-model debate on the write operation's safety/approach
- [ ] **11.5.1.4** Debate proposal clearly states the topic (derived from the triggering operation)
- [ ] **11.5.1.5** User is prompted for explicit confirmation: "Proceed with debate?" (or equivalent)
- [ ] **11.5.1.6** User approves → debate begins with correct topic and context from the original operation
- [ ] **11.5.1.7** Debate executes full round loop (Codex position → Claude counter-position per round)
- [ ] **11.5.1.8** Debate completes (consensus or max rounds) → debate report displayed
- [ ] **11.5.1.9** After debate completion, the original write operation proceeds (or is re-evaluated based on debate outcome)
- [ ] **11.5.1.10** Both the hook event and debate result are recorded in session history

#### 11.5.2 Rejection Path: Hook Fires → User Declines → No Debate

- [ ] **11.5.2.1** Trigger write-mode operation → hook fires → debate proposed
- [ ] **11.5.2.2** User declines the debate → debate is NOT started (no Codex debate invocation)
- [ ] **11.5.2.3** Declining the debate does NOT block the original operation (user can still proceed with the write)
- [ ] **11.5.2.4** Decline event is logged in session history for auditability

#### 11.5.3 Full-Auto Hook → Debate Proposal

- [ ] **11.5.3.1** Codex invocation with `--full-auto` flag → full-auto hook fires with file modification risk warning
- [ ] **11.5.3.2** Orchestrator proposes debate on full-auto execution risks
- [ ] **11.5.3.3** User must explicitly approve before debate starts (never auto-starts)
- [ ] **11.5.3.4** Approved debate covers full-auto trade-offs; result informs whether to proceed

#### 11.5.4 Rule-Triggered Debate via Hook Chain

- [ ] **11.5.4.1** `/codex-evaluate` returns low confidence → rule-engine triggers debate proposal
- [ ] **11.5.4.2** Rule-triggered debate proposal still requires user confirmation (never auto-executes)
- [ ] **11.5.4.3** User approves → debate runs with maximum default rounds + 2 additional rounds cap
- [ ] **11.5.4.4** Total rounds in rule-triggered debate never exceed default + 2 (constraint enforced)
- [ ] **11.5.4.5** Debate result is passed back to rule-engine; cascade depth incremented
- [ ] **11.5.4.6** Rule-engine respects depth 3 limit — no further debates triggered beyond depth 3

#### 11.5.5 Multiple Hooks on Single Operation

- [ ] **11.5.5.1** Trigger operation that fires both write-mode hook AND no-session hook simultaneously
- [ ] **11.5.5.2** All hook warnings are displayed (not just the first one)
- [ ] **11.5.5.3** Session auto-creation resolves the no-session warning before debate proposal
- [ ] **11.5.5.4** Write-mode debate proposal appears after session is established
- [ ] **11.5.5.5** User approval is required once for the debate (not per-hook)

#### 11.5.6 Blocked Operation — No Debate Proposed

- [ ] **11.5.6.1** `--dangerously-bypass-approvals-and-sandbox` flag → operation blocked with exit code 2
- [ ] **11.5.6.2** No debate is proposed for blocked operations (block is immediate and final)
- [ ] **11.5.6.3** Block event is logged but no debate history entry is created

---

## 12. Regression Checks

> Verify existing v2.0.0 features still work after v2.1.0 changes.

- [ ] **12.1** `/codex-session start` manual flow unchanged — advanced users not impacted
- [ ] **12.2** `validate-plugin.sh` still passes all 37 structural checks
- [ ] **12.3** All 4 safety hooks still fire on their respective triggers
- [ ] **12.4** Cross-verifier still runs mandatorily on `/codex-evaluate`
- [ ] **12.5** Debate anti-anchoring protocol unchanged
- [ ] **12.6** Rule engine cascade depth limit still enforced at 3
- [ ] **12.7** Session history schema unchanged (backward compatible)
- [ ] **12.8** Codex CLI invocation patterns (`exec`, `resume`, `--json`, `-o`) unchanged

---

## Sign-Off

| Role | Name | Date | Result |
|------|------|------|--------|
| QA Tester | | | ☐ Pass / ☐ Fail |
| Developer | | | ☐ Reviewed |
| Reviewer | | | ☐ Approved |

**Total scenarios:** 190
**Pass:** ___
**Fail:** ___
**Blocked:** ___

---

*Generated for codex-collab v2.1.0 release QA*
