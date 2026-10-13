---
description: 상태라인 사용법과 명령어를 보여준다
allowed-tools: Bash
---

상태라인 사용법을 한국어로 정리해서 보여준다. 아래 내용을 그대로 출력하되, 먼저
설치 여부를 확인해서 (`~/.claude/statusline.sh` 또는 `~/.claude/statusline.ps1` 존재)
설치돼 있지 않으면 `/statusline-install` 부터 안내할 것.

```
명령어
  /statusline-install   설치 · 재설치
  /statusline-roll      마스코트 뽑기 (하루 한 번)
  /statusline-today     지금 쓰고 있는 마스코트 확인
  /statusline-place     마스코트 위치 (right 아래 오른쪽 · left 아래 왼쪽 · above 위 · line 상태줄 끝)
  /statusline-mode      정보 줄 방식 (script 상태줄 스크립트 · app 플러그인이 직접, 스크립트 멈춤)
  /statusline-update    최신 버전으로 업데이트
  /statusline-help      이 도움말

터미널에서
  ~/.claude/mascot roll          뽑기
  ~/.claude/mascot               지금 마스코트
  sh ~/.claude/statusline.sh --help

읽는 법
  DIR    프로젝트 폴더        GIT   브랜치 (main·master 는 보라색)
  MODEL  쓰는 모델            CTX   컨텍스트 사용량 (실시간)
  5H     5시간 한도 + 남은 시간

마스코트
  기본 자리는 프롬프트 아래 오른쪽 (플러그인 설치 + 최신 Claude Code).
  그 밖에는 상태줄 끝에 나옵니다. /statusline-place 로 자리를 바꿉니다.
  어느 세션을 열어도 같은 얼굴, 작업 중·완료 직후·확인 요청·실패 때만 말합니다.
  작업 중에는 대사가 10초마다 바뀌고 넌센스 퀴즈도 냅니다. 등급이 높을수록 말을 잘합니다.

마스코트 뽑기
  커먼 40% · 언커먼 35% · 레어 18% · 유니크 6% · 레전드 1%
  얼굴은 51종이고 하나마다 영어 이름이 있습니다. 레전드는 테마색 무지개가 글자마다 반짝이며 흐릅니다.
  뽑기는 하루 한 번, 직접 돌립니다. 뽑기 전까지 지금 얼굴이 유지됩니다.

옵션 (~/.claude/settings.json 의 "env" 에 넣고 Claude Code 재시작)
  STATUSLINE_MASCOT=0      마스코트 숨기기
  STATUSLINE_TALK=0        얼굴만, 대사 없이
  STATUSLINE_SEVEN_DAY=1   주간(7일) 게이지 표시
  STATUSLINE_TRUE_COLOR=0  256색 터미널용
  NO_COLOR=1               색 전부 끄기
```
