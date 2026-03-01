# Daily Mafia (Flutter + Local Server)

매 턴마다 마피아/시민 역할이 랜덤으로 바뀌는 텍스트 기반 멀티플레이 MVP입니다.

## 구성

- `game_server`: Node.js WebSocket 서버
- `app_client`: Flutter 모바일 앱

## 구현된 핵심 기능

- 방 생성/입장/퇴장
- 실시간 전체 채팅
- 게임 시작, 아침 단계, 투표 시작/마감(방장)
- **매 턴 랜덤 역할 배정** (`role_assigned`)
- 시민 능력: 조사 (`inspect`) - 대상의 이번 턴 역할 확인
- 마피아 능력: 익명 제보 (`mislead`) - 전체에 익명 메시지 송출
- 마피아의 다음날 진행 여부 선택 (`mafia_continue`, 투표 단계)
- 투표 결과 처리:
  - 마피아 처형 시 즉시 게임 종료 + 점수 정산
  - 마피아 생존 시 잔존 시민 수만큼 마피아 점수 획득
- 점수/플레이어 목록 동기화

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

## 규칙 반영 메모

- 1턴: 아침 ~ 처형 투표 마감
- 턴이 끝날 때마다 다음 턴 역할 재배정
- 진행 중 턴에서 마피아가 검거되면 즉시 종료
- 세부 밸런스(점수 보정, 능력 추가 등)는 추후 확장 가능
