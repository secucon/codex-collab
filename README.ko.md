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

합의 게이트는 실패한 턴을 채점하지 않습니다. 어느 쪽이든 `status: "error"`이거나 `structured`가 없으면 0이 아닌 코드로 종료하고 중단 마커를 씁니다. 그래서 크래시된 Codex 턴이 조용히 토론 회차로 둔갑할 수 없습니다.

## 개발

`npm test`로 단위 테스트를 실행합니다(Codex 불필요 — 프로토콜 페이크를 사용).

행(hang) 방지: JSON-RPC 요청은 30초, 승인된 턴은 `turn/completed` 없이 10분이 지나면 타임아웃됩니다(`CODEX_COLLAB_REQUEST_TIMEOUT_MS` / `CODEX_COLLAB_TURN_TIMEOUT_MS`로 조정). `turn`/`check`는 작업을 시작하기 전에 `--out`에 실패 마커를 먼저 쓰므로, 프로세스가 죽어도 이전 실행 결과가 새 결과처럼 읽히는 일은 없습니다. CI는 추가로 실제 Codex CLI에 대해 드리프트 카나리를 실행합니다. 클라이언트 생존 여부와 app-server 프로토콜/핸드셰이크 드리프트를 감지합니다(`initialize` 핸드셰이크는 인증이 필요 없으므로, 핸드셰이크가 깨지면 빌드가 실패합니다). 완전히 성공한 라이브 턴까지 단언하려면 CI에 Codex 인증이 필요하므로, 턴 수준의 인증 실패는 허용합니다.
