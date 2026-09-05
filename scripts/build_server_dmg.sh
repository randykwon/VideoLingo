#!/bin/zsh
# 외부 Mac에서 STT·번역 서버(STTLMMServer)를 돌리기 위한 설치 패키지 DMG를 만듭니다.
# 앱이 아니라 설치 스크립트 묶음입니다. 실제 서버는 install.sh가 GitHub에서 받아 설치합니다.
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
SOURCE_DIR="$ROOT_DIR/tools/RemoteWorker"
DIST_DIR="$ROOT_DIR/dist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Sources/VideoLingo/Info.plist")
DMG_PATH="$DIST_DIR/VideoLingo-Server-$VERSION.dmg"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/videolingo-server-dmg.XXXXXX")
PAYLOAD="$STAGING_DIR/VideoLingo Server"

cleanup() { rm -rf "$STAGING_DIR"; }
trap cleanup EXIT

mkdir -p "$PAYLOAD" "$DIST_DIR"
cp "$SOURCE_DIR/install.sh" "$SOURCE_DIR/start.sh" "$SOURCE_DIR/.env.example" "$SOURCE_DIR/README.md" "$PAYLOAD/"
chmod +x "$PAYLOAD/install.sh" "$PAYLOAD/start.sh"

cat > "$PAYLOAD/시작하기.command" <<'LAUNCHER'
#!/bin/zsh
# 더블클릭하면 설치와 실행을 순서대로 진행합니다.
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -f .env ]]; then
  cp .env.example .env
  KEY=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)
  /usr/bin/sed -i '' "s|replace-with-a-long-random-token|$KEY|" .env
  echo "API 키를 생성해 .env에 저장했습니다."
fi
if [[ ! -d .venv ]]; then
  echo "== 설치를 시작합니다 (처음 한 번만, 수 분 소요) =="
  ./install.sh
fi
echo
echo "== 서버를 시작합니다 =="
echo "VideoLingo에 등록할 주소:"
for ip in $(ipconfig getifaddr en0 2>/dev/null; ipconfig getifaddr en1 2>/dev/null); do
  echo "    http://$ip:$(grep '^STTLMM_PORT=' .env | cut -d= -f2)"
done
echo "API 키: $(grep '^STTLMM_API_KEY=' .env | cut -d= -f2)"
echo
./start.sh
LAUNCHER
chmod +x "$PAYLOAD/시작하기.command"

cat > "$PAYLOAD/읽어주세요.txt" <<'GUIDE'
VideoLingo 원격 STT·번역 서버 (macOS)
=====================================

이 Mac을 VideoLingo의 STT·번역 처리 서버로 씁니다.
대량 번역을 다른 Mac에 맡겨 본체 부담을 줄일 수 있습니다.

■ 준비물 (먼저 설치)
    - Python 3.10~3.13
    - Git
    - ffmpeg
  Homebrew가 있으면:  brew install python git ffmpeg

■ 설치와 실행
    1. 이 폴더를 응용 프로그램이 아닌 곳(예: 홈 폴더)에 복사합니다.
    2. "시작하기.command"를 더블클릭합니다.
       - 처음 한 번은 설치가 진행됩니다(수 분 소요).
       - API 키가 자동 생성되어 .env에 저장됩니다.
    3. 터미널에 표시되는 주소와 API 키를 적어 둡니다.

■ VideoLingo(작업용 Mac)에서 등록
    대량 번역 창 → 설정 → "원격 STT·번역 서버"
      · 서버 주소: 표시된 http://... 주소 (또는 IP만 입력)
      · API 키 사용: 켬 → 표시된 키 입력
      · "연결 후 추가"

■ 방화벽
  같은 네트워크에서 TCP 8848 접속을 허용해야 합니다.
  시스템 설정 → 네트워크 → 방화벽에서 들어오는 연결을 허용하세요.

■ 참고
  - 서버 관리 화면: http://이-Mac의-IP:8848/admin
  - .env의 API 키는 외부에 공개하지 마세요.
  - 설치본은 github.com/randykwon/STTLMMServer 에서 받아옵니다.
GUIDE

hdiutil create -volname "VideoLingo Server" -srcfolder "$STAGING_DIR" -format UDZO -ov "$DMG_PATH" >/dev/null
hdiutil verify "$DMG_PATH" >/dev/null
echo "DMG: $DMG_PATH"
ls -lh "$DMG_PATH" | awk '{print "크기: "$5}'
shasum -a 256 "$DMG_PATH"
