---
description: Codex 협업 세션을 관리합니다 (start|end|delete|list)
argument-hint: <start <name>|end|delete <id>|list>
---

# Codex Session Management

Codex 협업 세션의 생명주기를 관리합니다. 모든 codex-collab 커맨드는 활성 세션 안에서만 동작합니다.

## Subcommands

### `start <name>`
새 세션을 시작합니다.

```
/codex-session start 리팩토링 작업
/codex-session start auth 모듈 개선
```

- 현재 프로젝트에 활성 세션이 이미 있으면 에러 (먼저 `end`로 종료 필요)
- 세션 ID가 생성되어 반환됩니다

### `end`
현재 활성 세션을 종료합니다.

```
/codex-session end
```

- 세션 데이터는 보존됩니다 (삭제하려면 `delete` 사용)
- 종료된 세션의 이력은 계속 조회 가능

### `delete <id>`
세션과 그 데이터를 영구 삭제합니다.

```
/codex-session delete codex-1710400000-a1b2
```

### `list`
현재 프로젝트의 세션 목록을 표시합니다.

```
/codex-session list
```

출력 예시:
```
| ID                      | Name         | Status | Created    | Interactions |
|-------------------------|--------------|--------|------------|--------------|
| codex-1710400000-a1b2   | 리팩토링 작업 | active | 2026-03-14 | 5            |
| codex-1710300000-c3d4   | 버그 수정     | ended  | 2026-03-13 | 3            |
```

## Storage

세션 데이터는 `~/.claude/codex-sessions/`에 JSON으로 저장됩니다.
프로젝트 경로가 메타데이터로 포함되어 프로젝트별 필터링이 가능합니다.

## Auto Status Summary

모든 서브커맨드 완료 후, config의 `status.auto_summary`가 `true`(기본값)이면 자동으로 상태 요약을 출력합니다:

```
[codex-collab] ✓ Session started: "리팩토링 작업"
[codex-collab] Status Summary
─────────────────────────────
📋 Session: "리팩토링 작업" (active) | Participants: Claude | Interactions: 0
⚡ No recent actions
📊 Total: 0 interactions | 1 active, 0 ended sessions
```

`status.auto_summary: false`로 설정하면 상태 요약이 비활성화됩니다.

## Routing

이 커맨드는 `workflow-orchestrator` → `session-manager`로 라우팅됩니다.
