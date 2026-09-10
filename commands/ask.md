---
description: Ask OpenAI Codex a read-only question; optionally add Claude's own take.
argument-hint: <question>
---

Ask Codex the user's question in a read-only sandbox, then present its answer.

1. Allocate a fresh run:

   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/workflow.mjs" init --kind ask
   ```

2. Read the returned dir and runId. Write $ARGUMENTS verbatim to <dir>/prompt.txt. Substitute the returned literal values in every call; do not use shell variables across Bash calls or reuse another invocation's directory.

3. Run:

   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-client.mjs" turn \
     --sandbox read-only --run-id "<runId>" \
     --prompt-file "<dir>/prompt.txt" --out "<dir>/answer.json"
   ```

4. Read <dir>/answer.json. Require status === "completed" and the expected runId; otherwise report the error and stop. Present text under a "Codex" heading. Optionally add your own view, clearly attributed to Claude.

Never use workspace-write for ask. If the user selects a model or reasoning effort, pass --model / --effort.
