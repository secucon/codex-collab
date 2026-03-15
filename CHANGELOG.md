# Changelog

All notable changes to `codex-collab` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/).

---

## [2.2.0] - 2026-03-15

### Added
- **브랜치별 세션 격리**: 세션에 `branch` 필드 추가 — 같은 프로젝트 디렉토리에서 브랜치별 독립 세션 운영 가능
- **git remote 기반 프로젝트 식별**: `git_remote` 필드로 프로젝트 이동/이름 변경 시에도 세션 복구 가능 (credential 자동 제거)
- **Shell Injection 방지**: Rule Engine 템플릿 변수에 MANDATORY 새니타이제이션 규칙 추가 (`sanitize_template_value()` 함수, quote/hash 문자 포함)
- **Anti-Anchoring 강제**: Cross-Verifier에 Blind Phase / Comparison Phase 필수 섹션 헤더 + orchestrator 검증 로직 추가
- **활성 세션 인덱스**: `.active-sessions.json` 기반 O(1) 세션 조회 최적화 (atomic write 패턴)
- **GitHub Actions CI**: `.github/workflows/ci.yml` — plugin 검증, config 테스트, 스크립트 단위 테스트, E2E 시나리오 자동 실행
- **스키마 버전 관리**: 모든 JSON 스키마에 `version: "2.2.0"` 필드 추가 (하위 호환성 관리)

### Changed
- **Hook regex 강화**: 모든 matcher에 `\b` 단어 경계 추가 — 유사 명령 오탐 방지 (예: `codecx`, `codex-example`)
- **python3 미설치 대응**: `load-config.sh`에서 오류 대신 경고 + hardcoded 기본값 사용 (graceful degradation)
- **Config 캐싱**: `load_config()` 호출 시 프로젝트별 캐시 키 기반으로 중복 파싱 방지
- **세션 조회**: 3단계 폴백 — exact(project+branch) → legacy(branch 없는 세션) → remote(git remote URL 매치)
- `workflow-orchestrator`: Cross-Verifier Blind Phase 섹션 검증 로직 추가
- `session-manager`: branch/git_remote 필드 추가, 활성 세션 조회에 branch 조건 반영
- `session-auto-create.sh`: branch/git_remote 감지, 안전한 python3 호출 (sys.argv 기반)
- `-w` hook matcher: 마지막 토큰 케이스 대응 (`-w(\s|$)`)

### Security
- Rule Engine 템플릿에서 `'`, `"`, `#` 문자 제거하여 쉘 브레이크아웃 방지
- git remote URL 저장 시 credential 자동 제거 (userinfo stripping)
- GitHub Actions CI에 `permissions: { contents: read }` 최소 권한 적용
- Hook dangerous mode 패턴을 `--dangerously-bypass`로 정밀 매칭

---

## [2.1.0] - 2026-03-15

### Added
- **세션 자동 생성**: `/debate`, `/evaluate`, `/ask` 실행 시 세션 없으면 config 기본값으로 자동 생성 (`session.auto_create`)
- **프로젝트 설정 파일**: 2-tier config hierarchy — `~/.claude/codex-collab-config.yaml` (글로벌) + `.codex-collab/config.yaml` (프로젝트 오버라이드)
- **Safety 자동 트리거**: safety hook이 `caution` 이상을 감지하면 cross-model debate를 자동 제안 (사용자 승인 필수)
- **Debate 결과 처리**: 합의 시 diff + 근거 → 코드 자동 적용, 비합의 시 4개 선택지, 최대 라운드 소진 시 3개 선택지 + 강제 리포트
- **자동 상태 요약**: 매 커맨드 실행 후 3-5줄 상세 상태 출력 (PostToolUse hook)
- **리포트 자동 저장**: debate 리포트를 `.codex-collab/reports/`에 자동 저장 (confidence 점수 포함)
- **Fake Codex mock**: `tests/fake-codex.sh` — 시나리오별 JSONL fixture로 Codex CLI를 모킹
- **자동 시나리오 테스트**: `tests/run-scenarios.sh` — happy path, resume chain, rule cascade, error recovery
- **수동 체크리스트**: `tests/manual-checklist.md` — 실제 Codex CLI 기반 수동 QA
- **신규 스크립트 14개**: load-config, session-auto-create, safety-hook-topic, status-summary, debate-result-handler, detect-non-consensus, detect-exhaustion, display-consensus-result, display-non-consensus-choices, debate-result-approval, apply-changes, compose-report, debate-report, debate-round-cap
- **신규 스키마 3개**: `config.json`, `debate-report.json`, `approval-result.json`

### Changed
- `workflow-orchestrator`: 규칙 엔진 통합, safety 자동 트리거, 세션 자동 생성 흐름 추가
- `session-manager`: Auto-Create 섹션 추가 (`auto_created: true` 필드)
- `hooks.json`: PostToolUse 자동 상태 요약 hook 추가 (총 5개 hook)
- 모든 커맨드: 세션 없을 때 자동 생성 또는 안내 로직 업데이트

---

## [2.0.0] - 2026-03-14

### Breaking Changes
- v1의 모든 커맨드를 제거하고 행위 기반 4개 커맨드로 재설계
- 세션 필수: 모든 커맨드가 세션 안에서만 동작 (v2.1에서 자동 생성으로 완화)

### Added
- **세션 시스템**: `session-manager` 에이전트, `/codex-session` 커맨드, `~/.claude/codex-sessions/` 저장소
- **`/codex-ask`**: `/codex` + `/codex-opinion` 통합, read/write 모드 자동 판단
- **`/codex-evaluate`**: `/codex-review` + `/codex-verify` 통합, `--output-schema` 구조화 결과, `cross-verifier` 필수 교차 검증
- **`/codex-debate`**: Claude↔Codex 자동 토론, 최대 5라운드, 조기 합의 종료, 앵커링 방지 프로토콜
- **`workflow-orchestrator`**: 모든 커맨드의 상위 오케스트레이터 (계층적 에이전트 조율)
- **`rule-engine`**: 조건-액션 규칙 평가, 자동 후속 커맨드 실행 (depth 3 guard)
- **`schema-builder` skill**: `--output-schema` JSON Schema 동적 생성 가이드
- **`session-management` skill**: 세션 CRUD 로직 가이드
- **Canonical schemas**: `schemas/evaluation.json`, `schemas/debate.json`
- **Session ID Capture**: `codex-delegator`가 `--json`으로 Codex session ID 캡처, Return Contract 정의
- **검증 스크립트**: `scripts/validate-plugin.sh` (37 checks)
- **규칙 예제**: `docs/rules.yaml.example`
- **규칙 파일 2-tier**: `~/.claude/codex-rules.yaml` (글로벌) + `.codex-collab/rules.yaml` (프로젝트)

### Changed
- `codex-delegator`: 순수 CLI 호출로 축소 (프롬프트/스키마는 orchestrator에서 전달)
- `codex-invocation` skill: `resume`, `fork`, `--output-schema`, `--json` 플래그 문서 추가
- `cross-verifier`: `/codex-evaluate` 파이프라인의 필수 교차 검증 단계로 재정의
- Safety hooks: 4개로 확장 (write-mode enforcement, 프로젝트별 세션 체크 추가)

### Removed
- `/codex` → `/codex-ask`로 대체
- `/codex-opinion` → `/codex-ask`로 흡수
- `/codex-review` → `/codex-evaluate`로 대체
- `/codex-verify` → `/codex-evaluate`로 대체

---

## [1.1.0] - 2026-03-13

### Added
- Safety hooks: `--full-auto` 경고, `--dangerously-*` 차단
- `codex-invocation` skill: CLI 호출 패턴, 플래그, 에러 처리 가이드
- `codex-delegator` agent: 작업 위임 오케스트레이션
- `cross-verifier` agent: 크로스 모델 검증
- `/codex`: Codex CLI에 작업 위임
- `/codex-review`: Codex 내장 코드 리뷰
- `/codex-verify`: Claude 작업의 독립 검증
- `/codex-opinion`: 세컨드 오피니언 요청

### Notes
- 최초 공개 버전
- 모든 호출이 `--ephemeral` 일회성
- 앵커링 바이어스 방지가 핵심 설계 원칙
