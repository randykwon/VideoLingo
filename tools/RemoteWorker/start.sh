#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"
set -a
source .env
set +a
: "${STTLMM_API_KEY:?STTLMM_API_KEY가 필요합니다.}"
export STTLMM_SERVER__API_KEYS="[\"${STTLMM_API_KEY}\"]"
exec .venv/bin/sttlmm serve --host 0.0.0.0 --port "${STTLMM_PORT:-8848}" --profile "${STTLMM_PROFILE:-balanced}"
