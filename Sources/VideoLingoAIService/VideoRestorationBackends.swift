import AVFoundation
import CoreImage
import CoreML
import CoreVideo
import Foundation
import Vision
import VideoLingoCore

// MARK: - CoreML 컴파일 캐시 유틸리티

enum CoreMLModelLoader {
    static func loadCompiledModel(directory: URL, name: String) -> MLModel? {
        let fm = FileManager.default
        let cachedCompiled = directory.appending(path: "\(name).mlmodelc")
        let package = directory.appending(path: "\(name).mlpackage")
        let config = MLModelConfiguration()
        config.computeUnits = .all

        if fm.fileExists(atPath: cachedCompiled.path),
           let loaded = try? MLModel(contentsOf: cachedCompiled, configuration: config) {
            return loaded
        }
        guard fm.fileExists(atPath: package.path) else { return nil }
        guard let tempCompiled = try? MLModel.compileModel(at: package) else { return nil }
        // 다음 실행 시 재컴파일을 피하기 위해 Models/Demosaic/<name>.mlmodelc 로 캐시합니다.
        try? fm.removeItem(at: cachedCompiled)
        if (try? fm.copyItem(at: tempCompiled, to: cachedCompiled)) != nil,
           let loaded = try? MLModel(contentsOf: cachedCompiled, configuration: config) {
            try? fm.removeItem(at: tempCompiled)
            return loaded
        }
        return try? MLModel(contentsOf: tempCompiled, configuration: config)
    }
}

// MARK: - Track 1A: LaMa CoreML (이미지 + 마스크 인페인팅)

final class CoreMLLaMaRestorer: DemosaicRestorer, @unchecked Sendable {
    private let mlModel: MLModel
    private let imageFeatureName: String
    private let maskFeatureName: String
    private let outputFeatureName: String
    private let imageSize: CGSize
    private let maskSize: CGSize
    private let maskPixelFormat: OSType
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    let displayName: String

    init?(modelDirectory: URL, name: String = "lama") {
        guard let loaded = CoreMLModelLoader.loadCompiledModel(directory: modelDirectory, name: name) else {
            return nil
        }
        let inputs = loaded.modelDescription.inputDescriptionsByName
        let outputs = loaded.modelDescription.outputDescriptionsByName

        let imageInputs = inputs.filter { $0.value.type == .image }
        guard imageInputs.count >= 2 else { return nil }

        let maskEntry = imageInputs.first { $0.key.localizedCaseInsensitiveContains("mask") }
            ?? imageInputs.sorted(by: { $0.key < $1.key }).last
        let imageEntry = imageInputs.first { $0.key != maskEntry?.key }
        guard let imgEntry = imageEntry, let mskEntry = maskEntry else { return nil }

        let imgConstraint = imgEntry.value.imageConstraint
        let mskConstraint = mskEntry.value.imageConstraint
        let outEntry = outputs.first { $0.value.type == .image } ?? outputs.first
        guard let outputName = outEntry?.key else { return nil }

        self.mlModel = loaded
        self.imageFeatureName = imgEntry.key
        self.maskFeatureName = mskEntry.key
        self.outputFeatureName = outputName
        self.imageSize = CGSize(
            width: max(64, imgConstraint?.pixelsWide ?? 800),
            height: max(64, imgConstraint?.pixelsHigh ?? 800)
        )
        self.maskSize = CGSize(
            width: max(64, mskConstraint?.pixelsWide ?? 800),
            height: max(64, mskConstraint?.pixelsHigh ?? 800)
        )
        self.maskPixelFormat = mskConstraint?.pixelFormatType ?? kCVPixelFormatType_OneComponent8
        self.displayName = "Core ML: LaMa (\(Int(self.imageSize.width))×\(Int(self.imageSize.height)))"
    }

    func restore(_ image: CIImage, roi: CGRect, fidelity: Double) -> CIImage {
        let bounds = image.extent
        guard roi.width >= 8, roi.height >= 8, bounds.width > 0, bounds.height > 0 else { return image }

        // LaMa는 주변 배경 문맥이 필요하므로 ROI보다 넓은 정사각 문맥 패치를 잘라 추론합니다.
        let contextSide = max(roi.width, roi.height) * 2.4
        let clampedSide = min(max(bounds.width, bounds.height), max(128, contextSide))
        var contextRect = CGRect(
            x: roi.midX - clampedSide / 2,
            y: roi.midY - clampedSide / 2,
            width: clampedSide,
            height: clampedSide
        )
        if contextRect.minX < bounds.minX { contextRect.origin.x = bounds.minX }
        if contextRect.minY < bounds.minY { contextRect.origin.y = bounds.minY }
        if contextRect.maxX > bounds.maxX { contextRect.origin.x = max(bounds.minX, bounds.maxX - contextRect.width) }
        if contextRect.maxY > bounds.maxY { contextRect.origin.y = max(bounds.minY, bounds.maxY - contextRect.height) }
        contextRect = contextRect.intersection(bounds).integral
        guard contextRect.width >= 16, contextRect.height >= 16 else { return image }

        let contextCrop = image
            .cropped(to: contextRect)
            .transformed(by: CGAffineTransform(translationX: -contextRect.minX, y: -contextRect.minY))

        let scaledInput = contextCrop.transformed(by: CGAffineTransform(
            scaleX: imageSize.width / contextRect.width,
            y: imageSize.height / contextRect.height
        ))
        guard let imageBuffer = renderBuffer(
            scaledInput,
            width: Int(imageSize.width),
            height: Int(imageSize.height),
            pixelFormat: kCVPixelFormatType_32BGRA
        ) else {
            return image
        }

        // 마스크: 문맥 패치 기준 검정 배경 + ROI(약간 확장) 흰색
        let pad = max(4, min(14, min(roi.width, roi.height) * 0.08))
        let localROI = CGRect(
            x: roi.minX - contextRect.minX - pad,
            y: roi.minY - contextRect.minY - pad,
            width: roi.width + pad * 2,
            height: roi.height + pad * 2
        ).intersection(CGRect(origin: .zero, size: contextRect.size))

        let maskCanvas = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: contextRect.size))
        let maskPatch = CIImage(color: .white).cropped(to: localROI)
        let maskLocal = maskPatch.composited(over: maskCanvas)
        let scaledMask = maskLocal.transformed(by: CGAffineTransform(
            scaleX: maskSize.width / contextRect.width,
            y: maskSize.height / contextRect.height
        ))
        guard let maskBuffer = renderBuffer(
            scaledMask,
            width: Int(maskSize.width),
            height: Int(maskSize.height),
            pixelFormat: maskPixelFormat
        ) else {
            return image
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
            imageFeatureName: MLFeatureValue(pixelBuffer: imageBuffer),
            maskFeatureName: MLFeatureValue(pixelBuffer: maskBuffer)
        ]),
              let output = try? mlModel.prediction(from: provider),
              let outValue = output.featureValue(for: outputFeatureName),
              let outBuffer = outValue.imageBufferValue else {
            return image
        }

        let restoredPatch = CIImage(cvPixelBuffer: outBuffer)
        let outExtent = restoredPatch.extent
        guard outExtent.width > 0, outExtent.height > 0 else { return image }

        let placed = restoredPatch
            .transformed(by: CGAffineTransform(
                scaleX: contextRect.width / outExtent.width,
                y: contextRect.height / outExtent.height
            ))
            .transformed(by: CGAffineTransform(translationX: contextRect.minX, y: contextRect.minY))
            .cropped(to: contextRect)

        // 경계 부자연스러움을 줄이기 위해 페더링 마스크로 부드럽게 합성합니다.
        let featherRadius = max(2.0, min(10.0, min(roi.width, roi.height) * 0.06))
        let softMask = maskLocal
            .transformed(by: CGAffineTransform(translationX: contextRect.minX, y: contextRect.minY))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: featherRadius])
            .cropped(to: contextRect)

        let blended = placed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: softMask
        ])
        return blended.cropped(to: bounds)
    }

    private func renderBuffer(_ image: CIImage, width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(nil, width, height, pixelFormat, attrs as CFDictionary, &buffer)
        guard let out = buffer else { return nil }
        let colorSpace: CGColorSpace = (pixelFormat == kCVPixelFormatType_OneComponent8)
            ? CGColorSpaceCreateDeviceGray()
            : CGColorSpaceCreateDeviceRGB()
        ciContext.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        return out
    }
}

// MARK: - 테스트 구간 클립 추출 유틸리티

enum VideoClipExtractor {
    /// 테스트 구간(start/duration)이 지정된 경우 해당 구간만 빠르게 mp4로 추출합니다.
    static func prepareClip(
        from sourceURL: URL,
        timeRange: CMTimeRange?,
        destinationURL: URL
    ) async throws -> URL {
        guard let timeRange else { return sourceURL }
        try? FileManager.default.removeItem(at: destinationURL)
        let asset = AVURLAsset(url: sourceURL)
        let composition = AVMutableComposition()

        if let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
           let targetVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try targetVideo.insertTimeRange(timeRange, of: videoTrack, at: .zero)
            targetVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        }
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let targetAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? targetAudio.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoLingoError.mediaHasNoVideo
        }
        try await exporter.export(to: destinationURL, as: .mp4)
        return destinationURL
    }
}

// MARK: - Track 2: MLX FlashVSR v1.1 러너

enum FlashVSRRunner {
    static func run(
        inputVideoURL: URL,
        outputVideoURL: URL,
        options: DemosaicOptions,
        modelsURL: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let binaryPath = options.flashVSRBinaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let binaryURL = (binaryPath?.isEmpty == false)
            ? URL(fileURLWithPath: binaryPath!)
            : VideoRestorationPaths.defaultFlashVSRBinaryURL()

        let weightsPath = options.flashVSRWeightsPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let weightsURL = (weightsPath?.isEmpty == false)
            ? URL(fileURLWithPath: weightsPath!, isDirectory: true)
            : VideoRestorationPaths.defaultFlashVSRWeightsURL(modelsURL: modelsURL)

        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw VideoLingoError.modelUnavailable(
                "FlashVSR MLX 실행 파일(\(binaryURL.path))이 없습니다. 모자이크·복원 창의 ‘FlashVSR 자동 설치’ 버튼으로 빌드해 주세요."
            )
        }
        guard VideoRestorationPaths.flashVSRWeightsExist(at: weightsURL, modelsURL: modelsURL) else {
            throw VideoLingoError.modelUnavailable(
                "FlashVSR v1.1 MLX 가중치(\(weightsURL.path))가 없습니다. ‘FlashVSR 자동 설치’ 버튼으로 내려받아 주세요."
            )
        }

        let scale = (options.flashVSRScale == 4) ? 4 : 2
        try? FileManager.default.removeItem(at: outputVideoURL)
        onProgress(0.08, "FlashVSR v1.1 MLX(×\(scale)) 초기화 중…")

        let arguments = [
            "engine",
            inputVideoURL.path,
            outputVideoURL.path,
            weightsURL.path,
            "--scale", "\(scale)"
        ]
        try await SubprocessRunner.run(
            executableURL: binaryURL,
            arguments: arguments,
            environment: nil,
            onOutputLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                if let progress = parseFraction(from: trimmed) {
                    onProgress(min(0.95, 0.1 + progress * 0.85), "FlashVSR MLX · \(trimmed)")
                } else {
                    onProgress(0.25, "FlashVSR MLX · \(trimmed.prefix(80))")
                }
            }
        )

        guard FileManager.default.fileExists(atPath: outputVideoURL.path) else {
            throw VideoLingoError.modelUnavailable("FlashVSR 실행은 종료되었지만 출력 영상을 찾지 못했습니다.")
        }
        onProgress(0.96, "FlashVSR MLX 렌더링 완료")
    }

    private static func parseFraction(from line: String) -> Double? {
        // 예: "frame 12/120", "chunk 2/5", "45%"
        if let pctRange = line.range(of: #"(\d{1,3}(?:\.\d+)?)\s*%"#, options: .regularExpression) {
            let numStr = line[pctRange].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            if let pct = Double(numStr) { return max(0, min(1, pct / 100.0)) }
        }
        if let fracRange = line.range(of: #"\b(\d+)\s*/\s*(\d+)\b"#, options: .regularExpression) {
            let parts = line[fracRange].split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b > 0 {
                return max(0, min(1, a / b))
            }
        }
        return nil
    }
}

// MARK: - Track 3A: ComfyUI 로컬 API 러너 (Wan2.1-VACE-1.3B / SeedVR2-3B)

enum ComfyUIVideoRunner {
    static func run(
        inputVideoURL: URL,
        maskVideoURL: URL?,
        outputVideoURL: URL,
        options: DemosaicOptions,
        frameRate: Double,
        width: Int,
        height: Int,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let baseString = options.comfyUIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: baseString.isEmpty ? "http://127.0.0.1:8188" : baseString) else {
            throw VideoLingoError.modelUnavailable("ComfyUI 주소가 올바르지 않습니다: \(baseString)")
        }

        onProgress(0.05, "ComfyUI 서버 연결 확인 중 (\(baseURL.absoluteString))…")
        let objectInfo = try await fetchObjectInfo(baseURL: baseURL)

        let customPath = options.comfyUIWorkflowPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if customPath.isEmpty {
            let requiredNodes: [String] = switch options.model {
            case .seedVR2:
                ["VHS_LoadVideo", "SeedVR2LoadDiTModel", "SeedVR2LoadVAEModel", "SeedVR2VideoUpscaler", "VHS_VideoCombine"]
            case .wanVACE:
                ["VHS_LoadVideo", "WanVaceToVideo", "VHS_VideoCombine"]
            default:
                ["VHS_LoadVideo", "VHS_VideoCombine"]
            }
            let missing = requiredNodes.filter { objectInfo[$0] == nil }
            if !missing.isEmpty {
                throw VideoLingoError.modelUnavailable(
                    "ComfyUI에 필수 노드가 없습니다: \(missing.joined(separator: ", ")). VideoHelperSuite(VHS) 및 \(options.model.displayName) 노드를 설치하거나 커스텀 워크플로 JSON을 지정해 주세요."
                )
            }
        }

        onProgress(0.12, "ComfyUI에 테스트 클립 업로드 중…")
        let uploadedVideo = try await uploadFile(fileURL: inputVideoURL, to: baseURL)
        var uploadedMask: String?
        if let maskVideoURL {
            onProgress(0.18, "ComfyUI에 마스크 영상 업로드 중…")
            uploadedMask = try await uploadFile(fileURL: maskVideoURL, to: baseURL)
        }

        let promptText = (options.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "clean natural video restoration, sharp realistic details, seamless background"
        let prefix = "videolingo_\(options.model.rawValue)_\(Int(Date.now.timeIntervalSince1970))"
        let params = ComfyUIWorkflowBuilder.TemplateParameters(
            inputVideoFilename: uploadedVideo,
            maskVideoFilename: uploadedMask,
            promptText: promptText,
            outputPrefix: prefix,
            frameRate: frameRate,
            width: width,
            height: height
        )

        let workflowBody: Data
        if !customPath.isEmpty {
            let jsonString = try String(contentsOfFile: customPath, encoding: .utf8)
            workflowBody = try ComfyUIWorkflowBuilder.renderCustomWorkflow(
                jsonString: jsonString,
                model: options.model,
                parameters: params
            )
        } else if options.model == .seedVR2 {
            workflowBody = try ComfyUIWorkflowBuilder.defaultSeedVR2Workflow(parameters: params)
        } else {
            workflowBody = try ComfyUIWorkflowBuilder.defaultWanVACEWorkflow(parameters: params)
        }

        onProgress(0.24, "ComfyUI에 \(options.model.displayName) 작업 제출 중…")
        let promptID = try await submitPrompt(body: workflowBody, to: baseURL)

        var pollCount = 0
        while true {
            do {
                try Task.checkCancellation()
            } catch {
                await interrupt(baseURL: baseURL)
                throw error
            }
            try await Task.sleep(for: .milliseconds(1200))
            pollCount += 1

            if let outputDescriptor = try await pollHistory(promptID: promptID, baseURL: baseURL) {
                onProgress(0.90, "ComfyUI 결과 영상 다운로드 중…")
                try await downloadOutput(descriptor: outputDescriptor, from: baseURL, to: outputVideoURL)
                onProgress(0.96, "ComfyUI 렌더링 완료")
                return
            }

            let simulated = min(0.86, 0.25 + Double(pollCount) * 0.015)
            onProgress(simulated, "ComfyUI에서 \(options.model.displayName) 처리 중… (\(pollCount)초대)")
        }
    }

    private struct OutputFileDescriptor {
        let filename: String
        let subfolder: String
        let type: String
    }

    private static func fetchObjectInfo(baseURL: URL) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL.appending(path: "object_info"))
        req.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VideoLingoError.modelUnavailable("ComfyUI 서버(\(baseURL.absoluteString))에 연결할 수 없습니다. ComfyUI를 먼저 실행해 주세요.")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func uploadFile(fileURL: URL, to baseURL: URL) async throws -> String {
        let boundary = "VideoLingo-\(UUID().uuidString)"
        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: video/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: baseURL.appending(path: "upload/image"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw VideoLingoError.modelUnavailable("ComfyUI 파일 업로드 실패: \(text.prefix(160))")
        }
        if let subfolder = json["subfolder"] as? String, !subfolder.isEmpty {
            return "\(subfolder)/\(name)"
        }
        return name
    }

    private static func submitPrompt(body: Data, to baseURL: URL) async throws -> String {
        var req = URLRequest(url: baseURL.appending(path: "prompt"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let promptID = json["prompt_id"] as? String else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw VideoLingoError.modelUnavailable("ComfyUI 워크플로 실행 요청 실패: \(text.prefix(240))")
        }
        return promptID
    }

    private static func pollHistory(promptID: String, baseURL: URL) async throws -> OutputFileDescriptor? {
        var req = URLRequest(url: baseURL.appending(path: "history/\(promptID)"))
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[promptID] as? [String: Any] else {
            return nil
        }

        if let status = entry["status"] as? [String: Any],
           let statusStr = status["status_str"] as? String,
           statusStr == "error" {
            throw VideoLingoError.modelUnavailable("ComfyUI 워크플로 실행 중 오류가 발생했습니다. ComfyUI 콘솔 로그를 확인해 주세요.")
        }

        guard let outputs = entry["outputs"] as? [String: Any] else { return nil }
        for (_, nodeValue) in outputs {
            guard let nodeDict = nodeValue as? [String: Any] else { continue }
            for key in ["gifs", "videos", "images"] {
                guard let items = nodeDict[key] as? [[String: Any]] else { continue }
                if let video = items.first(where: { ($0["filename"] as? String)?.lowercased().hasSuffix(".mp4") == true })
                    ?? items.first {
                    if let filename = video["filename"] as? String {
                        return OutputFileDescriptor(
                            filename: filename,
                            subfolder: video["subfolder"] as? String ?? "",
                            type: video["type"] as? String ?? "output"
                        )
                    }
                }
            }
        }
        return nil
    }

    private static func downloadOutput(descriptor: OutputFileDescriptor, from baseURL: URL, to destinationURL: URL) async throws {
        var components = URLComponents(url: baseURL.appending(path: "view"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "filename", value: descriptor.filename),
            URLQueryItem(name: "subfolder", value: descriptor.subfolder),
            URLQueryItem(name: "type", value: descriptor.type)
        ]
        guard let viewURL = components?.url else { throw VideoLingoError.invalidPayload }
        let (tempURL, response) = try await URLSession.shared.download(from: viewURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VideoLingoError.modelUnavailable("ComfyUI 결과 영상 다운로드에 실패했습니다.")
        }
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }

    private static func interrupt(baseURL: URL) async {
        var req = URLRequest(url: baseURL.appending(path: "interrupt"))
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Track 3B: 로컬 uv Python MPS 워커 러너

enum LocalWorkerVideoRunner {
    static func run(
        inputVideoURL: URL,
        maskVideoURL: URL?,
        outputVideoURL: URL,
        options: DemosaicOptions,
        modelsURL: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let customScript = options.localWorkerScriptPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scriptURL: URL? = (customScript?.isEmpty == false)
            ? URL(fileURLWithPath: customScript!)
            : VideoRestorationPaths.defaultLocalWorkerScriptURL()
        guard let scriptURL, FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw VideoLingoError.modelUnavailable(
                "로컬 uv 워커 스크립트(tools/video-enhancer/worker.py)를 찾을 수 없습니다."
            )
        }

        let uvCandidates = [
            NSHomeDirectory() + "/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv"
        ]
        let executableURL: URL
        var arguments: [String]
        if let uvPath = uvCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            executableURL = URL(fileURLWithPath: uvPath)
            arguments = ["run", "--script", scriptURL.path]
        } else {
            executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            arguments = [scriptURL.path]
        }

        let engineName = (options.model == .seedVR2) ? "seedvr2" : "wan_vace"
        arguments += [
            "--engine", engineName,
            "--input", inputVideoURL.path,
            "--output", outputVideoURL.path,
            "--models-dir", VideoRestorationPaths.demosaicModelsDirectory(modelsURL: modelsURL).path
        ]
        if let maskVideoURL {
            arguments += ["--mask", maskVideoURL.path]
        }
        if let prompt = options.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            arguments += ["--prompt", prompt]
        }

        try? FileManager.default.removeItem(at: outputVideoURL)
        onProgress(0.08, "로컬 uv MPS 워커(\(options.model.displayName)) 시작 중…")

        try await SubprocessRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: ["PYTORCH_ENABLE_MPS_FALLBACK": "1"],
            onOutputLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                if trimmed.hasPrefix("PROGRESS ") {
                    let parts = trimmed.dropFirst("PROGRESS ".count).split(separator: " ", maxSplits: 1)
                    let pct = parts.first.flatMap { Double($0) } ?? 0.3
                    let msg = parts.count > 1 ? String(parts[1]) : options.model.displayName
                    onProgress(max(0.05, min(0.95, pct)), msg)
                } else {
                    onProgress(0.25, "uv 워커 · \(trimmed.prefix(80))")
                }
            }
        )

        guard FileManager.default.fileExists(atPath: outputVideoURL.path) else {
            throw VideoLingoError.modelUnavailable("로컬 uv 워커 실행 후 결과 영상이 생성되지 않았습니다.")
        }
        onProgress(0.96, "로컬 uv 워커 렌더링 완료")
    }
}

// MARK: - 취소 지원 비동기 서브프로세스 러너

enum SubprocessRunner {
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var tail: [String] = []

        func append(_ line: String) {
            lock.withLock {
                tail.append(line)
                if tail.count > 20 { tail.removeFirst(tail.count - 20) }
            }
        }

        func summary() -> String {
            lock.withLock { tail.joined(separator: "\n") }
        }
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        let extraPath = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        if let environment {
            for (k, v) in environment { env[k] = v }
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collector = LineCollector()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            for rawLine in chunk.split(whereSeparator: \.isNewline) {
                let line = String(rawLine)
                collector.append(line)
                onOutputLine(line)
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { proc in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        let tail = collector.summary()
                        let detail = tail.isEmpty ? "종료 코드 \(proc.terminationStatus)" : tail
                        continuation.resume(throwing: VideoLingoError.modelUnavailable(detail))
                    }
                }
                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
