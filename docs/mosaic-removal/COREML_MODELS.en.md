# Face Demosaicing — Preparing Core ML Models (Phase 2)

[한국어](COREML_MODELS.md) | [English](COREML_MODELS.en.md)

The app's `DemosaicPipeline` automatically looks for Core ML models in `Models/Demosaic/`. When no compatible model is found, it falls back to the baseline Core Image restoration path.

## Model location

```text
~/Library/Application Support/VideoLingo/Models/Demosaic/
├── realesrgan.mlpackage     (or realesrgan.mlmodelc)
└── codeformer.mlpackage     (or codeformer.mlmodelc)
```

- Use the exact lowercase base names `realesrgan` and `codeformer`.
- An `.mlpackage` is compiled to `.mlmodelc` on first use. A precompiled `.mlmodelc` directory also works.
- Open **Settings → Model Files → Open Model Folder**, then place the files in its `Demosaic` subdirectory.

## Model contract

`DemosaicPipeline` runs models through Vision (`VNCoreMLRequest`) and expects an **image input and image output**. The output must become a `VNPixelBufferObservation`. Models that only return `MLMultiArray` cannot be used directly; export them with an image output.

- Input: color image; Vision resizes it with `scaleFill`
- Output: color image; super-resolution output may be larger because the pipeline scales it back to the ROI

## Real-ESRGAN conversion example

```python
# pip install torch coremltools basicsr realesrgan pillow numpy
import torch, coremltools as ct
from basicsr.archs.rrdbnet_arch import RRDBNet

net = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64,
              num_block=23, num_grow_ch=32, scale=4)
state = torch.load("RealESRGAN_x4plus.pth", map_location="cpu")
net.load_state_dict(state.get("params_ema", state.get("params", state)), strict=True)
net.eval()

example = torch.rand(1, 3, 128, 128)
traced = torch.jit.trace(net, example)
model = ct.convert(
    traced,
    inputs=[ct.ImageType(name="input", shape=(1, 3, 128, 128), scale=1/255.0)],
    outputs=[ct.ImageType(name="output")],
    minimum_deployment_target=ct.target.macOS14,
    compute_units=ct.ComputeUnit.ALL,
)
model.save("realesrgan.mlpackage")
```

A fixed input size such as 128×128 is the easiest starting point: Vision scales each ROI to that size and the pipeline scales the result back. Flexible dimensions may preserve more detail but make conversion and performance tuning harder.

## CodeFormer

CodeFormer requires face alignment and codebook-related preprocessing, so a simple traced conversion is usually insufficient. Validate quality with Real-ESRGAN first, then test CodeFormer through `tools/demosaic-poc` before porting its alignment pipeline. See [DESIGN.en.md](DESIGN.en.md#6-model-porting-constraints).

## Verification

After installing a model, select it in the demosaicing sheet and start a job:

- `Preparing demosaicing · Core ML: realesrgan`: model loaded successfully
- `Preparing demosaicing · Core Image baseline`: model was not found and fallback is active

## Performance

Inference runs once for every detected face ROI in every frame. A fixed 128×128 input commonly takes tens to hundreds of milliseconds per frame on M-series Macs. Long videos are processed as offline jobs with visible progress.
