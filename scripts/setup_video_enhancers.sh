#!/usr/bin/env bash
set -euo pipefail

# VAutoLang 영상 복원·제거 3트랙 설치 도우미
# 사용법:
#   ./scripts/setup_video_enhancers.sh flashvsr     # Track 2: mlx-flashvsr-swift 빌드 + FlashVSR-v1.1-bf16(3.5GB) 다운로드
#   ./scripts/setup_video_enhancers.sh wan-vace     # Track 3: Wan-AI/Wan2.1-VACE-1.3B 가중치 다운로드
#   ./scripts/setup_video_enhancers.sh seedvr2      # Track 3: SeedVR2-3B FP8 + VAE 가중치 다운로드

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

APP_SUPPORT="$HOME/Library/Application Support/VideoLingo"
ENHANCER_DIR="$APP_SUPPORT/VideoEnhancer"
MODELS_DIR="$APP_SUPPORT/Models/Demosaic"
mkdir -p "$ENHANCER_DIR/bin" "$ENHANCER_DIR/src" "$MODELS_DIR"

hf_download() {
    local repo="$1"
    local dest="$2"
    shift 2
    if command -v uvx >/dev/null 2>&1; then
        uvx --from huggingface_hub hf download "$repo" --local-dir "$dest" "$@"
    elif command -v hf >/dev/null 2>&1; then
        hf download "$repo" --local-dir "$dest" "$@"
    elif command -v huggingface-cli >/dev/null 2>&1; then
        huggingface-cli download "$repo" --local-dir "$dest" "$@"
    else
        echo "ERROR: uvx 또는 huggingface-cli가 필요합니다. (brew install uv)" >&2
        exit 1
    fi
}

TARGET="${1:-}"
case "$TARGET" in
    flashvsr)
        echo "[1/3] mlx-flashvsr-swift 소스 준비 중..."
        SRC_DIR="$ENHANCER_DIR/src/mlx-flashvsr-swift"
        if [ -d "$SRC_DIR/.git" ]; then
            git -C "$SRC_DIR" pull --ff-only || true
        else
            git clone --depth 1 https://github.com/xocialize/mlx-flashvsr-swift.git "$SRC_DIR"
        fi

        echo "[2/3] flashvsr-smoke Release 빌드 중 (Swift + MLX Metal)..."
        (
            cd "$SRC_DIR"
            swift build -c release --build-system swiftbuild --product flashvsr-smoke
        )
        BIN_PATH="$(find "$SRC_DIR/.build" -type f -name flashvsr-smoke -perm -111 | head -n 1 || true)"
        if [ -z "$BIN_PATH" ]; then
            echo "ERROR: flashvsr-smoke 빌드 산출물을 찾지 못했습니다." >&2
            exit 1
        fi
        cp -f "$BIN_PATH" "$ENHANCER_DIR/bin/flashvsr-smoke"
        chmod +x "$ENHANCER_DIR/bin/flashvsr-smoke"
        echo "설치 완료: $ENHANCER_DIR/bin/flashvsr-smoke"

        echo "[3/3] mlx-community/FlashVSR-v1.1-bf16 (3.5GB) 다운로드 중..."
        hf_download "mlx-community/FlashVSR-v1.1-bf16" "$MODELS_DIR/FlashVSR-v1.1-bf16"
        echo "DONE: FlashVSR v1.1 MLX 준비 완료"
        ;;

    wan-vace)
        echo "[1/1] Wan-AI/Wan2.1-VACE-1.3B 다운로드 중..."
        hf_download "Wan-AI/Wan2.1-VACE-1.3B" "$MODELS_DIR/Wan2.1-VACE-1.3B"
        echo "DONE: Wan2.1-VACE-1.3B 가중치 준비 완료 ($MODELS_DIR/Wan2.1-VACE-1.3B)"
        ;;

    seedvr2)
        echo "[1/1] SeedVR2-3B FP8 + VAE 다운로드 중..."
        hf_download "numz/SeedVR2_comfyUI" "$MODELS_DIR/SeedVR2-3B" \
            --include "*3b*fp8*" --include "*ema_vae_fp16*"
        echo "DONE: SeedVR2-3B 가중치 준비 완료 ($MODELS_DIR/SeedVR2-3B)"
        ;;

    *)
        echo "사용법: $0 {flashvsr|wan-vace|seedvr2}" >&2
        exit 2
        ;;
esac
