#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
set -a
source .env
set +a
exec .venv/bin/uvicorn server:app --host 0.0.0.0 --port "${VIDEOLINGO_PORT:-8765}"
