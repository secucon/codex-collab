---
name: codex-invocation
description: Use when Claude needs to invoke the Codex CLI, delegate a task to Codex (GPT-5.4), or run a codex command. Provides correct invocation patterns, flags, output handling, and error recovery.
---

# Codex CLI Invocation Guide

## Binary Location

```bash
$(command -v codex)
```

Resolved dynamically. Ensure `codex` is in your PATH. Auth is handled automatically via OAuth (chatgpt mode). No API key is needed.

## Core Invocation Pattern

```bash
CODEX=$(command -v codex)
OUTPUT=/tmp/codex-collab-$(date +%s).md

$CODEX exec \
  -o "$OUTPUT" \
  -C "$(pwd)" \
  -s read-only \
  "Your prompt here"

# Then use the Read tool to read $OUTPUT for Codex's response
```

## Key Flags

| Flag | Purpose | When to Use |
|------|---------|-------------|
| `-o <file>` | Write final message to file | Always (clean output capture) |
| `-C <dir>` | Set working directory | Always (match current project) |
| `-s read-only` | Read-only sandbox | Default for analysis/review |
| `-s workspace-write` | Allow file writes | When Codex needs to modify files |
| `--full-auto` | Shorthand for `-a on-request -s workspace-write` | When delegating file-modifying tasks (sandboxed) |
| `--ephemeral` | No session persistence | One-shot tasks only (NOT default in v2) |
| `-m <model>` | Override model | When specific model is needed |
| `--json` | JSONL output to stdout | When intermediate events are needed |
| `--output-schema <schema>` | Structured JSON response | When structured data is needed |

## Session Management Flags

| Flag | Purpose | When to Use |
|------|---------|-------------|
| `resume <session_id>` | Resume an existing session | Multi-turn conversations |
| `fork <session_id>` | Fork a session into a new branch | Exploring alternative directions |

### Resume Example
```bash
$CODEX exec resume <SESSION_ID> \
  -o "$OUTPUT" \
  -C "$(pwd)" \
  "Follow-up prompt"
```

### Fork Example
```bash
$CODEX exec fork <SESSION_ID> \
  -o "$OUTPUT" \
  -C "$(pwd)" \
  "Try a different approach"
```

## Structured Output with --output-schema

Request structured responses by providing a JSON Schema:

```bash
$CODEX exec \
  -o "$OUTPUT" \
  -C "$(pwd)" \
  -s read-only \
  --output-schema '{
    "type": "object",
    "properties": {
      "issues": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "severity": {"type": "string", "enum": ["low","medium","high","critical"]},
            "file": {"type": "string"},
            "line": {"type": "integer"},
            "description": {"type": "string"}
          }
        }
      },
      "confidence": {"type": "number", "minimum": 0, "maximum": 1},
      "summary": {"type": "string"}
    }
  }' \
  "Review this code for issues"
```

The response in the output file will be valid JSON matching the schema.

## Invocation Modes

### Read-Only (Default — Analysis, Review, Opinion)
```bash
$CODEX exec -o "$OUTPUT" -C "$(pwd)" -s read-only "prompt"
```

### File-Modifying (Task Delegation — sandboxed workspace-write)
```bash
$CODEX exec -o "$OUTPUT" -C "$(pwd)" --full-auto "prompt"
```
> `--full-auto`는 완전 자율 모드가 아닌 `-a on-request --sandbox workspace-write`의 축약형입니다.

### Code Review
```bash
$CODEX exec review --uncommitted -o "$OUTPUT" -C "$(pwd)"
$CODEX exec review --base main -o "$OUTPUT" -C "$(pwd)"
```

## Output Handling

1. Always use `-o <file>` to capture Codex's final response
2. Use the Read tool to read the output file after Codex completes
3. The `-o` flag gives only the clean final message, not intermediate JSONL noise
4. Present results with attribution: "**Codex (GPT-5.4) 응답:**"
5. For `--output-schema` responses, parse as JSON for structured handling

## Error Handling

| Error | Detection | Recovery |
|-------|-----------|----------|
| Auth failure | stderr contains "auth" or "login" | Suggest `codex login` |
| Timeout | Bash timeout (300s) exceeded | 1 retry, then partial completion |
| Empty output | Output file is empty or missing | Check stderr, 1 retry |
| Non-zero exit | Exit code ≠ 0 | Report stderr to user |

## Timeout

Set Bash tool timeout to `300000` (5 minutes) for complex tasks. Codex operations can take time, especially with large codebases.

## Security Rules

1. **NEVER** use `--dangerously-bypass-approvals-and-sandbox`
2. Default to `-s read-only` unless file writes are explicitly needed
3. Always pass `-C` with the current project directory
4. Output files go to `/tmp/` only, never into the project tree
