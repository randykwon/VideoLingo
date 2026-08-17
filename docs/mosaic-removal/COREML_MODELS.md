# 얼굴 모자이크 제거 — Core ML 모델 준비/배치 (Phase 2)

[한국어](COREML_MODELS.md) | [English](COREML_MODELS.en.md)

앱의 모자이크 제거 파이프라인(`DemosaicPipeline`)은 `Models/Demosaic/` 폴더에서 Core ML 모델을 자동으로 찾아 사용합니다.
모델이 없으면 Core Image 기본 복원(baseline)으로 폴백합니다.

## 배치 위치

```
~/Library/Application Support/VideoLingo/Models/Demosaic/
├── realesrgan.mlpackage     (또는 realesrgan.mlmodelc)   ← "Real-ESRGAN" 선택 시
└── codeformer.mlpackage     (또는 codeformer.mlmodelc)   ← "CodeFormer" 선택 시
```

- 파일명은 소문자로 정확히 `realesrgan` / `codeformer` 여야 합니다.
- `.mlpackage`를 넣으면 최초 실행 시 앱이 자동으로 컴파일(`.mlmodelc`)합니다. 미리 컴파일한 `.mlmodelc`를 넣어도 됩니다.
- 설정 › 모델 파일 › "모델 폴더 열기"로 `Models` 폴더를 연 뒤 `Demosaic` 하위에 넣으세요.

## 모델 요구사항 (중요)

`DemosaicPipeline`은 Vision(`VNCoreMLRequest`)으로 실행하며 **이미지 입력 → 이미지 출력** 모델을 기대합니다.
즉 출력이 `VNPixelBufferObservation`(이미지)로 나와야 합니다. 출력이 `MLMultiArray`인 모델은 그대로는 동작하지 않으므로,
변환 시 **출력 타입을 이미지로** 지정해야 합니다.

- 입력: 컬러 이미지(임의 크기 → Vision이 `scaleFill`로 맞춤)
- 출력: 컬러 이미지 (초해상 모델이면 더 큰 크기로 나와도 됨 — 파이프라인이 ROI 크기로 되돌립니다)

## 변환 예시

### Real-ESRGAN (PyTorch → Core ML, 이미지 출력)

```python
# pip install torch coremltools basicsr realesrgan pillow numpy
import torch, coremltools as ct
from basicsr.archs.rrdbnet_arch import RRDBNet

net = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=4)
sd = torch.load("RealESRGAN_x4plus.pth", map_location="cpu")
net.load_state_dict(sd.get("params_ema", sd.get("params", sd)), strict=True)
net.eval()

# 입력 정규화(0..1)를 모델에 포함하려면 래퍼를 두는 것이 좋습니다. 여기서는 기본 예시.
example = torch.rand(1, 3, 128, 128)
ts = torch.jit.trace(net, example)

mlmodel = ct.convert(
    ts,
    inputs=[ct.ImageType(name="input", shape=(1, 3, 128, 128), scale=1/255.0)],
    outputs=[ct.ImageType(name="output")],          # ★ 이미지 출력으로 지정
    minimum_deployment_target=ct.target.macOS14,
    compute_units=ct.ComputeUnit.ALL,
)
mlmodel.save("realesrgan.mlpackage")
```

> 고정 입력 크기(예: 128×128)로 변환하면 Vision이 ROI를 그 크기로 스케일해 넣고, 파이프라인이 결과를 ROI로 되돌립니다.
> 가변 크기(`RangeDim`)로 변환하면 더 선명하지만 변환·성능이 까다롭습니다. 처음엔 고정 크기를 권장합니다.

### CodeFormer

CodeFormer는 얼굴 정렬(align)·코드북 등 전처리가 있어 단순 트레이스 변환이 까다롭습니다.
초기에는 Real-ESRGAN으로 파이프라인을 검증하고, CodeFormer는 `tools/demosaic-poc`(파이썬)로 품질을 확인한 뒤
정렬 로직까지 포함해 변환/포팅하는 것을 권장합니다. (docs/mosaic-removal/DESIGN.md §6 참고)

## 확인 방법

모델을 넣고 시트에서 해당 모델을 선택해 실행하면, 진행 메시지 앞부분에 활성 복원기가 표시됩니다:
- `모자이크 제거 준비 중 · Core ML: realesrgan` → 모델 정상 로드
- `모자이크 제거 준비 중 · Core Image 기본 복원` → 모델 미검출(폴백)

## 성능
- 프레임마다 검출된 얼굴 ROI 각각에 대해 추론합니다. 고정 128×128 입력이면 M-시리즈에서 프레임당 수십 ms~수백 ms 수준.
- 긴 영상은 오프라인 배치로 처리되며 진행률이 표시됩니다.
