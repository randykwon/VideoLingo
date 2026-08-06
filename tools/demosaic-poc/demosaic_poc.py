#!/usr/bin/env python3
"""
Demosaic PoC — 얼굴 모자이크 제거 품질 검증 오케스트레이터.

여러 복원 백엔드를 실행해 "원본 + 각 결과"를 나란히 붙인 비교 영상을 만든다.
Swift 앱 통합 전에 실제 클립으로 모델을 고르기 위한 도구다. (README 참고)

주의: 모자이크는 비가역 손실이라 결과는 복구가 아닌 생성이며, 얼굴은 실제 인물이 아니다.
권리 있는 영상에만 사용할 것.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

import cv2
import numpy as np


# --------------------------------------------------------------------------- #
# 유틸
# --------------------------------------------------------------------------- #
def have_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


def run(cmd: list[str], cwd: Optional[str] = None) -> int:
    print("  $ " + " ".join(str(c) for c in cmd))
    return subprocess.run(cmd, cwd=cwd).returncode


def video_info(path: str) -> tuple[float, int, int, int]:
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise SystemExit(f"영상을 열 수 없습니다: {path}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    cap.release()
    return fps, w, h, n


def trim(input_path: str, seconds: Optional[float], workdir: Path) -> str:
    """앞 N초만 잘라 빠른 반복 테스트에 사용. ffmpeg 없으면 원본 그대로."""
    if not seconds:
        return input_path
    if not have_ffmpeg():
        print("  ! ffmpeg 없음 → --seconds 무시하고 전체 처리")
        return input_path
    out = str(workdir / "trimmed.mp4")
    run(["ffmpeg", "-y", "-i", input_path, "-t", str(seconds),
         "-c:v", "libx264", "-crf", "18", "-c:a", "aac", out])
    return out if os.path.exists(out) else input_path


def process_frames(input_path: str, output_path: str, fps: float,
                   fn: Callable[[np.ndarray], np.ndarray]) -> None:
    """입력 프레임을 fn으로 변환해 output_path(mp4v)로 저장. fn은 BGR→BGR."""
    cap = cv2.VideoCapture(input_path)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    writer = cv2.VideoWriter(output_path, cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
    idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        out = fn(frame)
        if out.shape[:2] != (h, w):
            out = cv2.resize(out, (w, h), interpolation=cv2.INTER_LANCZOS4)
        writer.write(out)
        idx += 1
        if idx % 50 == 0:
            print(f"    …{idx} 프레임")
    cap.release()
    writer.release()


# --------------------------------------------------------------------------- #
# 얼굴 검출 + 간이 IoU 트래커 (temporal identity 가정 검증용)
# --------------------------------------------------------------------------- #
class FaceTracker:
    def __init__(self, yunet_path: Optional[str]):
        self.detector = None
        self.haar = None
        # 1순위: YuNet(정확), 2순위: Haar, 둘 다 없으면 검출 없이 통과(경고).
        if yunet_path and os.path.exists(yunet_path) and hasattr(cv2, "FaceDetectorYN"):
            self.detector = cv2.FaceDetectorYN.create(yunet_path, "", (320, 320))
        elif hasattr(cv2, "CascadeClassifier") and hasattr(cv2, "data"):
            xml = os.path.join(cv2.data.haarcascades, "haarcascade_frontalface_default.xml")
            cascade = cv2.CascadeClassifier(xml)
            self.haar = cascade if not cascade.empty() else None
        if self.detector is None and self.haar is None:
            print("  ! 얼굴 검출기 사용 불가(YuNet 미지정 & Haar 없음) → 검출 없이 통과. "
                  "정확한 검출은 --yunet 로 YuNet onnx 지정 권장.")
        self.tracks: list[tuple[int, tuple[int, int, int, int]]] = []
        self.next_id = 0

    def detect(self, frame: np.ndarray) -> list[tuple[int, int, int, int]]:
        h, w = frame.shape[:2]
        boxes: list[tuple[int, int, int, int]] = []
        if self.detector is not None:
            self.detector.setInputSize((w, h))
            _, faces = self.detector.detect(frame)
            if faces is not None:
                for f in faces:
                    x, y, bw, bh = f[:4].astype(int)
                    boxes.append((max(0, x), max(0, y), int(bw), int(bh)))
        else:
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            for (x, y, bw, bh) in self.haar.detectMultiScale(gray, 1.2, 5, minSize=(32, 32)):
                boxes.append((int(x), int(y), int(bw), int(bh)))
        return boxes

    @staticmethod
    def _iou(a, b) -> float:
        ax, ay, aw, ah = a; bx, by, bw, bh = b
        x1, y1 = max(ax, bx), max(ay, by)
        x2, y2 = min(ax + aw, bx + bw), min(ay + ah, by + bh)
        inter = max(0, x2 - x1) * max(0, y2 - y1)
        union = aw * ah + bw * bh - inter
        return inter / union if union else 0.0

    def assign(self, boxes) -> list[tuple[int, tuple[int, int, int, int]]]:
        """각 박스에 안정적인 track id 부여(직전 프레임과 IoU 매칭)."""
        result = []
        used = set()
        for box in boxes:
            best, best_iou = -1, 0.3
            for tid, prev in self.tracks:
                if tid in used:
                    continue
                iou = self._iou(box, prev)
                if iou > best_iou:
                    best, best_iou = tid, iou
            if best < 0:
                best = self.next_id
                self.next_id += 1
            used.add(best)
            result.append((best, box))
        self.tracks = [(tid, box) for tid, box in result]
        return result


# --------------------------------------------------------------------------- #
# 백엔드
# --------------------------------------------------------------------------- #
@dataclass
class Ctx:
    fps: float
    args: argparse.Namespace
    workdir: Path


def backend_passthrough(inp: str, out: str, ctx: Ctx) -> bool:
    process_frames(inp, out, ctx.fps, lambda f: f)
    return True


def backend_faces(inp: str, out: str, ctx: Ctx) -> bool:
    tracker = FaceTracker(ctx.args.yunet)
    palette = [(60, 200, 60), (60, 60, 220), (220, 160, 40), (200, 60, 200), (40, 200, 200)]

    def draw(frame: np.ndarray) -> np.ndarray:
        vis = frame.copy()
        for tid, (x, y, bw, bh) in tracker.assign(tracker.detect(frame)):
            c = palette[tid % len(palette)]
            cv2.rectangle(vis, (x, y), (x + bw, y + bh), c, 2)
            cv2.putText(vis, f"id{tid}", (x, max(14, y - 6)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, c, 2)
        return vis

    process_frames(inp, out, ctx.fps, draw)
    return True


def backend_realesrgan(inp: str, out: str, ctx: Ctx) -> bool:
    try:
        import torch
        from realesrgan import RealESRGANer
        from basicsr.archs.rrdbnet_arch import RRDBNet
    except Exception as e:  # noqa: BLE001
        print(f"  ! realesrgan 미설치 건너뜀: {e}")
        return False
    device = ctx.args.device
    if device == "auto":
        device = "mps" if torch.backends.mps.is_available() else (
            "cuda" if torch.cuda.is_available() else "cpu")
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64,
                    num_block=23, num_grow_ch=32, scale=4)
    weights = ctx.args.realesrgan_model or "RealESRGAN_x4plus.pth"
    up = RealESRGANer(scale=4, model_path=weights, model=model,
                      half=(device == "cuda"), device=torch.device(device))

    def enhance(frame: np.ndarray) -> np.ndarray:
        # outscale=1: SR로 디테일 재생성 후 원본 크기로 되돌림(가벼운 디블록 효과)
        img, _ = up.enhance(frame, outscale=1)
        return img

    process_frames(inp, out, ctx.fps, enhance)
    return True


def _find_newest(dir_path: str, exts=(".mp4", ".avi", ".mov")) -> Optional[str]:
    cands = [os.path.join(r, f) for r, _, fs in os.walk(dir_path)
             for f in fs if f.lower().endswith(exts)]
    return max(cands, key=os.path.getmtime) if cands else None


def backend_deepmosaics(inp: str, out: str, ctx: Ctx) -> bool:
    repo = ctx.args.deepmosaics_repo
    weights = ctx.args.deepmosaics_weights
    if not repo or not os.path.isdir(repo):
        print("  ! --deepmosaics-repo 미지정/없음 → 건너뜀")
        return False
    result_dir = os.path.join(repo, "result")
    before = set(os.listdir(result_dir)) if os.path.isdir(result_dir) else set()
    cmd = [sys.executable, "deepmosaic.py",
           "--media_path", os.path.abspath(inp),
           "--mode", "clean",
           "--gpu_id", "0" if ctx.args.device == "cuda" else "-1"]
    if weights:
        cmd += ["--model_path", os.path.abspath(weights)]
    if run(cmd, cwd=repo) != 0:
        print("  ! DeepMosaics 실행 실패(플래그/가중치 확인) → 건너뜀")
        return False
    produced = _find_newest(result_dir) if os.path.isdir(result_dir) else None
    if not produced:
        print("  ! DeepMosaics 출력 파일을 찾지 못함 → 건너뜀")
        return False
    shutil.copy(produced, out)
    return True


def backend_codeformer(inp: str, out: str, ctx: Ctx) -> bool:
    repo = ctx.args.codeformer_repo
    if not repo or not os.path.isdir(repo):
        print("  ! --codeformer-repo 미지정/없음 → 건너뜀")
        return False
    out_dir = str(ctx.workdir / "codeformer_out")
    os.makedirs(out_dir, exist_ok=True)
    cmd = [sys.executable, "inference_codeformer.py",
           "-w", str(ctx.args.fidelity),
           "--input_path", os.path.abspath(inp),
           "--output_path", os.path.abspath(out_dir),
           "--bg_upsampler", "realesrgan", "--face_upsample"]
    if run(cmd, cwd=repo) != 0:
        print("  ! CodeFormer 실행 실패(버전별 플래그 확인) → 건너뜀")
        return False
    produced = _find_newest(out_dir)
    if not produced:
        print("  ! CodeFormer 출력 영상을 찾지 못함(프레임 폴더만 생성됐을 수 있음) → 건너뜀")
        return False
    shutil.copy(produced, out)
    return True


BACKENDS: dict[str, Callable[[str, str, Ctx], bool]] = {
    "passthrough": backend_passthrough,
    "faces": backend_faces,
    "realesrgan": backend_realesrgan,
    "deepmosaics": backend_deepmosaics,
    "codeformer": backend_codeformer,
}


# --------------------------------------------------------------------------- #
# 비교 영상 합성
# --------------------------------------------------------------------------- #
def build_comparison(labeled: list[tuple[str, str]], out_path: str,
                     fps: float, panel_h: int, audio_src: str) -> None:
    caps = [(label, cv2.VideoCapture(p)) for label, p in labeled]
    caps = [(l, c) for l, c in caps if c.isOpened()]
    if not caps:
        print("비교할 결과가 없습니다.")
        return
    tmp = out_path + ".noaudio.mp4"
    writer = None
    while True:
        panels = []
        ok_all = True
        for _, cap in caps:
            ok, frame = cap.read()
            if not ok:
                ok_all = False
                break
            h, w = frame.shape[:2]
            scale = panel_h / h
            panels.append(cv2.resize(frame, (int(w * scale), panel_h)))
        if not ok_all:
            break
        # 라벨 바
        labeled_panels = []
        for (label, _), panel in zip(caps, panels):
            bar = np.zeros((28, panel.shape[1], 3), np.uint8)
            cv2.putText(bar, label, (8, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
            labeled_panels.append(np.vstack([bar, panel]))
        row = np.hstack(labeled_panels)
        if writer is None:
            writer = cv2.VideoWriter(tmp, cv2.VideoWriter_fourcc(*"mp4v"),
                                     fps, (row.shape[1], row.shape[0]))
        writer.write(row)
    for _, cap in caps:
        cap.release()
    if writer:
        writer.release()
    # 원본 오디오 먹싱 + h264 재인코딩(호환성)
    if have_ffmpeg():
        run(["ffmpeg", "-y", "-i", tmp, "-i", audio_src,
             "-map", "0:v:0", "-map", "1:a:0?", "-c:v", "libx264", "-crf", "18",
             "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", out_path])
        os.remove(tmp)
    else:
        os.replace(tmp, out_path)
    print(f"\n✅ 비교 영상: {out_path}")


# --------------------------------------------------------------------------- #
def main() -> None:
    ap = argparse.ArgumentParser(description="얼굴 모자이크 제거 품질 비교 PoC")
    ap.add_argument("input")
    ap.add_argument("--backends", default="passthrough,faces,realesrgan")
    ap.add_argument("--outdir", default="out")
    ap.add_argument("--seconds", type=float, default=None)
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--device", default="auto", choices=["auto", "cpu", "mps", "cuda"])
    ap.add_argument("--fidelity", type=float, default=0.7, help="CodeFormer 충실도 0..1")
    ap.add_argument("--yunet", default=None, help="YuNet onnx 경로(얼굴검출 품질↑)")
    ap.add_argument("--realesrgan-model", default=None)
    ap.add_argument("--deepmosaics-repo", default=None)
    ap.add_argument("--deepmosaics-weights", default=None)
    ap.add_argument("--codeformer-repo", default=None)
    args = ap.parse_args()

    if not os.path.exists(args.input):
        raise SystemExit(f"입력 파일 없음: {args.input}")
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    workdir = Path(tempfile.mkdtemp(prefix="demosaic_poc_"))

    source = trim(args.input, args.seconds, workdir)
    fps, w, h, n = video_info(source)
    print(f"입력: {w}x{h} @ {fps:.2f}fps, {n} 프레임\n")

    ctx = Ctx(fps=fps, args=args, workdir=workdir)
    requested = [b.strip() for b in args.backends.split(",") if b.strip()]
    labeled: list[tuple[str, str]] = [("original", source)]

    for name in requested:
        fn = BACKENDS.get(name)
        if fn is None:
            print(f"⚠ 알 수 없는 백엔드: {name} (건너뜀)")
            continue
        if name == "passthrough":  # 원본과 중복 → 비교에서 생략
            continue
        print(f"▶ 백엔드 실행: {name}")
        out_path = str(outdir / f"{name}.mp4")
        try:
            if fn(source, out_path, ctx):
                labeled.append((name, out_path))
                print(f"  ✓ {out_path}")
        except Exception as e:  # noqa: BLE001
            print(f"  ! {name} 실패: {e}")

    build_comparison(labeled, str(outdir / "comparison.mp4"),
                     fps, args.height, audio_src=source)
    shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
