# codex-collab v3

[English](README.md) | **한국어**

Claude Code <-> OpenAI Codex 교차 모델 협업 — **debate(토론)**, **evaluate(교차 검증)**, **ask(질문)** — 안정적인 `codex app-server` JSON-RPC 프로토콜 위에서 동작합니다.

## 왜 v3인가

v3는 처음부터 다시 만든 버전입니다. 이전 버전은 `codex exec` 문자열을 셸로 실행하고 출력을 bash로 파싱했는데, CLI가 바뀌면 조용히 깨졌고 안전하지 않은 파일 적용 경로도 있었습니다. v3는 `codex app-server`와 직접 통신하고, 샌드박스를 프로그램 파라미터로 설정하며, 변경 적용은 Codex가 자기 샌드박스 안에서 하도록 맡깁니다. 그래서 한 부류의 결함이 아예 발생할 수 없습니다.

일상적인 리뷰·위임·백그라운드 작업에는 OpenAI 공식 플러그인(`openai/codex-plugin-cc`)을 쓰세요. codex-collab은 공식 플러그인이 다루지 않는 것, 즉 합의 판정이 있는 다회차 토론과 두 모델의 독립 교차 검증을 담당합니다.

## 요구 사항

- Claude Code
- Node.js >= 18.18
- OpenAI Codex CLI (`npm install -g @openai/codex` 설치 후 `codex login`)

## 설치

Claude Code에서:

```
/plugin marketplace add secucon/codex-collab
/plugin install codex-collab@codex-collab
```

`/plugin`으로 확인하면 아래 세 커맨드가 보여야 합니다. 로컬 체크아웃에서 설치하려면 `/plugin marketplace add /path/to/codex-collab`을 사용하세요.

## 커맨드

- `/codex-collab:ask <질문>` — Codex에 읽기 전용 질문을 하고, 선택적으로 Claude의 의견도 덧붙입니다.
- `/codex-collab:evaluate <대상>` — Claude가 블라인드로 분석하고, Codex가 독립적으로 평가한 뒤, 둘을 비교합니다.
- `/codex-collab:debate <주제>` — N회차 Claude<->Codex 토론. 결정론적 합의 판정과 승인 게이트가 있는 적용 단계를 포함합니다.

## 안전성

샌드박스는 코드에서 강제됩니다(기본 `read-only`, 승인된 적용 턴에서만 `workspace-write`). 위험한 플래그는 절대 만들어지지 않으며, 테스트로 강제됩니다. 모든 파일 쓰기는 Codex가 자기 샌드박스 안에서 수행합니다.

2026-08-16에 실제 Codex로 검증했습니다. `read-only`에서는 쓰기 요청이 거부되고 파일이 생성되지 않습니다. `workspace-write`에서는 작업 디렉터리 안의 쓰기는 성공하고, 밖의 경로 쓰기는 거부됩니다. 단, Codex의 `workspace-write` 정책은 `/tmp`와 `$TMPDIR` 쓰기도 허용합니다. 이는 작업 디렉터리만이 아니라 Codex 자체 샌드박스 정의이므로, "workspace-write"를 "cwd 전용"으로 여기지 마세요.

`status: "completed"`인 턴만 성공입니다. 실패·중단된 턴, 잘못된 JSON, 내장 출력 계약을 위반한 결과는 거부합니다. 합의는 두 모델이 동일한 합의안의 SHA-256을 명시적으로 승인했을 때만 성립하며, 서로 다른 이전 입장에 대한 동의는 합의로 취급하지 않습니다. 변경 적용에도 이 공통 합의안을 사용합니다.

정상 완료된 분석의 투표 필드에 오타나 불일치가 있으면 미승인으로 처리합니다. 라운드에 경고와 원본 투표를 기록하고 토론을 계속할 수 있습니다. 분석 본문 손상이나 통신 실패는 여전히 실행을 중단합니다.

실행마다 `.codex-collab/runs/` 아래 UUID 디렉터리를 생성합니다. Node가 토론 상태, 라운드 잠금, 스레드 재개, 최대 5라운드를 관리하며 각 실행의 `report.md`에 보고서를 저장합니다. 첫 라운드는 블라인드 분석이고 이후에는 동일한 후보 합의안을 검토합니다. 두 모델은 파일시스템 접근을 공유하므로 anti-anchoring은 행동 지침이며 파일 접근 격리를 뜻하지 않습니다.

이전 boolean 필드만 있는 토론 결과로는 새 스키마에서 합의가 성립하지 않습니다. 업그레이드 후 새 토론을 시작하세요. 기존 보고서는 유지됩니다.

## 성능 설정

`codex-client.mjs turn`과 `workflow.mjs round`에 `--model`, `--effort`를 지정할 수 있습니다. 결과에는 연결·스레드 시작/재개·턴 소요시간, 결과 생성까지의 총시간(종료 처리 제외), 프롬프트 바이트 수, 서버가 보고한 토큰 사용량을 기록합니다. 토큰 사용량이 제공되지 않으면 null이며, 요금 추정치는 아닙니다.

재개하는 토론 프롬프트는 Codex의 이전 답변을 반복하지 않고 새 후보 합의안을 전달합니다. 현재는 라운드마다 서버를 새로 시작하며 평가도 순차 실행합니다. 연결 재사용과 병렬 평가는 기록된 시간을 측정한 뒤 도입할 수 있습니다.

## 개발

`npm test`로 단위 테스트를 실행합니다(Codex 불필요 — 프로토콜 페이크를 사용).

`node tests/manual/live-debate-check.mjs`는 고정된 상대편 입력을 사용해 실제 인증된 Codex의 읽기 전용 턴 두 개를 실행합니다. 구조화 출력·스레드 재개·합의를 확인하고 임시 실행 디렉터리에 프로토콜 필드 형태를 기록합니다. 모델 사용량이 발생하며 `npm test`에는 포함되지 않습니다.

행(hang) 방지: JSON-RPC 요청은 30초, 서버가 수락한 턴은 10분 후 타임아웃됩니다(`CODEX_COLLAB_REQUEST_TIMEOUT_MS` / `CODEX_COLLAB_TURN_TIMEOUT_MS`로 조정). 타임아웃 시 턴 중단을 요청하며, 종료 시 필요하면 50ms 후 SIGTERM, 1초 후 SIGKILL을 보냅니다. `turn`/`check`는 연결 전에 실패 마커를 기록합니다. 비대화형 클라이언트는 권한·elicitation 요청을 거절하고 미지원 서버 요청에는 오류로 응답합니다.

CI는 Node 18/20/22/24 단위 테스트, 필수 Codex 0.154.0 카나리, 참고용 최신 CLI 카나리를 실행합니다. 핸드셰이크 이후의 명시적인 인증 오류만 허용하며 잘못된 파라미터와 타임아웃은 실패입니다. 인증 없는 카나리는 모델 출력이나 구조화 스키마 수락 여부를 검증하지 못합니다. 실패·중단된 토론은 멈춥니다. 이전 실행이 살아 있을 수 있는 동안 라운드 잠금을 삭제하지 마세요.
