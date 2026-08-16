---
description: Cross-verify — Codex evaluates a target while Claude independently analyzes it, then compares.
argument-hint: <file-or-topic>
---

Use the codex-orchestrator agent to run a two-model cross-verification of $ARGUMENTS. The ordering is mandatory and enforced by these steps.

Use stable paths under the gitignored `.codex-collab/tmp/evaluate/` directory — NOT `$$`-based paths, whose PID differs between separate Bash calls so the later read would miss the file. Run `mkdir -p .codex-collab/tmp/evaluate` first.

1. FIRST, produce your own independent (blind) analysis of the target and save it to `.codex-collab/tmp/evaluate/blind.md`. Do NOT call Codex yet.
2. THEN build a Codex prompt that contains ONLY the target and the evaluation task — it must NOT contain your analysis. Write it to `.codex-collab/tmp/evaluate/prompt.txt`.
3. Run:

   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-client.mjs" turn \
     --sandbox read-only \
     --prompt-file .codex-collab/tmp/evaluate/prompt.txt \
     --schema "${CLAUDE_PLUGIN_ROOT}/schemas/evaluation.json" \
     --out .codex-collab/tmp/evaluate/eval.json
   ```
4. Read `.codex-collab/tmp/evaluate/eval.json` and compare Codex's `structured` output against your blind analysis. Present: your findings, Codex's findings, and where they agree/diverge.
