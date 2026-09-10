# 변경 이력

[English](CHANGELOG.md) | **한국어**

## 3.1.1 — 2026-09-10

### 수정
- 합의는 두 모델이 같은 후보 제안의 SHA-256을 명시적으로 수락해야 성립합니다.
  두 모델이 입장을 맞바꾼 경우, 상대의 이전 입장에 대한 투표만으로는 더 이상
  합의가 되지 않습니다. position 스키마 3.1.1에 필수 필드 `accepted_proposal_id`가
  추가되었습니다(거부 또는 블라인드 라운드에서는 null). boolean만 있는 이전
  position은 합의를 성립시킬 수 없으므로, 업그레이드 후 새 debate를 시작하세요.
- 완료된 턴만 성공으로 처리합니다. 중단(interrupted)·실패한 턴과 유효하지 않은
  구조화 JSON은 error 결과가 되며, 번들된 position/evaluation 출력에는 로컬 도메인
  검증도 적용됩니다. check가 더 이상 중단된 턴을 정상으로 보고하지 않습니다.
- 완료된 position 출력에서 제안 투표가 잘못되었거나(malformed), 일관되지 않거나,
  오래된(stale) 경우에는 경고와 함께 "수락 안 함"으로 집계하고 원래 투표를
  보존합니다. 분석 본문 손상과 전송 실패는 여전히 실행을 중단시키지만, 투표
  오타는 그렇지 않습니다.
- 알림을 thread와 turn 기준으로 매칭하고, commentary보다 최종 답변을 우선하며,
  재시도 가능한 오류를 허용하고, 서버 요청에는 거절 또는 명시적 unsupported-method
  오류로 응답합니다. 한 클라이언트에서 겹치는 턴은 거부합니다.
- 종료 시 SIGTERM 후 SIGKILL로 시간을 제한하고, 타임아웃된 턴을 interrupt하며,
  보관하는 stderr 크기를 제한하고, 타임아웃과 라운드 제한 숫자를 검증합니다.
- 모든 커맨드에 UUID 실행 디렉터리를 부여합니다. debate 라운드는 배타 락을 사용하고,
  마지막 라운드를 포함해 중단 전에 상태를 원자적으로 저장합니다.
- CI가 명시적 인증 실패와 프로토콜 오류를 구분합니다. 0.154.0 고정 캐너리는 필수이고,
  최신 CLI 드리프트는 참고용으로 유지됩니다. 유닛 테스트 매트릭스가 Node 18, 20, 22,
  24를 포함합니다.
- `codexErrorInfo`가 `other`인 경우에도 실제 CLI의 명시적 자격 증명 누락 401 메시지를
  URL과 요청 메타데이터까지 포함해 인식합니다. 관련 없는 오류는 여전히 실패입니다.

### 변경
- 이제 Node가 `scripts/workflow.mjs`를 통해 debate 프롬프트를 만들고, 스레드를
  resume하고, 라운드를 채점·기록하며, 5라운드 상한을 강제합니다.
- resume된 debate 프롬프트에서 이미 저장된 Codex의 이전 응답을 제외합니다.
- CLI가 `--model`, `--effort`, `--run-id`를 받습니다. 결과에는 단계별 소요 시간,
  프롬프트 바이트 수, 턴 ID, 서버가 보고한 토큰 사용량(없으면 null)이 포함됩니다.
- 실행 결과와 리포트는 `.codex-collab/runs/<runId>/` 아래에 저장됩니다. 영구 연결과
  병렬 모델 평가는 지연 시간을 측정할 때까지 보류합니다.
- 인증된 2라운드 검사(결정적 Claude 측 fixture 사용)를 opt-in으로 추가했습니다.
  2026-09-10에 Codex 0.154.0에서 통과: 구조화 출력, 같은 스레드 resume, 공유 제안
  합의, 그리고 관측된 프로토콜 필드 형태.

## 3.1.0 — 2026-08-16

### 변경 (BREAKING — 커맨드 이름)
- 플러그인 이름이 이미 네임스페이스 역할을 하므로, 세 커맨드에서 중복되는
  `codex-` 접두사를 제거했습니다. `/codex-collab:codex-ask`는 "codex"를 두 번
  말하는 셈이었습니다.

  | 이전 | 이후 |
  | --- | --- |
  | `/codex-collab:codex-ask` | `/codex-collab:ask` |
  | `/codex-collab:codex-evaluate` | `/codex-collab:evaluate` |
  | `/codex-collab:codex-debate` | `/codex-collab:debate` |

  파일 이름과 그 이름을 언급하는 문장만 바뀌었고, 스크립트·스키마·프로토콜
  동작에는 영향이 없습니다. v3 아키텍처는 그대로이고 사용자가 입력하는 내용만
  바뀌므로 메이저가 아닌 마이너 버전으로 올렸습니다.

## 3.0.2 — 2026-08-16

실제 인증된 `codex`(CLI 0.147.0)에 대한 첫 검증입니다. 3.0.0부터 `tests/manual/`에
보류돼 있던 수동 검사 두 건을 모두 실행했고, 그때까지 도달하지 못했던 경로를
실제로 실행했습니다.

### 수정
- **실제 Codex에서 구조화 출력이 깨져 있었습니다.** `schemas/position.json`과
  `schemas/evaluation.json` 둘 다 `400 invalid_json_schema`로 거부되어
  `/codex-evaluate`와 `/codex-debate`가 단 한 턴도 완료할 수 없었습니다.
  `scripts/lib/schema.mjs`가 이제 전송 전에 스키마를 **메모리에서** 정규화합니다
  (`strictifySchema`): 비표준 최상위 `version`을 제거하고, 모든 object 노드에
  `additionalProperties: false`를 넣고, 모든 property 키를 `required`에 추가하고,
  선택 속성은 nullable로 바꿉니다. 디스크의 스키마는 그대로이며 사람이 읽는
  계약서 역할을 유지합니다.
- **`/codex-debate`가 합의에 도달할 수 없었습니다.** `agents/codex-orchestrator.md`가
  모든 라운드에 anti-anchoring 규칙을 적용해서 Codex가 Claude의 입장을 볼 수 없었고,
  `agrees_with_opponent`의 판단 대상이 없었습니다. 게이트는 양쪽 동의를 요구하는데
  말입니다. 이제 anti-anchoring은 1라운드에만 적용되고, 2라운드 이후는 상대의 이전
  입장을 그대로 전달합니다. 실제로 검증: 같은 2라운드 입장이 이전 프롬프트 형태에서는
  `consensus: false`, 새 형태에서는 `consensus: true`로 채점됩니다.
- **합의 게이트가 실패한 턴을 채점했습니다.** codex-client의 오류 마커
  (`status: "error"`, `structured: null`)를 `consensus.mjs`에 넣으면 평범한
  `"divergence N, continue"` 판정과 exit 0이 나와서, 크래시한 Codex 턴이 조용히
  debate 라운드가 될 수 있었습니다. 유일한 방어는 오케스트레이터가 확인을 잊지 않는
  것뿐이었습니다. 이제 `evaluateConsensus`는 어느 쪽이든 사용 불가한 position을
  거부하고, CLI는 작업 전에 pending 마커를 쓰고 exit 1로 종료하며, 채점 불가 라운드가
  루프를 돌게 하지 않고 멈추도록 `capReached: true` 중단 마커를 남깁니다.
- `strictifySchema`가 이제 `anyOf`/`oneOf`/`prefixItems`와 `$defs`/`definitions`를
  순회하고, `properties`를 선언하지 않은 object 노드를 닫고, `required`를 정확히
  property 키 집합으로 정규화하며(중복과 대응 property가 없는 항목 제거), `$ref`,
  `anyOf`/`oneOf`, 타입 없는 `enum` 속성에 nullable을 표현할 수 있습니다. 이전에는
  이들이 모두 required이면서 nullable이 아닌 상태가 되었습니다.
- **`strictifySchema`는 정규화할 수 없는 것을 조용히 바꾸지 않고 거부합니다.**
  두 가지 재작성(object 닫기, 선택 속성을 required-but-nullable로 승격)은 일반
  `properties`/`items`/union 위치에서만 의미를 보존합니다. applicator 안에서는 스키마가
  *매칭하는 대상*이 바뀝니다: 모든 `allOf` 분기를 닫으면 서로 다른 분기의 교집합이
  만족 불가능해지고, `if` 안에서 `required`를 강제하면 키가 없을 때 조건이 뒤집힙니다.
  그래서 `allOf`, `not`, `if`/`then`/`else`, `contains`, `propertyNames`,
  `patternProperties`, `dependentSchemas`, `dependencies`, `unevaluated*`,
  `additionalItems`, `contentSchema`는 이제 문제 경로와 함께 throw합니다. 스키마 값을
  가진 `additionalProperties`(이전에는 `false`로 덮어써서 "문자열 값을 가진 아무 키"를
  "키 없음"으로 좁혔음)와, 넓힐 `type`/`$ref`/`anyOf`/`enum`이 없는 선택 속성(이전에는
  required이면서 non-nullable이 됨)도 마찬가지입니다.
- **debate 스펙이 Bash 호출 사이에 살아남지 않는 셸 상태에 의존했습니다.**
  `agents/codex-orchestrator.md`가 `${codex_thread_id:+--resume "$codex_thread_id"}`와
  `--round "$round"`를 사용했는데, 어느 단계도 이 변수를 할당하지 않았습니다. 그대로
  붙여 넣으면 빈 문자열로 확장되어 `--resume`이 조용히 사라지고 매 라운드 새 Codex
  스레드가 시작됐습니다. 오류도 없고 연속성도 없었습니다. 이제 모든 스니펫이 리터럴
  값을 사용하고, 스레드 id는 이전 라운드의 `-codex.json`에서 읽으며, 커맨드/에이전트
  bash 스니펫이 `CLAUDE_PLUGIN_ROOT` 외의 변수를 참조하면 테스트가 빌드를 실패시킵니다.
- 실제 에이전트로 루프를 끝까지 돌려서 찾은 그 밖의 debate 스펙 결함: 2라운드 이후
  프롬프트가 Claude position 파일에는 없는 `structured` 키를 가리켰고(Codex 출력
  파일만 래핑됨), 라운드별 임시 경로에 라운드 번호는 있지만 debate id가 없어서 두 번째
  debate가 첫 번째의 아티팩트를 덮어썼고, 상태 파일 형태는 선언됐지만 어느 단계도
  쓰지 않았고, 리포트 디렉터리는 생성되지 않았으며 리포트 파일명은 지정되지 않았고,
  1라운드의 "주제만(topic ONLY)"이 중립적 지시조차 금지했습니다. 모두 이제 명시되어
  있습니다.
- 스펙에 문서화: 양쪽은 상대의 *이전* 입장에 대해 `agrees_with_opponent`를 답하므로,
  실제 상호 동의는 발생한 다음 라운드에야 게이트에 보입니다. 그리고 `divergence`는
  양쪽이 수렴하는 동안에도 올라갈 수 있으므로 수렴 지표로 제시해서는 안 됩니다.

### 실제 Codex로 검증 (2026-08-16)
- `thread/resume`이 별개의 app-server 프로세스 사이에서도 스레드를 **실제로**
  resume합니다(`tests/manual/resume-check.md` → PASS). 라운드마다 무상태인 설계는
  유효하며, 트랜스크립트 전달 fallback은 필요 없습니다.
- STRICT 모드가 `minimum`/`maximum`을 **허용합니다**.
  `tests/manual/schema-acceptance-check.md`의 세 번째 가설은 틀렸습니다.
  `evaluation.confidence`의 0..1 계약을 유지하기 위해 숫자 범위 키워드는 의도적으로
  보존합니다.
- `$defs` + `$ref`, `anyOf` union, 타입 없는 `enum`, `properties` 없는 object,
  `minimum`/`maximum` 범위를 사용하는 스키마가 정규화 후에는 **허용**되고 정규화
  전에는 **거부**됩니다(`400 invalid_json_schema`). 즉 정규화기는 장식이 아니라 실제로
  필요한 부품입니다.
- apply 게이트가 문서대로 동작합니다: `workspace-write`에서 작업 디렉터리 안 쓰기는
  성공하고 밖 쓰기는 거부되며, `read-only`에서는 파일이 생성되지 않습니다. Codex의
  `workspace-write` 정책은 `/tmp`와 `$TMPDIR`도 허용합니다. README의 Safety 섹션을
  참고하세요.

### 알려진 제한
- `$ref` 대상은 해석하거나 인라인하지 않습니다. 로컬 `$ref`는 `$defs`/`definitions`가
  자체적으로 순회되기 때문에 정규화될 뿐이며, 문서 밖을 가리키는 ref는 그대로 둡니다.
  키워드를 순회한다고 해서 STRICT 모드가 그 키워드를 *지원*하게 되는 것도 아닙니다.
- `consensus.mjs`는 자유 텍스트 `key_points`의 정확한 문자열 집합 차이를 `divergence`로
  보고하므로 거의 항상 `|a| + |b|`이고 쓸 만한 신호가 없습니다. 참고용일 뿐 루프를
  게이트하지 않습니다.

## 3.0.1 — 2026-08-10

강화 후속 조치: 행(hang)과 오래된 출력 보호.

### 수정
- 멈춘 app-server가 더 이상 클라이언트를 멈추게 하지 못합니다. JSON-RPC 요청은 타임아웃되고(기본 30초), 승인된 턴도 `turn/completed` 없이 타임아웃됩니다(기본 10분). `CODEX_COLLAB_REQUEST_TIMEOUT_MS` / `CODEX_COLLAB_TURN_TIMEOUT_MS`로 재정의할 수 있습니다.
- 실패한 핸드셰이크가 더 이상 spawn된 app-server 프로세스를 누수시키지 않습니다.
- `turn`/`check`가 작업 전에 `--out`에 pending 실패 마커를 쓰므로, 종료된 프로세스(예: 호출자 측 타임아웃)가 이전 실행 결과를 새 결과처럼 남길 수 없습니다. `/codex-ask`의 오래된 답변 창이 닫혔습니다.
- 로컬 입력 오류(프롬프트 파일 누락, 잘못된 스키마나 샌드박스)도 이제 `--out`을 오래된 상태로 두지 않고 오류 마커를 씁니다.

## 3.0.0 — 2026-08-10

`codex app-server` JSON-RPC 프로토콜 위에서 처음부터 다시 만들었습니다.

### Breaking
- v2.2의 bash/python 구현 전체, 규칙 엔진, 안전 훅, 이름 붙은 세션 저장소를 제거했습니다.
- Codex를 이제 `codex exec` 문자열이 아니라 `codex app-server`(JSON-RPC)로 호출합니다.

### 추가
- 프로그램적으로 샌드박스를 선택하는 `codex-client.mjs` app-server 클라이언트(기본 read-only).
- 결정적 합의 게이트(`consensus.mjs`). 모델의 자체 판단을 대체합니다.
- 실제 `@openai/codex`에 대한 CI 드리프트 캐너리. 프로토콜 변경이 이제 빌드를 실패시킵니다.
- 구조적 anti-anchoring(Codex 프롬프트가 구성상 Claude의 분석을 제외).

### 수정 (v2.2 대비 제거된 결함 부류)
- 작업 디렉터리 밖 임의 파일 쓰기(플러그인 측 파일 apply가 더 이상 없음).
- 깨진 롤백 / stash된 사용자 작업(Codex가 자기 샌드박스 안에서 apply).
- 죽은 안전 훅(안전은 이제 훅 matcher가 아니라 코드 파라미터).
- 조용한 CLI 드리프트(캐너리 + 프로토콜 클라이언트).
