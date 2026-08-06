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
}

public enum ManagedModelState: String, Codable, Sendable {
    case notDownloaded, downloading, downloaded, failed
}

public struct ModelManagementRequest: Codable, Sendable {
    public let kind: ManagedModelKind
    public let modelID: String
    public let modelsURL: URL

    public init(kind: ManagedModelKind, modelID: String, modelsURL: URL) {
        self.kind = kind
        self.modelID = modelID
        self.modelsURL = modelsURL
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
