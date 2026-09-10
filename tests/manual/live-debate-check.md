# Authenticated debate protocol check

Run `node tests/manual/live-debate-check.mjs` from the repository root with a
logged-in Codex CLI. This is opt-in and consumes two model turns. The Claude-side
input is a deterministic arithmetic fixture, not another live model. Codex runs
read-only in a fresh temporary directory with no project editing task.

## Recorded result — 2026-09-10

- Codex CLI: 0.154.0.
- Round 1: completed, valid structured position, no blind-round consensus.
- Round 2: completed in the resumed thread; both votes accepted the same proposal.
- Both rounds persisted; consensus true and workflow completed.
- Observed `item/completed` for `agentMessage`: string `threadId` and `turnId`,
  `phase: "final_answer"`.
- Observed `turn/completed`: string thread/turn IDs, `status: "completed"`.
- Observed `thread/tokenUsage/updated`.

The script writes sanitized field shapes to `protocol-events.json` alongside the
round artifacts and prints their directory. It does not print credentials.

This validates the normal authenticated lifecycle and current output schema.
The run did not trigger retryable errors, interruption, commentary or permission
requests. Those branches remain covered by deterministic protocol-fake tests;
this result does not claim production fault injection or compatibility with all
future CLI versions.
