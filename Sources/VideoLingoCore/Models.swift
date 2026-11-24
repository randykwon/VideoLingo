import Foundation

public enum JobStatus: String, Codable, Sendable {
    case queued, extracting, transcribing, translating, synthesizing, refining, completed, paused, cancelled, failed
}

public enum ProcessingQualityMode: String, Codable, Sendable, CaseIterable {
    case fast, enhanced, maximum
}

public enum SegmentQualityStatus: String, Codable, Sendable, Hashable {
    case good, reviewed, warning
}

public struct GlossaryEntry: Codable, Sendable, Equatable, Hashable {
    public let source: String
    public let target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

public struct ProcessingOptions: Codable, Sendable, Equatable {
    public static let defaultChunkDuration: TimeInterval = 60
    /// OpenAI 호환 외부 LLM 서버를 쓸 때 translationModel에 넣는 값입니다.
    /// Ollama·LM Studio·llama.cpp·vLLM처럼 API 키 없이 도는 로컬/사내 서버를 상정합니다.
    public static let externalServerModelID = "external-openai"
    /// Apple 전용 온디바이스 번역(Translation.framework)을 쓸 때 translationModel에 기록하는 식별자입니다.
    public static let appleTranslationModelID = "apple-translation"
    /// Azure Translator를 쓸 때 translationModel에 기록하는 식별자입니다.
    public static let azureTranslationModelID = "azure-translator"
    /// 사용자 정의 로컬 번역 API를 쓸 때 translationModel에 기록하는 식별자입니다.
    public static let localAPITranslationModelID = "local-translation-api"
    /// 앱 자체 llama.cpp 서버(GGUF)를 쓸 때 translationModel 접두사로 사용합니다.
    public static let managedLlamaModelPrefix = "managed-llama:"

    public var sourceLanguage: String?
    public var targetLanguages: [String]
    public var chunkDuration: TimeInterval
    public var sttModel: String
    public var translationModel: String
    public var synthesizeSpeech: Bool
    public var qualityMode: ProcessingQualityMode?
    public var glossary: [GlossaryEntry]?
    public var continuousImprovement: Bool?
    /// 화자 이름이 이미 적용된 결과에도 화자 분석을 다시 실행합니다.
    public var forceSpeakerReanalysis: Bool?
    /// 외부 LLM 서버의 기본 주소입니다. 예: http://localhost:11434/v1
    public var externalServerEndpoint: String?
    /// 외부 서버에서 사용할 모델 이름입니다. 예: qwen2.5:7b
    public var externalServerModel: String?
    /// 인증이 필요한 서버를 위한 선택 항목입니다. 비어 있으면 인증 헤더를 보내지 않습니다.
    public var externalServerAPIKey: String?
    public var maximumRefinementPasses: Int?
    /// STT 엔진 선택 (nil이면 기존 호환성 유지를 위해 WhisperKit 사용).
    public var sttEngine: STTEngineKind?
    /// 번역 엔진 선택 (nil이면 translationModel 문자열에서 자동 추론).
    public var translationEngine: TranslationEngineKind?
    /// 자체 whisper-server 주소 및 실행 토큰.
    public var managedSTTURL: String?
    public var managedSTTAPIKey: String?
    /// 자체 llama-server 주소 및 실행 토큰.
    public var managedTranslationURL: String?
    public var managedTranslationAPIKey: String?
    /// Deepgram API 키 및 모델(기본 nova-3).
    public var deepgramAPIKey: String?
    public var deepgramModel: String?
    /// Azure Translator API 키 및 리전.
    public var azureAPIKey: String?
    public var azureRegion: String?
    /// 로컬 커스텀 번역 API 설정 및 API 키.
    public var localTranslationAPI: LocalTranslationAPISettings?
    public var localTranslationAPIKey: String?

    public init(
        sourceLanguage: String? = nil,
        targetLanguages: [String] = ["ko"],
        chunkDuration: TimeInterval = ProcessingOptions.defaultChunkDuration,
        sttModel: String = "large-v3-v20240930_626MB",
        translationModel: String = "mlx-community/Qwen3-8B-4bit",
        synthesizeSpeech: Bool = false,
        qualityMode: ProcessingQualityMode = .enhanced,
        glossary: [GlossaryEntry] = [],
        continuousImprovement: Bool = true,
        forceSpeakerReanalysis: Bool = false,
        externalServerEndpoint: String? = nil,
        externalServerModel: String? = nil,
        externalServerAPIKey: String? = nil,
        maximumRefinementPasses: Int = 3,
        sttEngine: STTEngineKind? = nil,
        translationEngine: TranslationEngineKind? = nil,
        managedSTTURL: String? = nil,
        managedSTTAPIKey: String? = nil,
        managedTranslationURL: String? = nil,
        managedTranslationAPIKey: String? = nil,
        deepgramAPIKey: String? = nil,
        deepgramModel: String? = nil,
        azureAPIKey: String? = nil,
        azureRegion: String? = nil,
        localTranslationAPI: LocalTranslationAPISettings? = nil,
        localTranslationAPIKey: String? = nil
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguages = targetLanguages
        self.chunkDuration = chunkDuration
        self.sttModel = sttModel
        self.translationModel = translationModel
        self.synthesizeSpeech = synthesizeSpeech
        self.qualityMode = qualityMode
        self.glossary = glossary
        self.continuousImprovement = continuousImprovement
        self.forceSpeakerReanalysis = forceSpeakerReanalysis
        self.externalServerEndpoint = externalServerEndpoint
        self.externalServerModel = externalServerModel
        self.externalServerAPIKey = externalServerAPIKey
        self.maximumRefinementPasses = maximumRefinementPasses
        self.sttEngine = sttEngine
        self.translationEngine = translationEngine
        self.managedSTTURL = managedSTTURL
        self.managedSTTAPIKey = managedSTTAPIKey
        self.managedTranslationURL = managedTranslationURL
        self.managedTranslationAPIKey = managedTranslationAPIKey
        self.deepgramAPIKey = deepgramAPIKey
        self.deepgramModel = deepgramModel
        self.azureAPIKey = azureAPIKey
        self.azureRegion = azureRegion
        self.localTranslationAPI = localTranslationAPI
        self.localTranslationAPIKey = localTranslationAPIKey
    }
}

public extension ProcessingOptions {
    /// 외부 LLM 서버를 쓰도록 설정돼 있는지.
    var usesExternalServer: Bool { effectiveTranslationEngine == .externalOpenAI }

    var effectiveSTTEngine: STTEngineKind {
        sttEngine ?? .whisperKit
    }

    var effectiveTranslationEngine: TranslationEngineKind {
        if let translationEngine { return translationEngine }
        if translationModel == "apple-foundation-models" { return .appleFoundation }
        if translationModel == Self.externalServerModelID { return .externalOpenAI }
        if translationModel == Self.appleTranslationModelID { return .appleTranslation }
        if translationModel == Self.azureTranslationModelID { return .azure }
        if translationModel == Self.localAPITranslationModelID { return .localAPI }
        if translationModel.hasPrefix(Self.managedLlamaModelPrefix) { return .managedLlama }
        return .mlx
    }
}

public struct StartJobRequest: Codable, Sendable {
    public let jobID: UUID
    public let mediaURL: URL
    public let securityScopedBookmark: Data?
    public let options: ProcessingOptions
    public let databaseURL: URL
    public let workspaceURL: URL
    /// 원본 영상 옆에 결과를 기록할 수 없을 때 사용할 대체 저장 폴더입니다.
    public let alternateResultDirectoryURL: URL?
    public let alternateResultDirectoryBookmark: Data?
    /// 기존 결과를 지우지 않고 새 후보와 비교해 개선된 경우에만 교체할 청크입니다.
    public let retryChunkIndices: [Int]?

    public init(jobID: UUID, mediaURL: URL, securityScopedBookmark: Data?, options: ProcessingOptions, databaseURL: URL, workspaceURL: URL, alternateResultDirectoryURL: URL? = nil, alternateResultDirectoryBookmark: Data? = nil, retryChunkIndices: [Int] = []) {
        self.jobID = jobID
        self.mediaURL = mediaURL
        self.securityScopedBookmark = securityScopedBookmark
        self.options = options
        self.databaseURL = databaseURL
        self.workspaceURL = workspaceURL
        self.alternateResultDirectoryURL = alternateResultDirectoryURL
        self.alternateResultDirectoryBookmark = alternateResultDirectoryBookmark
        self.retryChunkIndices = retryChunkIndices.isEmpty ? nil : retryChunkIndices
    }
}

// MARK: - 모자이크 제거 · 영상 복원(디모자이크)

/// 영상 복원·제거 엔진 3가지 트랙입니다.
public enum VideoEnhancerTrack: String, Codable, Sendable, CaseIterable, Identifiable {
    case coreMLNative    // 1. CoreML 네이티브 (LaMa / Real-ESRGAN / GFPGAN / CodeFormer / 기본)
    case mlxFlashVSR     // 2. MLX 네이티브 (FlashVSR v1.1)
    case comfyOrUVMPS    // 3. 로컬 ComfyUI / uv MPS 워커 (Wan2.1-VACE-1.3B / SeedVR2-3B)

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .coreMLNative: "1. CoreML 네이티브"
        case .mlxFlashVSR: "2. MLX FlashVSR"
        case .comfyOrUVMPS: "3. ComfyUI · uv MPS"
        }
    }

    public var shortDescription: String {
        switch self {
        case .coreMLNative: "Python 없이 Swift/CoreML에서 즉시 실행 (LaMa 영역 제거 · Real-ESRGAN · GFPGAN)"
        case .mlxFlashVSR: "Apple Silicon MLX 1-step 스트리밍 영상 복원 (FlashVSR v1.1 · 3.5GB)"
        case .comfyOrUVMPS: "로컬 ComfyUI API 또는 uv Python MPS 워커 (Wan2.1-VACE-1.3B · SeedVR2-3B)"
        }
    }
}

/// 3번 트랙(Wan2.1-VACE / SeedVR2)의 실행 백엔드입니다.
public enum VideoEnhancerBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    case comfyUI
    case localWorker

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .comfyUI: "ComfyUI 로컬 API"
        case .localWorker: "로컬 uv Python MPS 워커"
        }
    }
}

/// 사용할 복원/제거 모델. Core ML 모델이 없으면 파이프라인이 고전적 복원으로 폴백합니다.
public enum DemosaicModel: String, Codable, Sendable, CaseIterable, Identifiable {
    case classical      // Core Image 업스케일+샤픈 (모델 불필요, 항상 사용 가능)
    case lamaCoreML     // LaMa CoreML 영역 제거/인페인팅 (Apache 2.0)
    case realESRGAN     // Real-ESRGAN x4 CoreML 디블록/초해상 (BSD-3)
    case gfpganCoreML   // GFPGAN CoreML 얼굴 복원
    case codeFormer     // CodeFormer CoreML 얼굴 복원 (사용자 변환 모델)
    case flashVSRMLX    // FlashVSR v1.1 MLX 1-step 영상 초해상·복원 (Apache 2.0)
    case wanVACE        // Wan2.1-VACE-1.3B 마스크 인페인팅·편집 (Apache 2.0)
    case seedVR2        // SeedVR2-3B 1-step 확산 영상 복원 (Apache 2.0)

    public var id: String { rawValue }

    public var track: VideoEnhancerTrack {
        switch self {
        case .classical, .lamaCoreML, .realESRGAN, .gfpganCoreML, .codeFormer:
            .coreMLNative
        case .flashVSRMLX:
            .mlxFlashVSR
        case .wanVACE, .seedVR2:
            .comfyOrUVMPS
        }
    }

    public var displayName: String {
        switch self {
        case .classical: "기본 (Core Image)"
        case .lamaCoreML: "LaMa (CoreML · 영역 제거)"
        case .realESRGAN: "Real-ESRGAN ×4 (CoreML · 화질 복원)"
        case .gfpganCoreML: "GFPGAN (CoreML · 얼굴 복원)"
        case .codeFormer: "CodeFormer (CoreML · 수동 배치)"
        case .flashVSRMLX: "FlashVSR v1.1 (MLX · 1-step 초해상·복원)"
        case .wanVACE: "Wan2.1-VACE-1.3B (마스크 제거·편집)"
        case .seedVR2: "SeedVR2-3B (1-step 확산 영상 복원)"
        }
    }

    public var coreMLModelID: String? {
        switch self {
        case .lamaCoreML: "lama"
        case .realESRGAN: "realesrgan"
        case .gfpganCoreML: "gfpgan"
        case .codeFormer: "codeformer"
        default: nil
        }
    }

    public static func models(for track: VideoEnhancerTrack) -> [DemosaicModel] {
        allCases.filter { $0.track == track }
    }
}

/// 복원할 영역을 어떻게 정할지.
public enum DemosaicRegionMode: String, Codable, Sendable, CaseIterable {
    case face          // 얼굴 영역만 (Vision 얼굴 검출)
    case autoMosaic    // 모자이크 영역 자동 탐지(전체 영상에서)
    case manual        // 사용자가 화면에서 직접 지정한 영역
    case wholeFrame    // 전체 화면
}

/// 영상 크기와 방향에 독립적인 좌하단 원점의 0...1 영역 좌표입니다.
public struct DemosaicRegion: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct DemosaicOptions: Codable, Sendable, Equatable {
    public var model: DemosaicModel
    public var regionMode: DemosaicRegionMode
    public var fidelity: Double
    public var temporalStabilization: Bool
    public var watermarkSynthetic: Bool
    /// 좌하단 원점의 0...1 정규화 좌표. manual 모드에서 영상 전체에 적용합니다.
    public var manualRegions: [DemosaicRegion]
    /// 테스트 구간 시작 초. nil이면 0초부터 처리합니다.
    public var clipStartSeconds: Double?
    /// 테스트 구간 길이(초). nil 또는 0 이하이면 전체 영상을 처리합니다.
    public var clipDurationSeconds: Double?
    /// 3번 트랙(Wan2.1-VACE / SeedVR2) 실행 백엔드.
    public var externalBackend: VideoEnhancerBackend
    /// ComfyUI 로컬 API 주소 (기본 http://127.0.0.1:8188).
    public var comfyUIBaseURL: String
    /// 사용자 지정 ComfyUI API 워크플로 JSON 경로 (비어 있으면 내장 템플릿 사용).
    public var comfyUIWorkflowPath: String?
    /// FlashVSR v1.1 배율 (2 또는 4).
    public var flashVSRScale: Int
    /// FlashVSR 실행 바이너리 경로(비어 있으면 기본 설치 경로 사용).
    public var flashVSRBinaryPath: String?
    /// FlashVSR MLX 가중치 폴더 경로(비어 있으면 기본 설치 경로 사용).
    public var flashVSRWeightsPath: String?
    /// 로컬 uv Python 워커 스크립트 경로(비어 있으면 기본 경로 탐색).
    public var localWorkerScriptPath: String?
    /// Wan2.1-VACE 등에서 사용할 선택 프롬프트.
    public var prompt: String?

    public init(
        model: DemosaicModel = .classical,
        regionMode: DemosaicRegionMode = .face,
        fidelity: Double = 0.7,
        temporalStabilization: Bool = true,
        watermarkSynthetic: Bool = true,
        manualRegions: [DemosaicRegion] = [],
        clipStartSeconds: Double? = nil,
        clipDurationSeconds: Double? = nil,
        externalBackend: VideoEnhancerBackend = .comfyUI,
        comfyUIBaseURL: String = "http://127.0.0.1:8188",
        comfyUIWorkflowPath: String? = nil,
        flashVSRScale: Int = 2,
        flashVSRBinaryPath: String? = nil,
        flashVSRWeightsPath: String? = nil,
        localWorkerScriptPath: String? = nil,
        prompt: String? = nil
    ) {
        self.model = model
        self.regionMode = regionMode
        self.fidelity = fidelity
        self.temporalStabilization = temporalStabilization
        self.watermarkSynthetic = watermarkSynthetic
        self.manualRegions = manualRegions
        self.clipStartSeconds = clipStartSeconds
        self.clipDurationSeconds = clipDurationSeconds
        self.externalBackend = externalBackend
        self.comfyUIBaseURL = comfyUIBaseURL
        self.comfyUIWorkflowPath = comfyUIWorkflowPath
        self.flashVSRScale = flashVSRScale
        self.flashVSRBinaryPath = flashVSRBinaryPath
        self.flashVSRWeightsPath = flashVSRWeightsPath
        self.localWorkerScriptPath = localWorkerScriptPath
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey {
        case model, regionMode, fidelity, temporalStabilization, watermarkSynthetic, manualRegions
        case clipStartSeconds, clipDurationSeconds, externalBackend, comfyUIBaseURL, comfyUIWorkflowPath
        case flashVSRScale, flashVSRBinaryPath, flashVSRWeightsPath, localWorkerScriptPath, prompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(DemosaicModel.self, forKey: .model) ?? .classical
        regionMode = try c.decodeIfPresent(DemosaicRegionMode.self, forKey: .regionMode) ?? .face
        fidelity = try c.decodeIfPresent(Double.self, forKey: .fidelity) ?? 0.7
        temporalStabilization = try c.decodeIfPresent(Bool.self, forKey: .temporalStabilization) ?? true
        watermarkSynthetic = try c.decodeIfPresent(Bool.self, forKey: .watermarkSynthetic) ?? true
        manualRegions = try c.decodeIfPresent([DemosaicRegion].self, forKey: .manualRegions) ?? []
        clipStartSeconds = try c.decodeIfPresent(Double.self, forKey: .clipStartSeconds)
        clipDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .clipDurationSeconds)
        externalBackend = try c.decodeIfPresent(VideoEnhancerBackend.self, forKey: .externalBackend) ?? .comfyUI
        comfyUIBaseURL = try c.decodeIfPresent(String.self, forKey: .comfyUIBaseURL) ?? "http://127.0.0.1:8188"
        comfyUIWorkflowPath = try c.decodeIfPresent(String.self, forKey: .comfyUIWorkflowPath)
        flashVSRScale = try c.decodeIfPresent(Int.self, forKey: .flashVSRScale) ?? 2
        flashVSRBinaryPath = try c.decodeIfPresent(String.self, forKey: .flashVSRBinaryPath)
        flashVSRWeightsPath = try c.decodeIfPresent(String.self, forKey: .flashVSRWeightsPath)
        localWorkerScriptPath = try c.decodeIfPresent(String.self, forKey: .localWorkerScriptPath)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
    }
}

public struct StartDemosaicRequest: Codable, Sendable {
    public let jobID: UUID
    public let mediaURL: URL
    public let securityScopedBookmark: Data?
    public let options: DemosaicOptions
    public let databaseURL: URL
    public let workspaceURL: URL
    public let modelsURL: URL
    public let uiLanguageCode: String?

    public init(
        jobID: UUID,
        mediaURL: URL,
        securityScopedBookmark: Data?,
        options: DemosaicOptions,
        databaseURL: URL,
        workspaceURL: URL,
        modelsURL: URL,
        uiLanguageCode: String? = nil
    ) {
        self.jobID = jobID
        self.mediaURL = mediaURL
        self.securityScopedBookmark = securityScopedBookmark
        self.options = options
        self.databaseURL = databaseURL
        self.workspaceURL = workspaceURL
        self.modelsURL = modelsURL
        self.uiLanguageCode = uiLanguageCode
    }
}

public struct TranscriptCue: Codable, Hashable, Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public init(startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let jobID: UUID
    public let chunkIndex: Int
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String
    public let language: String?
    public let confidence: Double?
    public let cues: [TranscriptCue]?
    public let qualityStatus: SegmentQualityStatus?
    public let retryCount: Int?
    public let qualityNotes: [String]?

    public init(id: UUID = UUID(), jobID: UUID, chunkIndex: Int, startTime: TimeInterval, endTime: TimeInterval, text: String, language: String? = nil, confidence: Double? = nil, cues: [TranscriptCue] = [], qualityStatus: SegmentQualityStatus? = nil, retryCount: Int? = nil, qualityNotes: [String]? = nil) {
        self.id = id
        self.jobID = jobID
        self.chunkIndex = chunkIndex
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.language = language
        self.confidence = confidence
        self.cues = cues
        self.qualityStatus = qualityStatus
        self.retryCount = retryCount
        self.qualityNotes = qualityNotes
    }
}

public struct TranslationSegment: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let transcriptID: UUID
    public let jobID: UUID
    public let targetLanguage: String
    public let modelID: String
    public let text: String
    public let qualityStatus: SegmentQualityStatus?
    public let qualityNotes: [String]?

    public init(id: UUID = UUID(), transcriptID: UUID, jobID: UUID, targetLanguage: String, modelID: String = "apple-foundation-models", text: String, qualityStatus: SegmentQualityStatus? = nil, qualityNotes: [String]? = nil) {
        self.id = id
        self.transcriptID = transcriptID
        self.jobID = jobID
        self.targetLanguage = targetLanguage
        self.modelID = modelID
        self.text = text
        self.qualityStatus = qualityStatus
        self.qualityNotes = qualityNotes
    }
}

public struct JobSnapshot: Codable, Identifiable, Sendable {
    public let id: UUID
    public var status: JobStatus
    public var progress: Double
    public var currentChunk: Int
    public var totalChunks: Int
    public var sttProgress: Double
    public var translationProgress: Double
    public var lastTranscriptText: String?
    public var lastTranslationText: String?
    public var liveTranscriptText: String?
    public var liveTranslationText: String?
    public var message: String
    public var error: String?
    public var updatedAt: Date
    public var refinementPass: Int?
    public var refinementProgress: Double?
    public var refinementRevision: Int?
    public var refinementImprovements: Int?

    public init(
        id: UUID,
        status: JobStatus = .queued,
        progress: Double = 0,
        currentChunk: Int = 0,
        totalChunks: Int = 0,
        sttProgress: Double = 0,
        translationProgress: Double = 0,
        lastTranscriptText: String? = nil,
        lastTranslationText: String? = nil,
        liveTranscriptText: String? = nil,
        liveTranslationText: String? = nil,
        message: String = "대기 중",
        error: String? = nil,
        updatedAt: Date = .now,
        refinementPass: Int? = nil,
        refinementProgress: Double? = nil,
        refinementRevision: Int? = nil,
        refinementImprovements: Int? = nil
    ) {
        self.id = id
        self.status = status
        self.progress = progress
        self.currentChunk = currentChunk
        self.totalChunks = totalChunks
        self.sttProgress = sttProgress
        self.translationProgress = translationProgress
        self.lastTranscriptText = lastTranscriptText
        self.lastTranslationText = lastTranslationText
        self.liveTranscriptText = liveTranscriptText
        self.liveTranslationText = liveTranslationText
        self.message = message
        self.error = error
        self.updatedAt = updatedAt
        self.refinementPass = refinementPass
        self.refinementProgress = refinementProgress
        self.refinementRevision = refinementRevision
        self.refinementImprovements = refinementImprovements
    }
}

public enum VideoLingoError: LocalizedError {
    case invalidPayload
    case serviceUnavailable
    case mediaHasNoAudio
    case mediaHasNoVideo
    case modelUnavailable(String)
    case sttIncomplete([Int])
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidPayload: "작업 요청을 해석할 수 없습니다."
        case .serviceUnavailable: "AI 서비스에 연결할 수 없습니다."
        case .mediaHasNoAudio: "영상에 오디오 트랙이 없습니다."
        case .mediaHasNoVideo: "영상에 비디오 트랙이 없습니다."
        case .modelUnavailable(let reason): "로컬 모델을 사용할 수 없습니다: \(reason)"
        case .sttIncomplete(let indices):
            "STT 검증이 끝나지 않은 청크가 있습니다: \(indices.map { String($0 + 1) }.joined(separator: ", ")). 저장된 결과를 유지한 채 다시 시작할 수 있습니다."
        case .cancelled: "작업이 취소되었습니다."
        }
    }
}
