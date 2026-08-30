# VideoLingo 다중 STT·LLM Worker

Worker는 운영체제와 관계없는 HTTP API를 사용한다. 메인 Mac은 내장 XPC 서버와 Windows, Linux, macOS의 원격 Worker를 함께 사용하며, 대량 번역 시작 시 각 서버의 가용 슬롯으로 작업을 자동 분산한다. 영상은 HTTP로 전송되므로 공유 폴더나 동일한 파일 경로가 필요 없다. 원격 장애 시 해당 작업은 내장 서버로 자동 전환된다.

## 권장 설치: Docker

Windows 10/11에서는 Docker Desktop(WSL2), Linux에서는 Docker Engine과 Compose plugin, macOS에서는 Docker Desktop을 설치한다. `tools/RemoteWorker` 폴더를 대상 PC로 복사한 다음 `.env.example`을 `.env`로 복사하고 다음 값을 변경한다.

- `VIDEOLINGO_TOKEN`: 충분히 긴 임의 문자열
- `VIDEOLINGO_NAME`: 서버 목록에 표시할 PC 이름
- `VIDEOLINGO_STT_SLOTS`, `VIDEOLINGO_TRANSLATION_SLOTS`: 처음에는 각각 1 권장
- `OLLAMA_MODEL`: 사용할 Ollama 모델 태그

CPU 또는 Apple Silicon 환경:

```sh
docker compose up -d --build
docker compose exec ollama ollama pull qwen3:8b
```

Windows/Linux의 NVIDIA GPU 환경은 최신 NVIDIA 드라이버와 NVIDIA Container Toolkit을 설치한 뒤 실행한다.

```sh
docker compose -f compose.yaml -f compose.nvidia.yaml up -d --build
docker compose exec ollama ollama pull qwen3:8b
```

Docker Desktop의 Windows PowerShell에서도 동일한 `docker compose` 명령을 사용할 수 있다. 상태 확인은 `docker compose logs -f worker`, 중지는 `docker compose down`으로 한다. 모델과 캐시는 Docker volume에 보존된다.

## Docker 없이 설치

Python 3.11 이상과 Ollama를 먼저 설치하고 `ollama pull qwen3:8b`를 실행한다.

Linux/macOS:

```sh
chmod +x install.sh start.sh
./install.sh
./start.sh
```

Windows PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
.\start.ps1
```

NVIDIA GPU를 네이티브 설치에서 사용할 때 `.env`의 `WHISPER_DEVICE=cuda`, `WHISPER_COMPUTE_TYPE=float16`으로 설정한다. GPU 드라이버/CUDA 조합이 맞지 않으면 CPU 설정인 `auto`로 되돌린다.

## 메인 앱 연결

Worker PC의 방화벽에서 TCP 8765를 같은 LAN에만 허용한다. 메인 앱의 `설정 > 서버 > 추가 STT·LLM 서버`에 다음 정보를 등록한다.

- 서버 주소: `http://Worker-PC-IP:8765`
- 인증 토큰: Worker의 `.env`에 지정한 `VIDEOLINGO_TOKEN`

연결 확인 후 표시되는 운영체제, CPU 구조, STT/번역 슬롯을 확인한다. 여러 PC를 같은 방식으로 등록하면 별도 설정 없이 함께 사용한다.

Bearer 토큰은 비밀번호처럼 관리해야 한다. 인터넷이나 신뢰할 수 없는 네트워크를 통과할 때는 VPN 또는 HTTPS 리버스 프록시를 반드시 사용한다.
