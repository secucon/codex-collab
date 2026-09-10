---
description: Cross-verify — Codex evaluates a target while Claude independently analyzes it, then compares.
argument-hint: <file-or-topic>
---

Use the codex-orchestrator agent to cross-verify $ARGUMENTS.

1. Allocate a fresh run:

   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/workflow.mjs" init --kind evaluate
   ```

   Read the returned dir and runId and substitute their literal values below. Never reuse another invocation's directory or depend on shell variables across calls.

2. Produce your independent blind analysis and save it to <dir>/blind.md before seeing Codex's output.
3. Write <dir>/prompt.txt containing only the target, evaluation task, and an instruction not to read .codex-collab collaboration artifacts. Exclude your analysis and conclusions. Both agents share filesystem access: this is a behavioral anti-anchoring rule, not a security boundary.
4. Run:

   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-client.mjs" turn \
     --sandbox read-only --run-id "<runId>" \
     --prompt-file "<dir>/prompt.txt" \
     --schema "${CLAUDE_PLUGIN_ROOT}/schemas/evaluation.json" \
     --out "<dir>/eval.json"
   ```

5. Read <dir>/eval.json. Require status === "completed", the expected runId, and non-null structured. On failure, report the error and stop. Otherwise compare with your saved blind analysis. Present each model's findings and their agreement/disagreement, and save <dir>/report.md.

If the user selects a model or reasoning effort, pass --model / --effort.
