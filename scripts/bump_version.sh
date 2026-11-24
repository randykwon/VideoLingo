#!/bin/zsh
# project.yml의 MARKETING_VERSION / CURRENT_PROJECT_VERSION을 단일 기준으로 조회하거나 갱신합니다.
# 사용법:
#   ./scripts/bump_version.sh                  # 현재 버전과 빌드 번호 출력
#   ./scripts/bump_version.sh 1.1.0            # 버전을 1.1.0으로 변경하고 빌드 번호를 +1
#   ./scripts/bump_version.sh 1.1.0 10         # 버전을 1.1.0, 빌드 번호를 10으로 지정
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
PROJECT_YML="$ROOT_DIR/project.yml"

current_version=$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' "$PROJECT_YML")
current_build=$(awk -F'"' '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$PROJECT_YML")

if [[ -z "$current_version" || -z "$current_build" ]]; then
  echo "error: project.yml에서 MARKETING_VERSION 또는 CURRENT_PROJECT_VERSION을 찾지 못했습니다." >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "Version: $current_version ($current_build)"
  exit 0
fi

if [[ $# -gt 2 ]]; then
  echo "Usage: $0 [<marketing_version> [<build_number>]]" >&2
  exit 1
fi

new_version="$1"
if [[ ! "$new_version" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]]; then
  echo "error: 버전 형식이 올바르지 않습니다 (예: 1.0.1 또는 1.1.0): $new_version" >&2
  exit 1
fi

if [[ $# -eq 2 ]]; then
  new_build="$2"
else
  new_build=$((current_build + 1))
fi

if [[ ! "$new_build" =~ '^[0-9]+$' ]]; then
  echo "error: 빌드 번호는 양의 정수여야 합니다: $new_build" >&2
  exit 1
fi

/usr/bin/sed -i '' \
  -e "s|^\([[:space:]]*MARKETING_VERSION:[[:space:]]*\)\"[^\"]*\"|\1\"$new_version\"|" \
  -e "s|^\([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*\)\"[^\"]*\"|\1\"$new_build\"|" \
  "$PROJECT_YML"

echo "Updated project.yml: $current_version ($current_build) -> $new_version ($new_build)"

if command -v xcodegen >/dev/null 2>&1; then
  (cd "$ROOT_DIR" && xcodegen generate)
else
  echo "warning: xcodegen이 설치되어 있지 않아 Xcode 프로젝트를 재생성하지 못했습니다." >&2
fi
