# Demosaic PoC — 얼굴 모자이크 제거 품질 검증 도구

[한국어](README.md) | [English](README.en.md)

Swift 앱에 통합하기 **전에**, 실제 클립으로 어떤 복원 모델이 쓸만한지 오프라인에서 빠르게 비교하는 파이썬 오케스트레이터입니다.
여러 백엔드를 돌려 **원본 + 각 결과를 나란히 붙인 비교 영상(comparison.mp4)** 을 만들어 줍니다.

> ⚠️ 현실 고지
> - 모자이크는 비가역 손실입니다. 결과는 **복구가 아니라 생성**이며, 얼굴은 **실제 인물의 얼굴이 아닙니다.**
> - 본인이 권리를 가진 영상에만 사용하세요. 타인 식별/검열 해제는 법적·윤리적 문제가 있습니다.
> - 이 도구는 **품질 판단용**입니다. 만족스러우면 승자 모델을 Core ML/MLX로 변환해 앱(`docs/mosaic-removal/DESIGN.md`)에 통합합니다.

## 백엔드

| 백엔드 | 설치/필요 | 성격 |
|---|---|---|
| `passthrough` | 없음(기본 내장) | 원본 그대로(대조군) |
| `faces` | OpenCV(+YuNet 모델 권장) | 얼굴 검출/간이 트래킹 시각화(검증용) |
| `realesrgan` | `pip install realesrgan basicsr torch` | 일반 디블록/초해상(얼굴엔 약함, 폴백) |
| `deepmosaics` | DeepMosaics 레포+가중치 | **모자이크 전용** 디모자이크 |
| `codeformer` | CodeFormer 레포+가중치 | **얼굴 복원** 베이스라인 |

영상 전용 얼굴 복원 SOTA(DicFace/KEEP/DVFace 등)는 연구 레포라, `codeformer`와 동일한 `--*-repo` 패턴으로 나중에 추가하면 됩니다(§확장).

## 설치

```bash
cd tools/demosaic-poc
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt          # opencv/numpy (경량 기본)
# 선택: 온디바이스 초해상 백엔드
pip install realesrgan basicsr torch torchvision
brew install ffmpeg                        # 오디오 먹싱/인코딩에 필요
```

외부 레포(무거운 백엔드, 필요 시):
```bash
# DeepMosaics (모자이크 전용)
git clone https://github.com/HypoX64/DeepMosaics ~/models/DeepMosaics
#   → clean_face_HD.pth 등 가중치 다운로드(레포 README 참고)

# CodeFormer (얼굴 복원)
git clone https://github.com/sczhou/CodeFormer ~/models/CodeFormer
#   → 레포의 스크립트로 가중치 다운로드
```

YuNet 얼굴 검출 모델(선택, `faces` 백엔드 품질↑):
`face_detection_yunet_2023mar.onnx` 를 받아 `--yunet` 로 경로 지정(OpenCV Zoo).

## 사용

```bash
# 빠른 확인: 앞 10초만, 원본 + realesrgan + 얼굴검출 나란히 비교
python demosaic_poc.py input.mp4 \
  --backends passthrough,faces,realesrgan \
  --seconds 10 --outdir out

# 전용 모델까지 비교 (레포 경로 지정)
python demosaic_poc.py input.mp4 \
  --backends passthrough,deepmosaics,codeformer \
  --deepmosaics-repo ~/models/DeepMosaics \
  --deepmosaics-weights ~/models/DeepMosaics/pretrained_models/clean_face_HD.pth \
  --codeformer-repo ~/models/CodeFormer \
  --outdir out
```

결과: `out/<backend>.mp4` (백엔드별 결과) + `out/comparison.mp4` (원본 오디오 포함, 나란히 비교).

## 옵션 요약
- `--backends` 쉼표 구분 목록(순서대로 좌→우 배치, 원본은 항상 맨 왼쪽).
- `--seconds N` 앞 N초만(빠른 반복용). 생략 시 전체.
- `--height H` 비교 영상 각 패널 높이(기본 480).
- `--device cpu|mps|cuda` realesrgan 등 추론 장치(기본 자동).
- `--fidelity 0..1` CodeFormer 충실도(0=화질 우선, 1=원형 유지).

## 다음 단계
이 PoC로 (1) 어느 모델이 나은지, (2) identity flicker가 허용 범위인지, (3) 소요 시간을 확인한 뒤,
`docs/mosaic-removal/DESIGN.md` §6/§9 순서대로 앱 통합을 진행합니다.
