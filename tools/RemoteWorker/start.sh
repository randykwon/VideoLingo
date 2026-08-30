#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"
set -a
source .env
set +a
exec .venv/bin/uvicorn server:app --host 0.0.0.0 --port "${VIDEOLINGO_PORT:-8765}"
