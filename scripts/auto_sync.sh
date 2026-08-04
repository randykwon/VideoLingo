#!/bin/bash
set -e

# 이동: 저장소 루트 디렉토리
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# 변동 사항이 있는지 확인
if [ -n "$(git status --porcelain)" ]; then
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TIMESTAMP] 변동 사항 감지. 커밋 및 푸시를 진행합니다..."
    git add .
    git commit -m "auto: Sync source updates ($TIMESTAMP)"
    git push origin main
    echo "[$TIMESTAMP] 커밋 및 푸시 완료."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 변경 사항 없음."
fi
