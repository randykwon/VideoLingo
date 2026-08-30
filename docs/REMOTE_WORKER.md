# VideoLingo 다중 STT·LLM Worker

메인 Mac은 내장 XPC 서버와 LAN의 원격 Worker를 함께 사용한다. 대량 번역 시작 시 등록된 Worker의 상태와 슬롯 수를 확인하고, 여유 Worker에 전체 STT·번역 작업을 배정한다. 원격 장애 시 작업은 내장 서버로 자동 전환된다.

## 다른 노트북 설치

Apple Silicon Mac 또는 Python 3.11 이상 환경에서 `Tools/RemoteWorker` 폴더를 복사한 뒤 실행한다.

```sh
chmod +x install.sh start.sh
./install.sh
ollama pull qwen3:8b
./start.sh
```

`.env`의 `VIDEOLINGO_TOKEN`은 비밀번호처럼 관리한다. 방화벽에서 TCP 8765를 같은 LAN에만 허용한다. 메인 앱의 설정 > 서버에서 `http://노트북-IP:8765`와 토큰을 등록하고 연결 확인을 누른다.

`VIDEOLINGO_STT_SLOTS`와 `VIDEOLINGO_TRANSLATION_SLOTS`는 노트북 메모리에 맞게 설정한다. 기본값 1을 권장하며, 여러 Worker를 등록하면 작업 단위로 자동 분산된다.

현재 전송은 Bearer 토큰 인증을 사용한다. 신뢰할 수 없는 네트워크나 인터넷을 경유할 때는 리버스 프록시에서 HTTPS를 반드시 적용한다.
