import Foundation

@objc public protocol VideoLingoAIServiceProtocol {
    func startJob(_ payload: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    func startDemosaic(_ payload: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    func snapshot(for jobID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    func cancelJob(_ jobID: String, withReply reply: @escaping @Sendable (Bool) -> Void)
    func ping(withReply reply: @escaping @Sendable (String) -> Void)
    func serviceStatus(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    func restart(withReply reply: @escaping @Sendable (Bool) -> Void)
    func modelManagerSnapshot(at modelsPath: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    func startModelDownload(_ payload: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    func deleteManagedModel(_ payload: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    func transcribeDirect(_ payload: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    func translateDirect(_ payload: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
}

public struct DirectSTTRequest: Codable, Sendable {
    public let audioURL: URL
    public let language: String?
    public let modelID: String
    public let modelsURL: URL
    public init(audioURL: URL, language: String?, modelID: String, modelsURL: URL) {
        self.audioURL = audioURL; self.language = language; self.modelID = modelID; self.modelsURL = modelsURL
    }
}

public struct DirectSTTSegment: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let avgLogprob: Double?
    public init(start: Double, end: Double, text: String, avgLogprob: Double?) {
        self.start = start; self.end = end; self.text = text; self.avgLogprob = avgLogprob
    }
}

public struct DirectSTTResponse: Codable, Sendable {
    public let language: String?
    public let segments: [DirectSTTSegment]
    public let duration: Double
    public let processingSeconds: Double
    public init(language: String?, segments: [DirectSTTSegment], duration: Double, processingSeconds: Double) {
        self.language = language; self.segments = segments; self.duration = duration; self.processingSeconds = processingSeconds
    }
}

public struct DirectTranslationRequest: Codable, Sendable {
    public let texts: [String]
    public let sourceLanguage: String?
    public let targetLanguage: String
    public let modelID: String
    public let modelsURL: URL
    public init(texts: [String], sourceLanguage: String?, targetLanguage: String, modelID: String, modelsURL: URL) {
        self.texts = texts; self.sourceLanguage = sourceLanguage; self.targetLanguage = targetLanguage
        self.modelID = modelID; self.modelsURL = modelsURL
    }
}

public struct DirectTranslationResponse: Codable, Sendable {
    public let translations: [String]
    public let processingSeconds: Double
    public init(translations: [String], processingSeconds: Double) {
        self.translations = translations; self.processingSeconds = processingSeconds
    }
}

public struct AIServiceStatus: Codable, Sendable, Equatable {
    public let processIdentifier: Int32
    public let startedAt: Date
    public let activeJobCount: Int
    public let version: String

    public init(processIdentifier: Int32, startedAt: Date, activeJobCount: Int, version: String) {
        self.processIdentifier = processIdentifier
        self.startedAt = startedAt
        self.activeJobCount = activeJobCount
        self.version = version
    }
}

public enum ManagedModelKind: String, Codable, Sendable, CaseIterable {
    case stt
    case tts
    case translation
    case demosaic
}

public enum ManagedModelState: String, Codable, Sendable {
    case notDownloaded, downloading, downloaded, failed
}

public struct ModelManagementRequest: Codable, Sendable {
    public let kind: ManagedModelKind
    public let modelID: String
    public let modelsURL: URL
    /// demosaic 종류에서 Core ML 모델(.mlpackage 또는 이를 담은 .zip)을 받을 직접 URL입니다.
    public let sourceURL: URL?

    public init(kind: ManagedModelKind, modelID: String, modelsURL: URL, sourceURL: URL? = nil) {
        self.kind = kind
        self.modelID = modelID
        self.modelsURL = modelsURL
        self.sourceURL = sourceURL
    }
}

public struct ManagedModelRecord: Codable, Identifiable, Sendable {
    public var id: String { "\(kind.rawValue):\(modelID)" }
    public let kind: ManagedModelKind
    public let modelID: String
    public var state: ManagedModelState
    public var progress: Double
    public var localURL: URL?
    public var sizeInBytes: Int64
    public var error: String?
    public var updatedAt: Date

    public init(kind: ManagedModelKind, modelID: String, state: ManagedModelState = .notDownloaded, progress: Double = 0, localURL: URL? = nil, sizeInBytes: Int64 = 0, error: String? = nil, updatedAt: Date = .now) {
        self.kind = kind
        self.modelID = modelID
        self.state = state
        self.progress = progress
        self.localURL = localURL
        self.sizeInBytes = sizeInBytes
        self.error = error
        self.updatedAt = updatedAt
    }
}

public struct ModelManagerSnapshot: Codable, Sendable {
    public let models: [ManagedModelRecord]
    public init(models: [ManagedModelRecord]) { self.models = models }
}

public struct DatabaseStatistics: Sendable {
    public let jobCount: Int
    public let transcriptCount: Int
    public let translationCount: Int

    public init(jobCount: Int, transcriptCount: Int, translationCount: Int) {
        self.jobCount = jobCount
        self.transcriptCount = transcriptCount
        self.translationCount = translationCount
    }
}

public enum WireCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
