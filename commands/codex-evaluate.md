---
description: Cross-verify — Codex evaluates a target while Claude independently analyzes it, then compares.
argument-hint: <file-or-topic>
---

Use the codex-orchestrator agent to run a two-model cross-verification of $ARGUMENTS. The ordering is mandatory and enforced by these steps:

1. FIRST, produce your own independent (blind) analysis of the target and save it to `/tmp/codex-collab-blind.$$.md`. Do NOT call Codex yet.
2. THEN build a Codex prompt that contains ONLY the target and the evaluation task — it must NOT contain your analysis. Write it to `/tmp/codex-collab-eval.$$.txt`.
3. Run:

   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-client.mjs" turn \
     --sandbox read-only \
     --prompt-file /tmp/codex-collab-eval.$$.txt \
     --schema "${CLAUDE_PLUGIN_ROOT}/schemas/evaluation.json" \
     --out /tmp/codex-collab-eval.$$.json
   ```
4. Read Codex's `structured` output and compare it against your blind analysis. Present: your findings, Codex's findings, and where they agree/diverge.
