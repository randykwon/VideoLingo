# VideoLingo Face Demosaicing Design — Swift/XPC Integration

[한국어](DESIGN.md) | [English](DESIGN.en.md)

> Target: offline, quality-first restoration of mosaiced people and faces  
> Status: design draft, contingent on Phase 0 PoC results

## 0. Technical and ethical constraints

- Mosaic censorship is an irreversible loss. Output is a plausible generation, not source recovery. A reconstructed face is not the real person's face.
- Process only footage you have the rights to use. Identifying other people or removing censorship may create legal, privacy, and platform-policy risks.
- The module should mark output as synthetic through metadata and an optional visible watermark by default.

## 1. Architecture

The feature reuses the existing app architecture:

```text
VideoLingo.app (UI)
   │ StartDemosaicRequest (XPC)
   ▼
VideoLingoAIService.xpc ── DemosaicPipeline
   │ AVAssetReader → CVPixelBuffer frames
   │   ├─ Vision face detection and tracking
   │   ├─ optional mosaic removal
   │   ├─ selected face restoration model
   │   └─ temporal stabilization
   │ AVAssetWriter → demosaiced-<name>.mp4 + source audio
   ▼
JobSnapshot progress through the existing polling mechanism
```

Reusable components include the XPC task queue in `ServiceDelegate.swift`, media composition patterns in `MediaPipeline.swift`, managed-model infrastructure, and `JobSnapshot` progress reporting.

## 2. Shared data model

The shared core defines a model choice, processing options, and an XPC request:

```swift
public enum DemosaicModel: String, Codable, Sendable, CaseIterable {
    case deepMosaics
    case codeFormer
    case dicFaceVideo
    case realESRGAN
}

public struct DemosaicOptions: Codable, Sendable, Equatable {
    public var model: DemosaicModel
    public var restoreFaceOnly: Bool
    public var fidelity: Double
    public var temporalStabilization: Bool
    public var manualROIs: [CGRect]?
    public var watermarkSynthetic: Bool
}

public struct StartDemosaicRequest: Codable, Sendable {
    public var jobID: UUID
    public var mediaURL: URL
    public var securityScopedBookmark: Data?
    public var options: DemosaicOptions
    public var databaseURL: URL
    public var workspaceURL: URL
    public var uiLanguageCode: String?
}
```

`VideoLingoAIServiceProtocol` adds `startDemosaic(_:withReply:)`. Snapshot and cancellation APIs continue using the shared job-ID namespace. A demosaicing model category is added to managed models.

## 3. Pipeline

### 3.1 Frame I/O

- Read BGRA pixel buffers using `AVAssetReader` and `AVAssetReaderTrackOutput`.
- Preserve source frame rate and timescale with `AVAssetWriter` and a pixel-buffer adaptor.
- Preserve source audio by passthrough or final composition following `DubbedVideoExporter`.
- Save frame-range checkpoints so long jobs can resume.

### 3.2 Detection and tracking

- Detect faces on-device with `VNDetectFaceRectanglesRequest`.
- Assign stable track IDs through `VNTrackObjectRequest` or IoU matching.
- Process face ROIs only when requested; otherwise process the full frame or manual ROIs.

### 3.3 Two-stage restoration

1. Optionally remove coarse mosaic blocks with a dedicated model.
2. Align each face ROI, run the selected restoration model, reverse the alignment, and blend the result into the frame with feathering or Poisson blending.

Core ML handles practical embedded models such as CodeFormer or Real-ESRGAN. Heavier video restoration may use MLX or an offline worker.

### 3.4 Temporal consistency

Identity flicker is the primary quality risk. Mitigations, in increasing order of cost:

1. Reuse parameters and codebook state for each face track.
2. Warp neighboring results with optical flow and blend high-frequency detail.
3. Use a video-native restoration model capable of temporal propagation.

## 4. App UI

- Entry point: **Remove Face Mosaic…** opens a focused sheet.
- Controls: model, face/full-frame scope, fidelity, stabilization, optional manual ROI, watermark, estimated cost, and model-download state.
- Progress: reuse `JobSnapshot`, including specific frame counts.
- Result: reveal or play `demosaiced-<name>.mp4`.
- Localization: send `uiLanguageCode` so service progress messages match the app language.

## 5. Model management

- Add a demosaicing model kind and a manifest per model.
- Download Core ML packages or MLX weights on first use and support offline execution afterward.
- Store files under `~/Library/Application Support/VideoLingo/Models/Demosaic/`.
- See [COREML_MODELS.en.md](COREML_MODELS.en.md) for the current Core ML contract and placement instructions.

## 6. Model-porting constraints

| Model | Type | Embedded feasibility | Notes |
|---|---|---|---|
| Real-ESRGAN | GAN | Available in Core ML/MLX forms | Useful fallback; weak face identity |
| CodeFormer | Transformer + VQ | Possible with careful conversion | Practical image baseline |
| DeepMosaics | pix2pix-style GAN | Requires PyTorch conversion | Mosaic-specific detection/restoration |
| DicFace/KEEP/DVFace | video codebook/diffusion | No ready app port | Best potential quality; major porting effort |

Recommended phases:

- **Phase 1 — embedded MVP:** Real-ESRGAN or CodeFormer through Core ML.
- **Phase 2 — mosaic-specific:** convert and integrate DeepMosaics.
- **Phase 3 — highest quality:** port a video face-restoration model or delegate offline inference to a bundled worker.

The Python PoC can become that worker if a native port is not practical.

## 7. Safeguards

- Add `com.videolingo.synthetic=true` metadata and offer a visible corner watermark.
- Show a one-time rights and synthetic-output notice before processing.
- Never retain source frames in logs; clean temporary frame data when a job completes.

## 8. Expected performance

- Real-ESRGAN: approximately 0.2–2 seconds per frame, depending on hardware and ROI size.
- Diffusion face restoration: several to tens of seconds per frame.

Long clips therefore require background execution, cancellation, checkpoints, and determinate progress.

## 9. Implementation checklist

- [ ] Evaluate actual clips and choose models with `tools/demosaic-poc`
- [ ] Finalize shared options, request types, and XPC API
- [ ] Implement frame I/O, face detection, and tracking
- [ ] Integrate Real-ESRGAN/CodeFormer through Core ML
- [ ] Add manual ROI selection, progress, and export UI
- [ ] Add optical-flow stabilization
- [ ] Convert DeepMosaics
- [ ] Port a video model or integrate an offline worker
- [ ] Add synthetic metadata, watermark, and rights notice

## References

- [DeepMosaics](https://github.com/HypoX64/DeepMosaics)
- [Real-ESRGAN for MLX](https://huggingface.co/mlx-community/Real-ESRGAN-x2plus)
- [DicFace](https://arxiv.org/html/2506.13355)
- [Discrete Prior-based Temporal-coherent Blind Face Video Restoration](https://arxiv.org/pdf/2501.09960)
