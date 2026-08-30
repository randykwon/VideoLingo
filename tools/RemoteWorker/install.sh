#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/pip install -r requirements.txt
if [[ ! -f .env ]]; then
  token="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  {
    echo "VIDEOLINGO_TOKEN=$token"
    echo "VIDEOLINGO_NAME=$(scutil --get ComputerName 2>/dev/null || hostname)"
    echo "VIDEOLINGO_STT_SLOTS=1"
    echo "VIDEOLINGO_TRANSLATION_SLOTS=1"
    echo "OLLAMA_URL=http://127.0.0.1:11434"
    echo "OLLAMA_MODEL=qwen3:8b"
  } > .env
fi
echo "설치 완료. ./start.sh 를 실행한 뒤 .env의 VIDEOLINGO_TOKEN을 메인 Mac에 등록하세요."
