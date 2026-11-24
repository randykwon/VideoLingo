import CryptoKit
import Foundation

// MARK: - SpikDoum 호환 자체 모델 카탈로그 (whisper.cpp GGML 9종 + llama.cpp GGUF 10종)

public enum ManagedRuntimeRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case stt
    case translation

    public var id: String { rawValue }
    public var title: String { self == .stt ? "STT" : "번역" }
    /// SpikDoum(18880/18881)과 동시 실행해도 포트가 충돌하지 않도록 18882/18883을 사용합니다.
    public var port: Int { self == .stt ? 18882 : 18883 }
    public var executable: String { self == .stt ? "whisper-server" : "llama-server" }
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    public var customFileExtension: String { self == .stt ? "bin" : "gguf" }
}

public struct ManagedRuntimeModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let role: ManagedRuntimeRole
    public let repository: String
    public let revision: String
    public let filename: String
    public let bytes: Int64
    public let sha256: String
    public let note: String
    public var badge: String?
    public var isCustom: Bool

    public init(
        id: String,
        name: String,
        role: ManagedRuntimeRole,
        repository: String,
        revision: String,
        filename: String,
        bytes: Int64,
        sha256: String,
        note: String,
        badge: String? = nil,
        isCustom: Bool = false
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.repository = repository
        self.revision = revision
        self.filename = filename
        self.bytes = bytes
        self.sha256 = sha256
        self.note = note
        self.badge = badge
        self.isCustom = isCustom
    }

    public var url: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")! }
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    public var sourceURL: URL? { repository.isEmpty ? nil : URL(string: "https://huggingface.co/\(repository)") }
}

public struct CustomManagedRuntimeModel: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var role: ManagedRuntimeRole
    public var filename: String
    public var bytes: Int64

    public init(id: String, name: String, role: ManagedRuntimeRole, filename: String, bytes: Int64) {
        self.id = id
        self.name = name
        self.role = role
        self.filename = filename
        self.bytes = bytes
    }

    public var asManagedModel: ManagedRuntimeModel {
        ManagedRuntimeModel(
            id: id,
            name: name,
            role: role,
            repository: "",
            revision: "",
            filename: "custom/\(filename)",
            bytes: bytes,
            sha256: "",
            note: "사용자가 직접 추가한 로컬 .\(role.customFileExtension) 모델",
            badge: "로컬 추가",
            isCustom: true
        )
    }
}

public enum ManagedRuntimeModelCatalog {
    private static let whisperRepo = "ggerganov/whisper.cpp"
    private static let whisperRev = "5359861c739e955e79d9a303bcbc70fb988958b1"

    public static let all: [ManagedRuntimeModel] = [
        // MARK: - STT Models (Whisper.cpp GGML — 9종)
        ManagedRuntimeModel(
            id: "whisper-tiny",
            name: "Whisper Tiny · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-tiny.bin",
            bytes: 77_691_713,
            sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
            note: "초경량 · 최저 지연 · 저사양/배터리 절약"
        ),
        ManagedRuntimeModel(
            id: "whisper-base",
            name: "Whisper Base · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-base.bin",
            bytes: 147_951_465,
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
            note: "가볍고 빠른 다국어 인식"
        ),
        ManagedRuntimeModel(
            id: "whisper-small",
            name: "Whisper Small · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-small.bin",
            bytes: 487_601_967,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            note: "균형 잡힌 다국어 정확도"
        ),
        ManagedRuntimeModel(
            id: "whisper-medium-q5",
            name: "Whisper Medium Q5 · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-medium-q5_0.bin",
            bytes: 539_212_467,
            sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
            note: "Small 크기에서 Medium급 정확도 · 양자화"
        ),
        ManagedRuntimeModel(
            id: "whisper-large-v3-turbo-q5",
            name: "Whisper Large v3 Turbo Q5 · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-large-v3-turbo-q5_0.bin",
            bytes: 574_041_195,
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            note: "한국어·일본어·영어 매우 우수 · 빠른 추론 속도",
            badge: "추천"
        ),
        ManagedRuntimeModel(
            id: "whisper-large-v3-turbo-q8",
            name: "Whisper Large v3 Turbo Q8 · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-large-v3-turbo-q8_0.bin",
            bytes: 874_188_075,
            sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
            note: "Large v3 Turbo 고정밀 양자화 · 높은 정확도와 속도"
        ),
        ManagedRuntimeModel(
            id: "whisper-large-v3-q5",
            name: "Whisper Large v3 Q5 · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-large-v3-q5_0.bin",
            bytes: 1_081_140_203,
            sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
            note: "최고 정확도 · 억양·잡음·일본어/다국어 강점"
        ),
        ManagedRuntimeModel(
            id: "whisper-medium",
            name: "Whisper Medium · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-medium.bin",
            bytes: 1_533_763_059,
            sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
            note: "비양자화 Medium · 정밀 인식"
        ),
        ManagedRuntimeModel(
            id: "whisper-large-v3-turbo",
            name: "Whisper Large v3 Turbo · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-large-v3-turbo.bin",
            bytes: 1_624_555_275,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
            note: "비양자화 Large v3 Turbo · 최고 품질 + 고속"
        ),

        // MARK: - Translation Models (llama.cpp GGUF — 10종)
        ManagedRuntimeModel(
            id: "qwen25-05b-q4",
            name: "Qwen2.5 0.5B Instruct · Q4",
            role: .translation,
            repository: "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
            revision: "9217f5db79a29953eb74d5343926648285ec7e67",
            filename: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
            bytes: 491_400_032,
            sha256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
            note: "초경량 · 최저 메모리/초고속 번역 · Apache-2.0"
        ),
        ManagedRuntimeModel(
            id: "qwen25-15b-q4",
            name: "Qwen2.5 1.5B Instruct · Q4",
            role: .translation,
            repository: "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
            revision: "91cad51170dc346986eccefdc2dd33a9da36ead9",
            filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            bytes: 1_117_320_736,
            sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e",
            note: "가볍고 빠른 다국어 번역 · Apache-2.0"
        ),
        ManagedRuntimeModel(
            id: "gemma2-2b-q4",
            name: "Gemma 2 2B Instruct · Q4",
            role: .translation,
            repository: "bartowski/gemma-2-2b-it-GGUF",
            revision: "855f67caed130e1befc571b52bd181be2e858883",
            filename: "gemma-2-2b-it-Q4_K_M.gguf",
            bytes: 1_708_582_752,
            sha256: "e0aee85060f168f0f2d8473d7ea41ce2f3230c1bc1374847505ea599288a7787",
            note: "Google Gemma 2 · 자연스러운 경량 한/영/일 번역"
        ),
        ManagedRuntimeModel(
            id: "qwen3-17b-q8",
            name: "Qwen3 1.7B · Q8",
            role: .translation,
            repository: "Qwen/Qwen3-1.7B-GGUF",
            revision: "90862c4b9d2787eaed51d12237eafdfe7c5f6077",
            filename: "Qwen3-1.7B-Q8_0.gguf",
            bytes: 1_834_426_016,
            sha256: "061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a",
            note: "차세대 Qwen3 고정밀 경량 다국어 번역 · Apache-2.0"
        ),
        ManagedRuntimeModel(
            id: "llama32-3b-q4",
            name: "Llama 3.2 3B Instruct · Q4",
            role: .translation,
            repository: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            revision: "5ab33fa94d1d04e903623ae72c95d1696f09f9e8",
            filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            bytes: 2_019_377_696,
            sha256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
            note: "Meta Llama 3.2 · 영어·유럽어 회화 번역 강점"
        ),
        ManagedRuntimeModel(
            id: "qwen25-3b-q4",
            name: "Qwen2.5 3B Instruct · Q4",
            role: .translation,
            repository: "Qwen/Qwen2.5-3B-Instruct-GGUF",
            revision: "7dabda4d13d513e3e842b20f0d435c732f172cbe",
            filename: "qwen2.5-3b-instruct-q4_k_m.gguf",
            bytes: 2_104_932_768,
            sha256: "626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d",
            note: "한·영·일·중 유창한 번역과 빠른 속도의 균형 · Apache-2.0",
            badge: "균형 추천"
        ),
        ManagedRuntimeModel(
            id: "gemma3-4b-q4",
            name: "Gemma 3 4B Instruct · Q4",
            role: .translation,
            repository: "unsloth/gemma-3-4b-it-GGUF",
            revision: "5a3566e716d80f709ed7b79817eaf7733d2a1fce",
            filename: "gemma-3-4b-it-Q4_K_M.gguf",
            bytes: 2_489_894_016,
            sha256: "04a43a22e8d2003deda5acc262f68ec1005fa76c735a9962a8c77042a74a7d19",
            note: "Google 최신 Gemma 3 · 한국어·일본어·영어 고품질 번역",
            badge: "추천"
        ),
        ManagedRuntimeModel(
            id: "qwen3-4b-q4",
            name: "Qwen3 4B · Q4",
            role: .translation,
            repository: "Qwen/Qwen3-4B-GGUF",
            revision: "bc640142c66e1fdd12af0bd68f40445458f3869b",
            filename: "Qwen3-4B-Q4_K_M.gguf",
            bytes: 2_497_280_256,
            sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
            note: "차세대 Qwen3 4B · 뛰어난 문맥 이해·다국어 번역 · Apache-2.0"
        ),
        ManagedRuntimeModel(
            id: "qwen25-7b-q4",
            name: "Qwen2.5 7B Instruct · Q4",
            role: .translation,
            repository: "bartowski/Qwen2.5-7B-Instruct-GGUF",
            revision: "8911e8a47f92bac19d6f5c64a2e2095bd2f7d031",
            filename: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
            bytes: 4_683_074_240,
            sha256: "65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423",
            note: "고품질 대형 번역 모델 · 16GB+ Mac 권장 · Apache-2.0"
        ),
        ManagedRuntimeModel(
            id: "gemma3-12b-q4",
            name: "Gemma 3 12B Instruct · Q4",
            role: .translation,
            repository: "unsloth/gemma-3-12b-it-GGUF",
            revision: "d15e4c7dc21dc55d56bf8549db57a71ad8a2a35d",
            filename: "gemma-3-12b-it-Q4_K_M.gguf",
            bytes: 7_300_778_336,
            sha256: "15b8fd9d8672cd4240c178c217ca781409291f34e353d2e913b29c7602ceb3ff",
            note: "최고 품질 번역 · 24GB+ Mac 권장 · Google Gemma 3"
        )
    ]

    public static func model(_ id: String) -> ManagedRuntimeModel? {
        all.first { $0.id == id }
    }
}

public struct ManagedRuntimeModelStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func file(_ model: ManagedRuntimeModel) -> URL {
        root.appendingPathComponent(model.filename)
    }

    public func receipt(_ model: ManagedRuntimeModel) -> URL {
        root.appendingPathComponent(model.id + ".verified")
    }

    public func installed(_ model: ManagedRuntimeModel) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: file(model).path)[.size] as? NSNumber)?.int64Value
        if model.isCustom { return (size ?? 0) > 0 }
        return size == model.bytes && (try? String(contentsOf: receipt(model), encoding: .utf8)) == model.sha256
    }

    public func finalize(_ temporary: URL, model: ManagedRuntimeModel, cancelled: () -> Bool = { false }) throws {
        guard let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber,
              size.int64Value == model.bytes else {
            throw VideoLingoError.modelUnavailable("모델 파일 크기가 일치하지 않습니다. 다시 다운로드해주세요.")
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            if cancelled() { throw CancellationError() }
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == model.sha256 else {
            throw VideoLingoError.modelUnavailable("모델 SHA-256 검증에 실패했습니다. 손상된 파일은 적용하지 않습니다.")
        }
        if cancelled() { throw CancellationError() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file(model).path) {
            try FileManager.default.removeItem(at: file(model))
        }
        try FileManager.default.moveItem(at: temporary, to: file(model))
        try model.sha256.write(to: receipt(model), atomically: true, encoding: .utf8)
    }

    public func remove(_ model: ManagedRuntimeModel) throws {
        for path in [receipt(model), file(model)] where FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}

public final class ManagedRuntimeModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let model: ManagedRuntimeModel
    private let store: ManagedRuntimeModelStore
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false
    private var lastProgress = Date.distantPast
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    public var progress: ((Double, Bool) -> Void)?
    public var completion: ((Result<Void, Error>) -> Void)?

    public init(model: ManagedRuntimeModel, store: ManagedRuntimeModelStore) {
        self.model = model
        self.store = store
    }

    public func start() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        task = session?.downloadTask(with: model.url)
        task?.resume()
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        task?.cancel()
    }

    private func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        completion?(result)
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard Date().timeIntervalSince(lastProgress) > 0.2 else { return }
        lastProgress = Date()
        progress?(min(1, Double(totalBytesWritten) / Double(max(1, model.bytes))), false)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let http = downloadTask.response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.url?.scheme == "https" else {
                throw VideoLingoError.modelUnavailable("모델 다운로드 서버가 정상 파일을 반환하지 않았습니다.")
            }
            progress?(1, true)
            try store.finalize(location, model: model, cancelled: isCancelled)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

// MARK: - 자체 whisper-server 클라이언트

public struct ManagedWhisperClient: Sendable {
    public struct TranscriptionOutput: Sendable {
        public let text: String
        public let language: String?
        public let cues: [TranscriptCue]
        public let confidence: Double?
    }

    public let baseURL: URL
    public let apiKey: String
    public var session: URLSession

    public init(baseURL: URL = ManagedRuntimeRole.stt.baseURL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public static func wavData(pcm16Mono: Data, sampleRate: UInt32 = 16_000) -> Data {
        var result = Data()
        func appendString(_ value: String) { result.append(Data(value.utf8)) }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        appendString("RIFF")
        appendLE(UInt32(pcm16Mono.count + 36))
        appendString("WAVEfmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(sampleRate)
        appendLE(sampleRate * 2)
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        appendString("data")
        appendLE(UInt32(pcm16Mono.count))
        result.append(pcm16Mono)
        return result
    }

    public func makeRequest(audioData: Data, filename: String = "speech.wav", contentType: String = "audio/wav", language: String?) -> URLRequest {
        let boundary = "VideoLingo-" + UUID().uuidString
        var request = URLRequest(url: baseURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        let sttLang = VideoLingoLanguageCatalog.whisperParameter(for: language)
        for (name, value) in [
            ("response_format", "verbose_json"),
            ("language", sttLang),
            ("temperature", "0"),
            ("no_speech_thold", "0.6")
        ] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n")
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    public func transcribe(audioData: Data, filename: String = "speech.wav", contentType: String = "audio/wav", language: String?) async throws -> TranscriptionOutput {
        let request = makeRequest(audioData: audioData, filename: filename, contentType: contentType, language: language)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw VideoLingoError.modelUnavailable("자체 whisper.cpp 서버 연결 실패: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw VideoLingoError.modelUnavailable("자체 whisper.cpp 서버 응답 오류 (HTTP \(status)). 모델·서버 관리에서 상태를 확인하세요.")
        }
        return try Self.parse(data)
    }

    public static func parse(_ data: Data) throws -> TranscriptionOutput {
        struct Segment: Decodable {
            let start: Double?
            let end: Double?
            let text: String?
            let avgLogprob: Double?
            let noSpeechProb: Double?

            enum CodingKeys: String, CodingKey {
                case start, end, text
                case avgLogprob = "avg_logprob"
                case noSpeechProb = "no_speech_prob"
            }
        }
        struct Payload: Decodable {
            let text: String?
            let language: String?
            let segments: [Segment]?
        }
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        var cues: [TranscriptCue] = []
        var confidences: [Double] = []
        for segment in decoded.segments ?? [] {
            let cleaned = TranscriptTextSanitizer.cleanWhisperText(segment.text ?? "")
            let noSpeech = segment.noSpeechProb ?? 0
            let logprob = segment.avgLogprob ?? -0.25
            guard !cleaned.isEmpty,
                  !TranscriptTextSanitizer.isLikelyHallucination(cleaned, noSpeechProb: noSpeech, avgLogprob: logprob) else { continue }
            if let start = segment.start, let end = segment.end, end > start {
                cues.append(TranscriptCue(startTime: start, endTime: end, text: cleaned))
            }
            if let lp = segment.avgLogprob {
                confidences.append(min(1, max(0, exp(lp))))
            }
        }
        let combinedText: String
        if !cues.isEmpty {
            combinedText = cues.map(\.text).joined(separator: "\n")
        } else {
            let raw = TranscriptTextSanitizer.cleanWhisperText(decoded.text ?? "")
            combinedText = TranscriptTextSanitizer.isLikelyHallucination(raw, noSpeechProb: 0.4, avgLogprob: -0.7) ? "" : raw
        }
        let avgConfidence = confidences.isEmpty ? (combinedText.isEmpty ? nil : 0.78) : confidences.reduce(0, +) / Double(confidences.count)
        return TranscriptionOutput(text: combinedText, language: decoded.language, cues: cues, confidence: avgConfidence)
    }
}

// MARK: - Deepgram Nova-3 사전 녹음 파일 STT 클라이언트

public struct DeepgramPreRecordedClient: Sendable {
    public struct TranscriptionOutput: Sendable {
        public let text: String
        public let language: String?
        public let cues: [TranscriptCue]
        public let confidence: Double?
    }

    public let apiKey: String
    public var session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public func makeRequest(audioData: Data, contentType: String = "audio/mp4", language: String?) throws -> URLRequest {
        guard !apiKey.isEmpty else {
            throw VideoLingoError.modelUnavailable("엔진 설정에서 Deepgram API 키를 저장해주세요.")
        }
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var items = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "utterances", value: "true")
        ]
        let langParam = VideoLingoLanguageCatalog.whisperParameter(for: language)
        if langParam == "auto" {
            items.append(URLQueryItem(name: "detect_language", value: "true"))
        } else {
            items.append(URLQueryItem(name: "language", value: langParam))
        }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData
        return request
    }

    public func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionOutput {
        let audioData = try Data(contentsOf: audioURL)
        let contentType = audioURL.pathExtension.lowercased() == "wav" ? "audio/wav" : "audio/mp4"
        let request = try makeRequest(audioData: audioData, contentType: contentType, language: language)
        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = VideoLingoError.modelUnavailable("Deepgram 연결 실패: \(error.localizedDescription)")
                if attempt < 2 {
                    try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
                    continue
                }
                throw lastError!
            }
            guard let http = response as? HTTPURLResponse else {
                throw VideoLingoError.modelUnavailable("Deepgram 응답을 해석할 수 없습니다.")
            }
            if (200..<300).contains(http.statusCode) {
                return try Self.parse(data)
            }
            let detail = String(data: data, encoding: .utf8)?.prefix(180) ?? ""
            lastError = VideoLingoError.modelUnavailable("Deepgram 오류 HTTP \(http.statusCode): \(detail)")
            if attempt < 2 && (http.statusCode == 429 || (500...504).contains(http.statusCode)) {
                try await Task.sleep(for: .milliseconds(600 * (1 << attempt)))
                continue
            }
            throw lastError!
        }
        throw lastError ?? VideoLingoError.modelUnavailable("Deepgram STT 요청에 실패했습니다.")
    }

    public static func parse(_ data: Data) throws -> TranscriptionOutput {
        struct Response: Decodable {
            struct Results: Decodable {
                struct Utterance: Decodable {
                    let start: Double
                    let end: Double
                    let confidence: Double?
                    let transcript: String
                    let speaker: Int?
                }
                struct Channel: Decodable {
                    struct Alternative: Decodable {
                        let transcript: String
                        let confidence: Double?
                    }
                    let detectedLanguage: String?
                    let alternatives: [Alternative]

                    enum CodingKeys: String, CodingKey {
                        case detectedLanguage = "detected_language"
                        case alternatives
                    }
                }
                let channels: [Channel]?
                let utterances: [Utterance]?
            }
            let results: Results?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let detectedLanguage = decoded.results?.channels?.first?.detectedLanguage
        let utterances = decoded.results?.utterances ?? []
        var cues: [TranscriptCue] = []
        var confidences: [Double] = []
        for utterance in utterances {
            let cleaned = TranscriptTextSanitizer.cleanWhisperText(utterance.transcript)
            guard !cleaned.isEmpty, utterance.end > utterance.start else { continue }
            let prefix = utterance.speaker.map { "[화자 \($0 + 1)] " } ?? ""
            cues.append(TranscriptCue(startTime: utterance.start, endTime: utterance.end, text: prefix + cleaned))
            if let confidence = utterance.confidence { confidences.append(confidence) }
        }
        if !cues.isEmpty {
            let avg = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
            return TranscriptionOutput(
                text: cues.map(\.text).joined(separator: "\n"),
                language: detectedLanguage,
                cues: cues,
                confidence: avg
            )
        }
        let fallback = decoded.results?.channels?.first?.alternatives.first
        let fallbackText = TranscriptTextSanitizer.cleanWhisperText(fallback?.transcript ?? "")
        return TranscriptionOutput(
            text: fallbackText,
            language: detectedLanguage,
            cues: [],
            confidence: fallback?.confidence
        )
    }
}

// MARK: - Azure Translator 클라이언트 (화자 라벨 보존 배치 번역)

public struct AzureTranslatorClient: Sendable {
    public let apiKey: String
    public let region: String
    public var session: URLSession

    public init(apiKey: String, region: String, session: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public func translate(_ text: String, targetLanguage: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw VideoLingoError.modelUnavailable("엔진 설정에서 Azure Translator API 키를 저장해주세요.")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parsed = lines.map { splitSpeakerPrefix($0) }
        let bodiesToTranslate = parsed.enumerated().compactMap { index, item -> (Int, String)? in
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : (index, body)
        }
        guard !bodiesToTranslate.isEmpty else { return text }

        let targetCode = VideoLingoLanguageCatalog.azureCode(for: targetLanguage)
        var components = URLComponents(string: "https://api.cognitive.microsofttranslator.com/translate")!
        components.queryItems = [
            URLQueryItem(name: "api-version", value: "3.0"),
            URLQueryItem(name: "to", value: targetCode)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        if !region.isEmpty {
            request.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        }
        let payload = bodiesToTranslate.map { ["Text": $0.1] }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw VideoLingoError.modelUnavailable("Azure Translator 연결 실패: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw VideoLingoError.modelUnavailable("Azure 번역 실패 (HTTP \(status)). 키와 리전을 확인해주세요.")
        }
        let translatedBodies = try Self.parseBatch(data)
        guard translatedBodies.count == bodiesToTranslate.count else {
            throw VideoLingoError.modelUnavailable("Azure 번역 응답 항목 수가 일치하지 않습니다.")
        }
        var outputLines = lines
        for ((lineIndex, _), translatedBody) in zip(bodiesToTranslate, translatedBodies) {
            if let prefix = parsed[lineIndex].prefix {
                outputLines[lineIndex] = "\(prefix) \(translatedBody)"
            } else {
                outputLines[lineIndex] = translatedBody
            }
        }
        return outputLines.joined(separator: "\n")
    }

    public static func parseBatch(_ data: Data) throws -> [String] {
        struct Item: Decodable {
            struct Translation: Decodable { let text: String }
            let translations: [Translation]
        }
        let decoded = try JSONDecoder().decode([Item].self, from: data)
        let texts = decoded.compactMap { $0.translations.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard texts.count == decoded.count, !texts.isEmpty else {
            throw VideoLingoError.modelUnavailable("Azure 번역 결과가 비어 있습니다.")
        }
        return texts
    }

    private func splitSpeakerPrefix(_ line: String) -> (prefix: String?, body: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else {
            return (nil, trimmed)
        }
        let prefix = String(trimmed[...close])
        guard prefix.count <= 42 else { return (nil, trimmed) }
        let body = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        return (prefix, body)
    }
}

// MARK: - SpikDoum 호환 로컬 커스텀 번역 API 클라이언트

public struct CustomLocalTranslatorClient: Sendable {
    public let settings: LocalTranslationAPISettings
    public let apiKey: String
    public var session: URLSession

    public init(settings: LocalTranslationAPISettings, apiKey: String = "", session: URLSession = .shared) {
        self.settings = settings
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public func makeRequest(text: String, source: String, target: String) throws -> URLRequest {
        let endpoint = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw VideoLingoError.modelUnavailable("로컬 번역 주소를 http(s)://호스트:포트/v1/translate 형태로 입력해주세요.")
        }
        guard let template = settings.requestJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: template),
              object is [String: Any] else {
            throw VideoLingoError.modelUnavailable("로컬 번역 요청 JSON이 올바르지 않습니다.")
        }
        guard Self.containsTextPlaceholder(object) else {
            throw VideoLingoError.modelUnavailable("요청 JSON에 {{text}} 플레이스홀더를 포함해야 합니다.")
        }
        let values = ["{{text}}": text, "{{source}}": source, "{{target}}": target]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = min(180, max(5, settings.timeout))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.replace(object, values: values))
        return request
    }

    public func translate(_ text: String, source: String, target: String) async throws -> String {
        let request = try makeRequest(text: text, source: source, target: target)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw VideoLingoError.modelUnavailable("로컬 번역 응답 시간 초과. 서버 실행 상태와 연결을 확인해주세요.")
        } catch {
            throw VideoLingoError.modelUnavailable("로컬 번역 서버 연결 실패: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw VideoLingoError.modelUnavailable("로컬 번역 서버의 HTTP 응답을 확인하지 못했습니다.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VideoLingoError.modelUnavailable("로컬 번역 HTTP \(http.statusCode). 주소·인증·요청 JSON을 확인해주세요.")
        }
        let raw = try Self.parse(data, path: settings.responsePath)
        return TranslationTextSanitizer.cleanLLMOutput(raw, source: text)
    }

    public static func parse(_ data: Data, path: String = "") throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw VideoLingoError.modelUnavailable("로컬 번역 서버가 JSON 응답을 반환하지 않았습니다.")
        }
        if let value = object as? [String: Any],
           let choices = value["choices"] as? [[String: Any]],
           let reason = choices.first?["finish_reason"] as? String,
           reason == "length" || reason == "content_filter" {
            throw VideoLingoError.modelUnavailable("번역 응답이 완료되지 않았습니다 (\(reason)).")
        }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidatePaths = trimmedPath.isEmpty
            ? ["translation", "translated_text", "translatedText", "data.translation", "data.translated_text", "translations.0.text", "choices.0.message.content", "output", "text"]
            : [trimmedPath]
        let result: String?
        if trimmedPath.isEmpty, let plain = object as? String {
            result = plain
        } else {
            result = candidatePaths.lazy.compactMap { lookup($0, in: object) as? String }.first
        }
        guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VideoLingoError.modelUnavailable("응답에서 번역 문자열을 찾지 못했습니다. 응답 경로(예: translation, data.translation)를 확인해주세요.")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lookup(_ path: String, in object: Any) -> Any? {
        var value: Any? = object
        for component in path.split(separator: ".").map(String.init) {
            if let dictionary = value as? [String: Any] {
                value = dictionary[component]
            } else if let array = value as? [Any], let index = Int(component), array.indices.contains(index) {
                value = array[index]
            } else {
                return nil
            }
        }
        return value
    }

    private static func containsTextPlaceholder(_ object: Any) -> Bool {
        if let text = object as? String { return text.contains("{{text}}") }
        if let array = object as? [Any] { return array.contains(where: containsTextPlaceholder) }
        if let dictionary = object as? [String: Any] { return dictionary.values.contains(where: containsTextPlaceholder) }
        return false
    }

    private static func replace(_ object: Any, values: [String: String]) -> Any {
        if let string = object as? String {
            // 단일 패스로 치환해 원문 내부에 {{text}} 문자열이 있어도 재치환되지 않게 합니다.
            let regex = try! NSRegularExpression(pattern: #"\{\{(?:text|source|target)\}\}"#)
            var value = string
            for match in regex.matches(in: string, range: NSRange(string.startIndex..., in: string)).reversed() {
                guard let original = Range(match.range, in: string),
                      let range = Range(match.range, in: value),
                      let replacement = values[String(string[original])] else { continue }
                value.replaceSubrange(range, with: replacement)
            }
            return value
        }
        if let array = object as? [Any] { return array.map { replace($0, values: values) } }
        if let dictionary = object as? [String: Any] { return dictionary.mapValues { replace($0, values: values) } }
        return object
    }
}
