---
description: Ask OpenAI Codex a read-only question; optionally add Claude's own take.
argument-hint: <question>
---

Ask Codex the user's question in a strictly read-only sandbox, then present the answer.

1. Write the user's question ($ARGUMENTS) verbatim to a temp file, e.g. `/tmp/codex-collab-ask.$$.txt`.
2. Run (read-only is mandatory):

   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-client.mjs" turn \
     --sandbox read-only \
     --prompt-file /tmp/codex-collab-ask.$$.txt \
     --out /tmp/codex-collab-ask.$$.json
   ```
3. Read the `.json` `out` file and present Codex's `text` to the user under a "Codex" heading.
4. Optionally add a short "Claude's take" section with your own view, clearly separated. Never merge the two into one unattributed answer.

Never pass `--sandbox workspace-write` here. This command is read-only by contract.
