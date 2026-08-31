#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

command -v git >/dev/null || { echo "git이 필요합니다." >&2; exit 1; }
command -v python3 >/dev/null || { echo "Python 3.10~3.13이 필요합니다." >&2; exit 1; }

if [[ -d STTLMMServer/.git ]]; then
  git -C STTLMMServer pull --ff-only
else
  git clone https://github.com/randykwon/STTLMMServer.git STTLMMServer
fi
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
  .venv/bin/pip install -e './STTLMMServer[mlx,audio]'
else
  .venv/bin/pip install -e './STTLMMServer[cpu,llamacpp,audio]'
fi
echo "STTLMMServer 설치 완료. ./start.sh 로 실행하세요."
