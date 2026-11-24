#!/bin/zsh
# SpikDoum과 동일한 방식으로 Metal GPU 임베디드 whisper-server(whisper.cpp)와
# llama-server(llama.cpp)를 빌드하고 로컬 Application Support/VideoLingo/ManagedRuntime에 설치합니다.
# 이미 SpikDoum이 /Users/yongsunk/Dev/speakhelper 또는 /Applications/SpikDoum.app에 있다면
# --from-spikdoum 옵션으로 기존 빌드된 Metal 바이너리를 즉시 복사할 수 있습니다.
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
DEST_DIR="${HOME}/Library/Application Support/VideoLingo/ManagedRuntime"
mkdir -p "$DEST_DIR"

if [[ "${1:-}" == "--from-spikdoum" ]]; then
  for candidate in \
    "/Applications/SpikDoum.app/Contents/Resources/ManagedRuntime" \
    "${HOME}/Dev/speakhelper/dist/SpikDoum.app/Contents/Resources/ManagedRuntime"; do
    if [[ -x "$candidate/whisper-server" && -x "$candidate/llama-server" ]]; then
      cp -f "$candidate/whisper-server" "$DEST_DIR/whisper-server"
      cp -f "$candidate/llama-server" "$DEST_DIR/llama-server"
      chmod +x "$DEST_DIR/whisper-server" "$DEST_DIR/llama-server"
      for doc in whisper-LICENSE llama-LICENSE THIRD_PARTY_LICENSES.txt ManagedRuntimeNotice.md; do
        [[ -f "$candidate/$doc" ]] && cp -f "$candidate/$doc" "$DEST_DIR/$doc"
      done
      echo "Installed prebuilt Metal runtimes from $candidate -> $DEST_DIR"
      exit 0
    fi
  done
  echo "error: SpikDoum의 사전 빌드된 ManagedRuntime을 찾지 못했습니다. 인자 없이 실행해 소스에서 빌드하세요." >&2
  exit 1
fi

cd "$ROOT_DIR"
mkdir -p .runtime-src .runtime-build/bin

fetch_source() {
  local project="$1" tag="$2" revision="$3" folder="$4"
  if [[ ! -d "$folder/.git" ]]; then
    git clone --depth 1 --branch "$tag" "https://github.com/ggml-org/$project.git" "$folder"
  fi
  [[ "$(git -C "$folder" rev-parse HEAD)" == "$revision" ]] || {
    print -u2 "Unexpected runtime source revision: $folder"
    exit 1
  }
}

fetch_source whisper.cpp v1.9.5 d1be6fde11ac6e0407606b4e42fe72d34add8037 .runtime-src/whisper
fetch_source llama.cpp v1.0.0 b1b770d90d94cad9e9ea5b993bdbc383a522fb28 .runtime-src/llama

python3 - <<'PATCH'
from pathlib import Path
p = Path('.runtime-src/whisper/examples/server/server.cpp')
s = p.read_text()
if '// VideoLingo loopback authorization' not in s and '// SpikDoum loopback authorization' not in s:
    target = '    svr->set_default_headers('
    i = s.index(target)
    patch = '''    // VideoLingo loopback authorization
    const char * raw_key = std::getenv("VIDEOLINGO_API_KEY") ? std::getenv("VIDEOLINGO_API_KEY") : std::getenv("SPIKDOUM_API_KEY");
    const std::string app_key = raw_key ? raw_key : "";
    svr->set_payload_max_length(64 * 1024 * 1024);
    svr->set_pre_routing_handler([app_key](const Request & req, Response & res) {
        if (req.path == "/health") return httplib::Server::HandlerResponse::Unhandled;
        if (!app_key.empty() && req.get_header_value("Authorization") != "Bearer " + app_key) {
            res.status = 401;
            res.set_content(R"({"error":"unauthorized"})", "application/json");
            return httplib::Server::HandlerResponse::Handled;
        }
        return httplib::Server::HandlerResponse::Unhandled;
    });
'''
    p.write_text(s[:i] + patch + s[i:])

for name in ['.runtime-src/whisper/examples/server/server.cpp', '.runtime-src/llama/tools/server/main.cpp']:
    p = Path(name)
    s = p.read_text()
    if '// VideoLingo parent lifetime' not in s and '// SpikDoum parent lifetime' not in s:
        s = '#include <unistd.h>\n#include <cstdlib>\n#include <thread>\n#include <chrono>\n' + s
        target = 'int main(int argc, char ** argv) {'
        guard = '''
    // VideoLingo parent lifetime
    const char * value = std::getenv("VIDEOLINGO_PARENT_PID") ? std::getenv("VIDEOLINGO_PARENT_PID") : std::getenv("SPIKDOUM_PARENT_PID");
    if (value) {
        const int parent = std::atoi(value);
        std::thread([parent]() {
            while (getppid() == parent) std::this_thread::sleep_for(std::chrono::seconds(1));
            std::_Exit(0);
        }).detach();
    }
'''
        assert target in s
        p.write_text(s.replace(target, target + guard, 1))
PATCH

common=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
cmake -S .runtime-src/whisper -B .runtime-build/whisper $common -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=ON -DWHISPER_CURL=OFF
cmake --build .runtime-build/whisper --config Release --target whisper-server -j 4
cmake -S .runtime-src/llama -B .runtime-build/llama $common -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_OPENSSL=OFF
cmake --build .runtime-build/llama --config Release --target llama-server -j 4

cp -f .runtime-build/whisper/bin/whisper-server "$DEST_DIR/whisper-server"
cp -f .runtime-build/llama/bin/llama-server "$DEST_DIR/llama-server"
chmod +x "$DEST_DIR/whisper-server" "$DEST_DIR/llama-server"
cp -f .runtime-src/whisper/LICENSE "$DEST_DIR/whisper-LICENSE"
cp -f .runtime-src/llama/LICENSE "$DEST_DIR/llama-LICENSE"
echo "Built and installed Metal runtimes -> $DEST_DIR"
