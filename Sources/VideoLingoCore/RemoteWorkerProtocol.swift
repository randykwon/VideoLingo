import Foundation

/// VideoLingo 메인 앱과 별도 설치형 STT·LLM Worker가 공유하는 API 버전입니다.
public enum RemoteWorkerAPI {
    public static let version = 1
    public static let statusPath = "/v1/status"
    public static let jobsPath = "/v1/jobs"

    public static func jobPath(_ id: UUID) -> String { "\(jobsPath)/\(id.uuidString)" }
}

public struct RemoteWorkerCapabilities: Codable, Sendable, Equatable {
    public var sttSlots: Int
    public var translationSlots: Int
    public var sttModels: [String]
    public var translationModels: [String]

    public init(sttSlots: Int, translationSlots: Int, sttModels: [String] = [], translationModels: [String] = []) {
        self.sttSlots = max(0, sttSlots)
        self.translationSlots = max(0, translationSlots)
        self.sttModels = sttModels
        self.translationModels = translationModels
    }
}

public struct RemoteWorkerStatus: Codable, Sendable, Equatable {
    public let apiVersion: Int
    public let workerID: UUID
    public let name: String
    public let version: String
    public let activeJobs: Int
    public let capabilities: RemoteWorkerCapabilities

    public init(apiVersion: Int = RemoteWorkerAPI.version, workerID: UUID, name: String, version: String, activeJobs: Int, capabilities: RemoteWorkerCapabilities) {
        self.apiVersion = apiVersion
        self.workerID = workerID
        self.name = name
        self.version = version
        self.activeJobs = max(0, activeJobs)
        self.capabilities = capabilities
    }
}

/// 영상 업로드가 끝난 후 Worker에 전달하는 작업 메타데이터입니다.
public struct RemoteJobManifest: Codable, Sendable {
    public let jobID: UUID
    public let originalFilename: String
    public let mediaByteCount: Int64
    public let options: ProcessingOptions

    public init(jobID: UUID, originalFilename: String, mediaByteCount: Int64, options: ProcessingOptions) {
        self.jobID = jobID
        self.originalFilename = originalFilename
        self.mediaByteCount = mediaByteCount
        self.options = options
    }
}

public struct RemoteJobReceipt: Codable, Sendable {
    public let jobID: UUID
    public let accepted: Bool
    public let message: String

    public init(jobID: UUID, accepted: Bool, message: String) {
        self.jobID = jobID
        self.accepted = accepted
        self.message = message
    }
}

public struct RemoteJobProgress: Codable, Sendable {
    public let jobID: UUID
    public let status: JobStatus
    public let sttProgress: Double
    public let translationProgress: Double
    public let message: String
    public let result: RemoteJobResult?

    public init(jobID: UUID, status: JobStatus, sttProgress: Double, translationProgress: Double, message: String, result: RemoteJobResult? = nil) {
        self.jobID = jobID
        self.status = status
        self.sttProgress = sttProgress
        self.translationProgress = translationProgress
        self.message = message
        self.result = result
    }
}

public struct RemoteJobResult: Codable, Sendable {
    public let transcripts: [TranscriptSegment]
    public let translations: [TranslationSegment]

    public init(transcripts: [TranscriptSegment], translations: [TranslationSegment]) {
        self.transcripts = transcripts
        self.translations = translations
    }
}
