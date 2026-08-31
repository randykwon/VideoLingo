# VideoLingo Remote Worker 설치

이 폴더의 `.env`에는 메인 VideoLingo 앱과 연결할 인증 토큰이 들어 있습니다. 외부에 공개하지 마세요.

## Docker 권장

Docker Desktop 또는 Docker Engine을 설치한 뒤 이 폴더에서 실행합니다.

CPU:

```sh
docker compose up -d --build
docker compose exec ollama ollama pull qwen3:8b
```

Windows/Linux NVIDIA GPU:

```sh
docker compose -f compose.yaml -f compose.nvidia.yaml up -d --build
docker compose exec ollama ollama pull qwen3:8b
```

## Docker 없이 실행

Python 3.11 이상과 Ollama를 설치하고 `ollama pull qwen3:8b`를 먼저 실행합니다.

- Windows PowerShell: `Set-ExecutionPolicy -Scope Process Bypass`, `./install.ps1`, `./start.ps1`
- Linux/macOS: `chmod +x install.sh start.sh`, `./install.sh`, `./start.sh`

방화벽에서 같은 LAN에 대해 TCP 8765를 허용합니다. 메인 Mac에서 이 PC의 IP를 확인한 뒤 `http://IP주소:8765`를 서버 주소로 등록하세요.
