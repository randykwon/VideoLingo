#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "torch>=2.4.0",
#   "diffusers>=0.33.0",
#   "transformers>=4.49.0",
#   "accelerate>=1.3.0",
#   "huggingface-hub>=0.28.0",
#   "imageio[ffmpeg]>=2.36.0",
#   "pillow>=10.4.0",
#   "numpy>=1.26.0",
# ]
# ///
"""
VAutoLang 로컬 uv Python MPS 영상 복원/인페인팅 워커 (Track 3).
표준 출력으로 `PROGRESS <0.0~1.0> <메시지>` 형식을 출력해 앱 진행률 바와 연동됩니다.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def emit_progress(fraction: float, message: str) -> None:
    clamped = max(0.0, min(1.0, float(fraction)))
    print(f"PROGRESS {clamped:.3f} {message}", flush=True)


def run_check(models_dir: Path) -> int:
    info: dict[str, object] = {
        "python": sys.version.split()[0],
        "models_dir": str(models_dir),
        "wan_vace_weights": (models_dir / "Wan2.1-VACE-1.3B").exists(),
        "seedvr2_weights": (models_dir / "SeedVR2-3B").exists(),
    }
    try:
        import torch  # type: ignore

        info["torch"] = torch.__version__
        info["mps_available"] = bool(torch.backends.mps.is_available())
    except Exception as exc:
        info["torch"] = None
        info["mps_available"] = False
        info["torch_error"] = str(exc)

    try:
        import diffusers  # type: ignore

        info["diffusers"] = diffusers.__version__
        info["has_wan_vace_pipeline"] = hasattr(diffusers, "WanVACEPipeline")
    except Exception as exc:
        info["diffusers"] = None
        info["has_wan_vace_pipeline"] = False
        info["diffusers_error"] = str(exc)

    print(json.dumps(info, ensure_ascii=False), flush=True)
    return 0


def load_video_frames(path: Path, max_frames: int = 81, max_width: int = 832, max_height: int = 480):
    import imageio.v3 as iio  # type: ignore
    from PIL import Image  # type: ignore

    meta = iio.immeta(path, plugin="pyav") if hasattr(iio, "immeta") else {}
    fps = float(meta.get("fps", 24.0)) if isinstance(meta, dict) else 24.0
    frames = []
    for idx, frame in enumerate(iio.imiter(path)):
        if idx >= max_frames:
            break
        img = Image.fromarray(frame).convert("RGB")
        # Wan2.1-VACE는 16 배수 해상도 요구
        scale = min(1.0, max_width / img.width, max_height / img.height)
        w = max(256, (int(img.width * scale) // 16) * 16)
        h = max(256, (int(img.height * scale) // 16) * 16)
        if (w, h) != img.size:
            img = img.resize((w, h), Image.Resampling.BICUBIC)
        frames.append(img)

    if not frames:
        raise RuntimeError(f"입력 영상에서 프레임을 읽지 못했습니다: {path}")
    # Wan2.1은 4n+1 프레임 길이를 선호
    valid_len = ((len(frames) - 1) // 4) * 4 + 1
    frames = frames[: max(1, valid_len)]
    return frames, fps


def run_wan_vace(args: argparse.Namespace) -> int:
    import torch  # type: ignore
    from diffusers import WanVACEPipeline  # type: ignore
    from diffusers.utils import export_to_video  # type: ignore

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    dtype = torch.bfloat16 if device == "mps" else torch.float32

    local_dir = Path(args.models_dir) / "Wan2.1-VACE-1.3B"
    model_source = str(local_dir) if local_dir.exists() else "Wan-AI/Wan2.1-VACE-1.3B"

    emit_progress(0.10, f"Wan2.1-VACE-1.3B 로드 중 ({device})…")
    pipe = WanVACEPipeline.from_pretrained(model_source, torch_dtype=dtype)
    pipe.to(device)

    emit_progress(0.25, "테스트 클립 프레임 디코딩 중…")
    video_frames, fps = load_video_frames(Path(args.input))
    mask_frames = None
    if args.mask and Path(args.mask).exists():
        mask_raw, _ = load_video_frames(
            Path(args.mask),
            max_frames=len(video_frames),
            max_width=video_frames[0].width,
            max_height=video_frames[0].height,
        )
        mask_frames = [m.convert("L") for m in mask_raw[: len(video_frames)]]

    prompt = args.prompt or "clean natural video restoration, sharp realistic details, seamless background"
    negative_prompt = "blurry, mosaic, pixelated, distorted, artifacts, watermark"

    emit_progress(0.40, f"Wan2.1-VACE-1.3B 추론 중 ({len(video_frames)}프레임, {video_frames[0].width}×{video_frames[0].height})…")
    result = pipe(
        video=video_frames,
        mask=mask_frames,
        prompt=prompt,
        negative_prompt=negative_prompt,
        height=video_frames[0].height,
        width=video_frames[0].width,
        num_frames=len(video_frames),
        num_inference_steps=12,
        guidance_scale=5.0,
    ).frames[0]

    emit_progress(0.90, "출력 영상 인코딩 중…")
    export_to_video(result, args.output, fps=fps)
    emit_progress(0.98, "Wan2.1-VACE-1.3B 완료")
    return 0


def run_seedvr2(args: argparse.Namespace) -> int:
    # SeedVR2-3B는 전용 ComfyUI 노드(ComfyUI-SeedVR2_VideoUpscaler) 또는 공식 레포에서 추론합니다.
    seedvr_cli = os.environ.get("SEEDVR2_CLI_PATH")
    if seedvr_cli and Path(seedvr_cli).exists():
        import subprocess

        emit_progress(0.20, "SeedVR2-3B 로컬 CLI 실행 중…")
        subprocess.run(
            [seedvr_cli, "--input", args.input, "--output", args.output],
            check=True,
        )
        emit_progress(0.96, "SeedVR2-3B 완료")
        return 0

    raise RuntimeError(
        "SeedVR2-3B는 현재 ComfyUI 백엔드(ComfyUI-SeedVR2_VideoUpscaler 노드)에서 실행하는 것을 권장합니다. "
        "3번 트랙에서 실행 방식을 ‘ComfyUI 로컬 API’로 선택하거나 SEEDVR2_CLI_PATH 환경 변수를 지정해 주세요."
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--engine", choices=["wan_vace", "seedvr2"], default="wan_vace")
    parser.add_argument("--input", default="")
    parser.add_argument("--mask", default="")
    parser.add_argument("--output", default="")
    parser.add_argument("--models-dir", default=str(Path.home() / "Library/Application Support/VideoLingo/Models/Demosaic"))
    parser.add_argument("--prompt", default="")
    args = parser.parse_args()

    if args.check:
        return run_check(Path(args.models_dir))

    if not args.input or not args.output:
        print("ERROR: --input 및 --output 경로가 필요합니다.", file=sys.stderr)
        return 2

    if args.engine == "wan_vace":
        return run_wan_vace(args)
    return run_seedvr2(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
