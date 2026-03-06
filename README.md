# Daily Mafia / GUILNOCENT (Flutter + Node.js Server)

모바일(Flutter) + WebSocket 서버(Node.js) 기반의 실시간 멀티플레이 마피아 게임입니다.
현재는 **오리지널 마피아**와 **Moral Roulette** 2개 모드를 지원합니다.

## 구성

- `game_server`: Node.js WebSocket 서버
- `app_client`: Flutter 모바일 앱

## 구현된 핵심 기능

- 방 생성/입장/퇴장, 공개 로비 목록/검색/새로고침
- 공용 서버(`wss`) + LAN 서버(`ws`) 연결, LAN 자동 탐색(UDP)
- 실시간 채팅(WebSocket), 이모지 퀵 채팅
- 역할 시스템: 시민 / 마피아 / 의사 / 경찰 / 조커(시민 편)
- 게임 페이즈: 대기 → 밤 능력 → 처형 투표 → 처형 찬반 → (모드별) 진행
- 인게임 모달 UI: 개인 로그 / 유저 목록 / 도움말 / 게임 설정
- 게임 모드 설정: `original`, `moral_roulette`
- 점수 설정 동기화: `mafiaJoker2Plus`, `mafiaJoker1`, `mafiaJoker0`, `citizenEndMultiplier`
- 서버-클라 규칙 버전 표시(`rulesVersion`) 및 연결 시 버전 경고

## 최근 업데이트 내역 (2026-03-06)

### 1) 룰/게임 진행 고도화

- 모드별 진행 규칙 정교화 (오리지널 / Moral Roulette)
- Moral Roulette 점수/종료 규칙 강화
  - 마피아 생존 점수 구간(조커 2+/1/0)
  - 시민 편 종료 보너스 배수 적용
  - 2마피아→1마피아 전환 턴 예외 처리
  - 3인(시민편2+마피아1)에서 1:1 성립 시 자동 종료(+10)
- 경찰 조사 결과를 **직업 전체 공개가 아닌 “마피아 여부”만** 전달하도록 변경
- 조커는 위장 직업으로 행동 가능하지만 실제 효과는 없는 규칙 명확화

### 2) 서버 메시지/프로토콜 확장

- 채팅 패킷 확장:
  - `imageAsset`: 시스템 결과 이미지를 클라에서 표시
  - `highlightDanger`: 위험/핵심 로그 강조 표시
- 개인 전용 시스템 로그/피드백 강화 (`ability_log` 및 private system chat)
- 능력 결과 및 투표 결과를 **이미지 메시지 + 텍스트 메시지 분리** 전송으로 개선
  - 예: `doctor_success.png`, `mafia.png`, `execution.png`
- 최종 점수 요약에 실제 직업 표기 반영
  - `플레이어명 (직업) - 점수`

### 3) 클라이언트 UI/UX 개선

- 인룸 화면을 채팅 중심으로 단순화하고 조작을 상단 모달로 분리
- 유저 목록을 격자(Grid) 버튼으로 제공하고 투표 선택 UX 개선
- 채팅 렌더러 개선:
  - 이미지 에셋 표시 (`Image.asset`)
  - 키워드/위험 로그 색상 강조
  - 시스템/개인 로그 가독성 향상
- 조커 인게임 역할 표시는 실제 역할이 아닌 **위장 직업 라벨**로 표시

### 4) 레이아웃 밀도(간격) 최적화

- 모달/로비/인룸 전반의 상하 여백, 패딩, 컴포넌트 간격 축소
- 채팅 버블 마진/패딩 축소로 스크롤 효율 개선
- 이모지 버튼 크기/간격 축소로 한 화면 정보량 증가
- 불필요한 세로 공백 최소화로 모바일 사용성 개선

### 5) 에셋/클라이언트 설정

- `app_client/pubspec.yaml`에 `image/` 에셋 등록
- 시스템 로그용 이미지 사용: `mafia.png`, `doctor_success.png`, `police.png`, `execution.png` 등

## 서버 실행

```bash
cd game_server
npm install
npm start
```

기본 포트: `8080`

## 앱 실행

```bash
cd app_client
flutter pub get
flutter run
```

앱 상단의 서버 주소를 `ws://<PC의-로컬-IP>:8080` 형태로 입력하세요.

예시:

- `ws://192.168.0.10:8080`

## 휴대폰에서 접속하려면

1. PC와 휴대폰을 **같은 Wi-Fi**에 연결
2. 서버를 PC에서 실행
3. Windows 방화벽에서 Node.js 또는 8080 포트 허용
4. 앱에서 서버 주소를 PC의 로컬 IP로 입력

## 원거리(인터넷) 플레이 배포

### 1) Render에 서버 배포

루트의 `render.yaml`을 사용해 Web Service를 생성하면 됩니다.

- 서비스 루트: `game_server`
- 빌드: `npm ci`
- 시작: `npm start`
- 포트: Render가 `PORT` 환경변수로 자동 주입

### 2) 공용 WebSocket 주소 확인

배포 후 예시:

- `https://daily-mafia-server.onrender.com/health`
- WebSocket 주소: `wss://daily-mafia-server.onrender.com`

### 3) 앱에서 서버 주소 기본값으로 빌드

`SERVER_WS_URL`을 주입해서 앱 기본 접속 주소를 클라우드로 설정할 수 있습니다.

개발 실행:

```bash
cd app_client
flutter run --dart-define=SERVER_WS_URL=wss://daily-mafia-server.onrender.com
```

릴리스 APK:

```bash
cd app_client
flutter build apk --release --dart-define=SERVER_WS_URL=wss://daily-mafia-server.onrender.com
```

설정하지 않으면 기본값은 `ws://127.0.0.1:8080`입니다.

## 참고

- 상세 규칙/수치는 서버 로직(`game_server/index.js`) 기준으로 우선 적용됩니다.
- 앱은 서버에서 전달된 상태(`room_update`, `role_assigned`, `chat`, `ability_log`)를 실시간 반영합니다.
