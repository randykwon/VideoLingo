# Demosaic PoC — Face Restoration Quality Evaluation

[한국어](README.md) | [English](README.en.md)

This Python orchestrator compares restoration models on real clips before they are integrated into the Swift app. It runs multiple backends and creates `comparison.mp4`, placing the source and every result side by side.

> **Important:** Mosaic censorship destroys information irreversibly. Output is generated reconstruction, not recovery, and a reconstructed face is not the real person's face. Use only footage you have the rights to process. This tool is intended for quality evaluation.

## Backends

| Backend | Requirement | Purpose |
|---|---|---|
| `passthrough` | Built in | Unchanged control image |
| `faces` | OpenCV; YuNet recommended | Face detection and simple tracking visualization |
| `realesrgan` | `realesrgan basicsr torch` | General deblocking/super-resolution fallback |
| `deepmosaics` | Repository and weights | Mosaic-specific restoration |
| `codeformer` | Repository and weights | Baseline face restoration |

Video-specific research models can later follow the same external-repository pattern.

## Installation

```bash
cd tools/demosaic-poc
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
pip install realesrgan basicsr torch torchvision  # optional
brew install ffmpeg
```

Optional external repositories:

```bash
git clone https://github.com/HypoX64/DeepMosaics ~/models/DeepMosaics
git clone https://github.com/sczhou/CodeFormer ~/models/CodeFormer
```

Download their weights according to each project's documentation. For better `faces` results, download OpenCV Zoo's `face_detection_yunet_2023mar.onnx` and pass it with `--yunet`.

## Usage

```bash
# Quick ten-second comparison
python demosaic_poc.py input.mp4 \
  --backends passthrough,faces,realesrgan \
  --seconds 10 --outdir out

# Compare dedicated models
python demosaic_poc.py input.mp4 \
  --backends passthrough,deepmosaics,codeformer \
  --deepmosaics-repo ~/models/DeepMosaics \
  --deepmosaics-weights ~/models/DeepMosaics/pretrained_models/clean_face_HD.pth \
  --codeformer-repo ~/models/CodeFormer \
  --outdir out
```

Outputs are written to `out/<backend>.mp4`, plus a side-by-side `out/comparison.mp4` containing the source audio.

## Key options

- `--backends`: comma-separated backends, ordered left to right; the source remains leftmost
- `--seconds N`: process only the first N seconds
- `--height H`: height of each comparison panel; default 480
- `--device cpu|mps|cuda`: inference device; automatic by default
- `--fidelity 0..1`: CodeFormer fidelity, from quality-first to source-shape-first

## Next step

Use the PoC to compare quality, identity flicker, and runtime. Then follow the model and integration phases in [the design document](../../docs/mosaic-removal/DESIGN.en.md).
