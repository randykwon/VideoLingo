#!/usr/bin/env python3
"""합성 테스트 클립 생성기 — 파이프라인 검증용.
움직이는 '얼굴' 위에 모자이크 블록을 입힌 짧은 영상을 만든다. (실제 얼굴 아님)
"""
import argparse
import cv2
import numpy as np


def draw_face(frame, cx, cy):
    cv2.ellipse(frame, (cx, cy), (70, 90), 0, 0, 360, (150, 190, 230), -1)  # 얼굴
    cv2.circle(frame, (cx - 25, cy - 20), 10, (60, 60, 60), -1)             # 눈
    cv2.circle(frame, (cx + 25, cy - 20), 10, (60, 60, 60), -1)
    cv2.ellipse(frame, (cx, cy + 30), (30, 15), 0, 0, 180, (40, 40, 120), 3)  # 입


def mosaic(frame, x, y, w, h, block=12):
    roi = frame[y:y + h, x:x + w]
    if roi.size == 0:
        return
    small = cv2.resize(roi, (max(1, w // block), max(1, h // block)), interpolation=cv2.INTER_LINEAR)
    frame[y:y + h, x:x + w] = cv2.resize(small, (w, h), interpolation=cv2.INTER_NEAREST)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="sample.mp4")
    ap.add_argument("--seconds", type=float, default=4.0)
    ap.add_argument("--fps", type=int, default=24)
    ap.add_argument("--size", default="640x480")
    args = ap.parse_args()
    w, h = (int(v) for v in args.size.split("x"))
    n = int(args.seconds * args.fps)
    writer = cv2.VideoWriter(args.out, cv2.VideoWriter_fourcc(*"mp4v"), args.fps, (w, h))
    for i in range(n):
        frame = np.full((h, w, 3), (30, 30, 30), np.uint8)
        t = i / max(1, n - 1)
        cx = int(w * (0.3 + 0.4 * t))
        cy = int(h * 0.5 + 40 * np.sin(t * 6.28))
        draw_face(frame, cx, cy)
        mosaic(frame, cx - 45, cy - 45, 90, 90, block=12)  # 얼굴 위 모자이크
        writer.write(frame)
    writer.release()
    print(f"생성: {args.out} ({w}x{h}, {n} 프레임)")


if __name__ == "__main__":
    main()
