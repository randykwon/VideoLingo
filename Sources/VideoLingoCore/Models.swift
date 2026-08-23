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

    public var sourceLanguage: String?
    public var targetLanguages: [String]
    public var chunkDuration: TimeInterval
    public var sttModel: String
    public var translationModel: String
    public var synthesizeSpeech: Bool
    public var qualityMode: ProcessingQualityMode?
    public var glossary: [GlossaryEntry]?
    public var continuousImprovement: Bool?
    public var maximumRefinementPasses: Int?

    public init(
        sourceLanguage: String? = nil,
        targetLanguages: [String] = ["ko"],
        chunkDuration: TimeInterval = ProcessingOptions.defaultChunkDuration,
        sttModel: String = "large-v3-v20240930_626MB",
        translationModel: String = "apple-foundation-models",
        synthesizeSpeech: Bool = false,
        qualityMode: ProcessingQualityMode = .enhanced,
        glossary: [GlossaryEntry] = [],
        continuousImprovement: Bool = true,
        maximumRefinementPasses: Int = 3
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
        self.maximumRefinementPasses = maximumRefinementPasses
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

// MARK: - 모자이크 제거(디모자이크)

/// 사용할 복원 모델. Core ML 모델이 없으면 파이프라인이 고전적 복원으로 폴백합니다.
public enum DemosaicModel: String, Codable, Sendable, CaseIterable {
    case classical      // Core Image 업스케일+샤픈 (모델 불필요, 항상 사용 가능)
    case realESRGAN     // 일반 디블록/초해상 (Core ML/MLX)
    case codeFormer     // 얼굴 복원 (Core ML)
}

/// 복원할 영역을 어떻게 정할지.
public enum DemosaicRegionMode: String, Codable, Sendable, CaseIterable {
    case face          // 얼굴 영역만 (Vision 얼굴 검출)
    case autoMosaic    // 모자이크 영역 자동 탐지(전체 영상에서)
    case wholeFrame    // 전체 화면
}

public struct DemosaicOptions: Codable, Sendable, Equatable {
    public var model: DemosaicModel
    public var regionMode: DemosaicRegionMode
    public var fidelity: Double
    public var temporalStabilization: Bool
    public var watermarkSynthetic: Bool

    public init(
        model: DemosaicModel = .classical,
        regionMode: DemosaicRegionMode = .face,
        fidelity: Double = 0.7,
        temporalStabilization: Bool = true,
        watermarkSynthetic: Bool = true
    ) {
        self.model = model
        self.regionMode = regionMode
        self.fidelity = fidelity
        self.temporalStabilization = temporalStabilization
        self.watermarkSynthetic = watermarkSynthetic
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
