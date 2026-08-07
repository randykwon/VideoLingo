import AVFoundation
import CoreImage
import CoreML
import CoreVideo
import Foundation
import Vision
import VideoLingoCore

/// 영상 얼굴 모자이크 제거 파이프라인 (Phase 1).
///
/// 프레임 디코드(AVAssetReader) → Vision 얼굴 검출 → 영역 복원 → 인코딩(AVAssetWriter) → 원본 오디오 먹싱.
/// 복원기는 프로토콜로 분리돼 있어, 현재는 Core Image 기반 baseline이 동작하고
/// 이후 Core ML(Real-ESRGAN/CodeFormer) 복원기를 그 자리에 끼우면 됩니다.
///
/// 주의: 모자이크는 비가역 손실이라 결과는 복구가 아닌 생성이며, 얼굴은 실제 인물이 아닙니다.
final class DemosaicPipeline: @unchecked Sendable {
    private let onSnapshot: @Sendable (JobSnapshot) -> Void
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(onSnapshot: @escaping @Sendable (JobSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
    }

    func run(_ request: StartDemosaicRequest) async {
        var snapshot = JobSnapshot(id: request.jobID)
        var accessedURL: URL?
        do {
            let mediaURL = try resolveMediaURL(request, accessedURL: &accessedURL)
            defer { accessedURL?.stopAccessingSecurityScopedResource() }
            try FileManager.default.createDirectory(at: request.workspaceURL, withIntermediateDirectories: true)

            let asset = AVURLAsset(url: mediaURL)
            let duration = try await asset.load(.duration)
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoLingoError.mediaHasNoVideo
            }
            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let frameRate = try await videoTrack.load(.nominalFrameRate)
            let fps = frameRate > 0 ? Double(frameRate) : 30
            let totalFrames = max(1, Int((duration.seconds * fps).rounded()))
            let width = Int(abs(naturalSize.width).rounded())
            let height = Int(abs(naturalSize.height).rounded())
            guard width > 0, height > 0 else { throw VideoLingoError.mediaHasNoVideo }

            // 읽기
            let reader = try AVAssetReader(asset: asset)
            let readerOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            readerOutput.alwaysCopiesSampleData = false
            reader.add(readerOutput)

            // 쓰기 (영상만, 이후 오디오 먹싱)
            let videoOnlyURL = request.workspaceURL.appending(path: "demosaic-video-only.mp4")
            try? FileManager.default.removeItem(at: videoOnlyURL)
            let writer = try AVAssetWriter(outputURL: videoOnlyURL, fileType: .mp4)
            let writerInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height
                ]
            )
            writerInput.expectsMediaDataInRealTime = false
            writerInput.transform = transform
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: writerInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
            )
            writer.add(writerInput)

            guard reader.startReading() else {
                throw reader.error ?? VideoLingoError.mediaHasNoVideo
            }
            guard writer.startWriting() else {
                throw writer.error ?? VideoLingoError.mediaHasNoVideo
            }
            writer.startSession(atSourceTime: .zero)

            let restorer = Self.makeRestorer(request.options, modelsURL: request.modelsURL)
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)

            snapshot.status = .extracting
            snapshot.totalChunks = totalFrames
            snapshot.progress = 0
            snapshot.message = "모자이크 제거 준비 중 · \(restorer.displayName)"
            snapshot.updatedAt = .now
            publish(snapshot)

            var frameIndex = 0
            while reader.status == .reading, let sample = readerOutput.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)

                var image = CIImage(cvPixelBuffer: pixelBuffer)
                let rois = request.options.restoreFaceOnly
                    ? detectFaceROIs(pixelBuffer, width: width, height: height)
                    : [bounds]
                for roi in rois {
                    image = restorer.restore(image, roi: roi.integral.intersection(bounds), fidelity: request.options.fidelity)
                }
                if request.options.watermarkSynthetic {
                    image = watermark(image, bounds: bounds)
                }

                if let outBuffer = renderPixelBuffer(image, width: width, height: height, pool: adaptor.pixelBufferPool, bounds: bounds) {
                    while !writerInput.isReadyForMoreMediaData {
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                    adaptor.append(outBuffer, withPresentationTime: pts)
                }

                frameIndex += 1
                if frameIndex % 5 == 0 || frameIndex >= totalFrames {
                    snapshot.status = .synthesizing
                    snapshot.currentChunk = frameIndex
                    snapshot.totalChunks = max(totalFrames, frameIndex)
                    snapshot.progress = min(0.98, Double(frameIndex) / Double(max(totalFrames, frameIndex)))
                    snapshot.message = "모자이크 제거 \(frameIndex)/\(snapshot.totalChunks) 프레임"
                    snapshot.updatedAt = .now
                    publish(snapshot)
                }
            }

            writerInput.markAsFinished()
            await writer.finishWriting()
            if reader.status == .failed { throw reader.error ?? VideoLingoError.mediaHasNoVideo }
            if writer.status == .failed { throw writer.error ?? VideoLingoError.mediaHasNoVideo }

            snapshot.message = "오디오 합치는 중"
            snapshot.updatedAt = .now
            publish(snapshot)

            let outputName = "demosaiced-\(mediaURL.deletingPathExtension().lastPathComponent).mp4"
            let finalURL = request.workspaceURL.appending(path: outputName)
            try await muxOriginalAudio(
                videoURL: videoOnlyURL,
                originalAsset: asset,
                outputURL: finalURL,
                synthetic: request.options.watermarkSynthetic
            )
            try? FileManager.default.removeItem(at: videoOnlyURL)

            snapshot.status = .completed
            snapshot.progress = 1
            snapshot.currentChunk = snapshot.totalChunks
            snapshot.message = "모자이크 제거 완료 · \(outputName)"
            snapshot.updatedAt = .now
            publish(snapshot)
        } catch is CancellationError {
            snapshot.status = .cancelled
            snapshot.message = "모자이크 제거가 취소되었습니다."
            snapshot.updatedAt = .now
            publish(snapshot)
        } catch {
            snapshot.status = .failed
            snapshot.message = "모자이크 제거 실패"
            snapshot.error = error.localizedDescription
            snapshot.updatedAt = .now
            publish(snapshot)
        }
    }

    // MARK: - 복원기

    private static func makeRestorer(_ options: DemosaicOptions, modelsURL: URL) -> DemosaicRestorer {
        // modelsURL/Demosaic/<name>.mlmodelc(또는 .mlpackage)가 있으면 Core ML 복원기를 사용하고,
        // 없거나 로딩 실패 시 Core Image baseline으로 폴백합니다. (docs/mosaic-removal/COREML_MODELS.md)
        let dir = modelsURL.appending(path: "Demosaic", directoryHint: .isDirectory)
        let name: String? = switch options.model {
        case .classical: nil
        case .realESRGAN: "realesrgan"
        case .codeFormer: "codeformer"
        }
        if let name, let coreML = CoreMLDemosaicRestorer(modelDirectory: dir, name: name) {
            return coreML
        }
        return ClassicalDemosaicRestorer()
    }

    // MARK: - 얼굴 검출

    private func detectFaceROIs(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> [CGRect] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        let request = VNDetectFaceRectanglesRequest()
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let w = CGFloat(width), h = CGFloat(height)
        return (request.results ?? []).map { face in
            // Vision·CoreImage 모두 좌하단 원점 정규화 → 픽셀 좌표로 변환 후 여유(20%) 확장
            let box = face.boundingBox
            let pad: CGFloat = 0.2
            let rect = CGRect(
                x: (box.minX - box.width * pad) * w,
                y: (box.minY - box.height * pad) * h,
                width: box.width * (1 + pad * 2) * w,
                height: box.height * (1 + pad * 2) * h
            )
            return rect
        }
    }

    // MARK: - 합성 표식

    private func watermark(_ image: CIImage, bounds: CGRect) -> CIImage {
        let size = max(6, bounds.width * 0.012)
        let marker = CIImage(color: CIColor(red: 1, green: 0.55, blue: 0))
            .cropped(to: CGRect(x: bounds.minX + size, y: bounds.minY + size, width: size, height: size))
        return marker.composited(over: image)
    }

    // MARK: - 렌더링

    private func renderPixelBuffer(_ image: CIImage, width: Int, height: Int, pool: CVPixelBufferPool?, bounds: CGRect) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        }
        guard let out = buffer else { return nil }
        ciContext.render(image, to: out, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        return out
    }

    // MARK: - 오디오 먹싱

    private func muxOriginalAudio(videoURL: URL, originalAsset: AVAsset, outputURL: URL, synthetic: Bool) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let composition = AVMutableComposition()
        let processed = AVURLAsset(url: videoURL)

        if let processedVideo = try await processed.loadTracks(withMediaType: .video).first,
           let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let range = CMTimeRange(start: .zero, duration: try await processed.load(.duration))
            try videoTrack.insertTimeRange(range, of: processedVideo, at: .zero)
            videoTrack.preferredTransform = try await processedVideo.load(.preferredTransform)
        }
        if let sourceAudio = try await originalAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let range = CMTimeRange(start: .zero, duration: try await originalAsset.load(.duration))
            try? audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            // 오디오 합성 실패 시 최소한 영상만이라도 결과로 남깁니다.
            try FileManager.default.copyItem(at: videoURL, to: outputURL)
            return
        }
        if synthetic {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierDescription
            item.value = "AI로 재구성된 합성 영상 (VideoLingo)" as NSString
            exporter.metadata = [item]
        }
        try await exporter.export(to: outputURL, as: .mp4)
    }

    // MARK: - 보안 스코프 URL 복원

    private func resolveMediaURL(_ request: StartDemosaicRequest, accessedURL: inout URL?) throws -> URL {
        guard let bookmark = request.securityScopedBookmark else { return request.mediaURL }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if url.startAccessingSecurityScopedResource() { accessedURL = url }
            return url
        } catch {
            guard FileManager.default.isReadableFile(atPath: request.mediaURL.path) else { throw error }
            return request.mediaURL
        }
    }

    private func publish(_ snapshot: JobSnapshot) {
        onSnapshot(snapshot)
    }
}

// MARK: - 복원기 프로토콜

protocol DemosaicRestorer: Sendable {
    var displayName: String { get }
    /// roi 영역(픽셀 좌표, 좌하단 원점)을 복원해 원본 위에 합성한 새 이미지를 반환합니다.
    func restore(_ image: CIImage, roi: CGRect, fidelity: Double) -> CIImage
}

/// Core ML 이미지→이미지 복원기(Real-ESRGAN/CodeFormer 등). 모델은 Vision으로 실행하며,
/// ROI를 잘라 추론한 결과를 원본 위 해당 영역에 다시 합성합니다.
/// 모델 출력이 이미지가 아니거나 추론이 실패하면 원본 ROI를 그대로 두어 파이프라인을 깨지 않습니다.
final class CoreMLDemosaicRestorer: DemosaicRestorer, @unchecked Sendable {
    private let model: VNCoreMLModel
    let displayName: String

    init?(modelDirectory: URL, name: String) {
        guard let loaded = Self.load(directory: modelDirectory, name: name) else { return nil }
        self.model = loaded
        self.displayName = "Core ML: \(name)"
    }

    private static func load(directory: URL, name: String) -> VNCoreMLModel? {
        let fm = FileManager.default
        let compiled = directory.appending(path: "\(name).mlmodelc")
        let package = directory.appending(path: "\(name).mlpackage")
        var url: URL?
        if fm.fileExists(atPath: compiled.path) {
            url = compiled
        } else if fm.fileExists(atPath: package.path) {
            url = try? MLModel.compileModel(at: package)   // 최초 1회 컴파일(임시 경로)
        }
        guard let modelURL = url,
              let mlModel = try? MLModel(contentsOf: modelURL),
              let vnModel = try? VNCoreMLModel(for: mlModel) else { return nil }
        return vnModel
    }

    func restore(_ image: CIImage, roi: CGRect, fidelity: Double) -> CIImage {
        guard roi.width >= 8, roi.height >= 8 else { return image }
        let crop = image.cropped(to: roi)
        // ROI를 원점(0,0) 기준으로 옮겨 모델 입력으로 사용
        let normalized = crop.transformed(by: CGAffineTransform(translationX: -roi.minX, y: -roi.minY))

        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(ciImage: normalized, options: [:])
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first as? VNPixelBufferObservation else {
            return image
        }
        var restored = CIImage(cvPixelBuffer: result.pixelBuffer)
        // 모델 출력 크기를 ROI 크기에 맞춰 스케일 후, 원래 위치로 이동
        let outExtent = restored.extent
        if outExtent.width > 0, outExtent.height > 0 {
            let sx = roi.width / outExtent.width
            let sy = roi.height / outExtent.height
            restored = restored
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .transformed(by: CGAffineTransform(translationX: roi.minX, y: roi.minY))
        }
        return restored.cropped(to: roi).composited(over: image)
    }
}

/// Core Image 기반 baseline. 진짜 모자이크 복원은 아니고, 블록 경계를 완화하고 디테일을 강조하는
/// 전처리 수준입니다. Core ML 복원기가 준비되면 동일 프로토콜로 교체합니다.
struct ClassicalDemosaicRestorer: DemosaicRestorer {
    var displayName: String { "Core Image 기본 복원" }

    func restore(_ image: CIImage, roi: CGRect, fidelity: Double) -> CIImage {
        guard roi.width >= 4, roi.height >= 4 else { return image }
        let region = image.cropped(to: roi)

        // 1) 블록 경계 완화(가우시안) → 2) 디테일 복원(언샤프) → 3) 채도/대비 소폭 보정
        let blurRadius = max(1.0, min(6.0, roi.width * 0.02)) * (1.0 - fidelity * 0.5)
        let softened = region
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: roi)
        let sharpened = softened.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 2.5,
            kCIInputIntensityKey: 0.8
        ])
        let graded = sharpened.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.05,
            kCIInputContrastKey: 1.03
        ])
        return graded.cropped(to: roi).composited(over: image)
    }
}
