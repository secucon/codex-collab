---
description: Ask OpenAI Codex a read-only question; optionally add Claude's own take.
argument-hint: <question>
---

Ask Codex the user's question in a strictly read-only sandbox, then present the answer.

Use stable paths under the gitignored `.codex-collab/tmp/ask/` directory — NOT `$$`-based paths, whose PID differs between separate Bash calls so the later read would miss the file. Run `mkdir -p .codex-collab/tmp/ask` first.

1. Write the user's question ($ARGUMENTS) verbatim to `.codex-collab/tmp/ask/prompt.txt`.
2. Run (read-only is mandatory):

   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-client.mjs" turn \
     --sandbox read-only \
     --prompt-file .codex-collab/tmp/ask/prompt.txt \
     --out .codex-collab/tmp/ask/answer.json
   ```
3. Read `.codex-collab/tmp/ask/answer.json`. If its `status` is `"error"`, report the `error` field to the user and stop — do not present `text`. Otherwise present Codex's `text` under a "Codex" heading.
4. Optionally add a short "Claude's take" section with your own view, clearly separated. Never merge the two into one unattributed answer.

Never pass `--sandbox workspace-write` here. This command is read-only by contract.
