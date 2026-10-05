import Foundation
import Network
import Observation
import Darwin
import Security
import VideoLingoCore

@MainActor
@Observable
final class EmbeddedAPIServer {
    static let shared = EmbeddedAPIServer()

    enum State: Equatable { case stopped, starting, running, failed(String) }

    struct RequestRecord: Identifiable, Sendable {
        let id: UUID
        let method: String
        let path: String
        let startedAt: Date
        var completedAt: Date?
        var statusCode: Int?

        var duration: TimeInterval? {
            completedAt.map { $0.timeIntervalSince(startedAt) }
        }
    }

    struct APIEndpoint: Identifiable, Sendable {
        let path: String
        let title: String
        let method: String
        var id: String { path }
    }

    static let apiEndpoints = [
        APIEndpoint(path: "/health", title: "상태 확인", method: "GET"),
        APIEndpoint(path: "/v1/system", title: "시스템 정보", method: "GET"),
        APIEndpoint(path: "/v1/audio/transcriptions", title: "STT 음성 인식", method: "POST"),
        APIEndpoint(path: "/v1/translate", title: "LLM 번역", method: "POST")
    ]

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "embeddedAPIEnabled") }
    }
    var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "embeddedAPIPort") }
    }
    var apiKey: String {
        didSet {
            do {
                if apiKey.isEmpty { try credentialStore.clear() }
                else { try credentialStore.save(apiKey) }
                UserDefaults.standard.removeObject(forKey: "embeddedAPIKey")
            } catch {
                lastError = "API 키를 Keychain에 저장하지 못했습니다: \(error.localizedDescription)"
            }
        }
    }
    private(set) var state: State = .stopped
    private(set) var activeRequests = 0
    private(set) var totalRequests = 0
    private(set) var successfulRequests = 0
    private(set) var failedRequests = 0
    private(set) var unauthorizedRequests = 0
    private(set) var activeSTTRequests = 0
    private(set) var activeTranslationRequests = 0
    private(set) var recentRequests: [RequestRecord] = []
    private(set) var startedAt: Date?
    private(set) var lastError: String?
    @ObservationIgnored private let credentialStore = EmbeddedServerCredentialStore()
    @ObservationIgnored private var listener: NWListener?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "embeddedAPIEnabled")
        port = UserDefaults.standard.object(forKey: "embeddedAPIPort") as? Int ?? 8848
        let legacyKey = UserDefaults.standard.string(forKey: "embeddedAPIKey") ?? ""
        apiKey = credentialStore.load() ?? legacyKey
        if credentialStore.load() == nil, !legacyKey.isEmpty,
           (try? credentialStore.save(legacyKey)) != nil {
            UserDefaults.standard.removeObject(forKey: "embeddedAPIKey")
        }
        if isEnabled { Task { await start() } }
    }

    var statusText: String {
        switch state {
        case .stopped: "중지됨"
        case .starting: "시작 중…"
        case .running: "외부 연결 대기 중"
        case .failed(let message): "시작 실패: \(message)"
        }
    }

    var endpoint: String { "http://\(Self.lanAddress() ?? "이 Mac의 IP"):\(port)" }

    func uri(for path: String) -> String { endpoint + path }

    @discardableResult
    func issueAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            let fallback = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            apiKey = "vl_\(fallback)"
            return apiKey
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        apiKey = "vl_\(token)"
        return apiKey
    }

    func revokeAPIKey() { apiKey = "" }

    func clearMonitoring() {
        totalRequests = 0
        successfulRequests = 0
        failedRequests = 0
        unauthorizedRequests = 0
        recentRequests.removeAll()
        lastError = nil
    }

    func apply() async {
        stop()
        if isEnabled { await start() }
    }

    func start() async {
        guard listener == nil else { return }
        state = .starting
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port >= 1, port <= 65_535 else {
                throw NSError(domain: "VideoLingo.EmbeddedAPI", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "포트는 1~65535 범위여야 합니다."])
            }
            let newListener = try NWListener(using: .tcp, on: nwPort)
            newListener.stateUpdateHandler = { [weak self] value in
                Task { @MainActor in
                    guard let self else { return }
                    switch value {
                    case .ready: self.state = .running; self.startedAt = .now
                    case .failed(let error): self.lastError = error.localizedDescription; self.state = .failed(error.localizedDescription); self.listener = nil
                    case .cancelled: if self.listener == nil { self.state = .stopped }
                    default: break
                    }
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener = newListener
            newListener.start(queue: DispatchQueue(label: "com.vvv.VideoLingo.EmbeddedAPI", qos: .utility))
        } catch {
            lastError = error.localizedDescription
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        let current = listener
        listener = nil
        current?.cancel()
        state = .stopped
        startedAt = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "com.vvv.VideoLingo.EmbeddedAPI.connection", qos: .utility))
        HTTPConnectionReader(connection: connection) { [weak self] request in
            Task { @MainActor in await self?.handle(request, connection: connection) }
        }.start()
    }

    private func handle(_ request: HTTPRequest?, connection: NWConnection) async {
        guard let request else { sendJSON(["error": ["message": "잘못된 HTTP 요청입니다."]], status: 400, connection: connection); return }
        let recordID = beginRequest(request)
        var responseStatus = 200
        defer { finishRequest(recordID, status: responseStatus, path: request.path) }
        if !apiKey.isEmpty && request.headers["authorization"] != "Bearer \(apiKey)" {
            responseStatus = 401
            unauthorizedRequests += 1
            sendJSON(["error": ["message": "API 키가 올바르지 않습니다."]], status: 401, connection: connection); return
        }
        do {
            switch (request.method, request.path) {
            case ("GET", "/health"):
                sendJSON(["status": "ok", "version": "VideoLingo", "accelerator": "metal",
                          "stt_backend": "whisperkit", "llm_backend": "mlx_lm",
                          "stt_model_installed": true, "llm_model_installed": true,
                          "loaded_models": 0, "warnings": []], connection: connection)
            case ("GET", "/v1/system"):
                let sttModel = UserDefaults.standard.string(forKey: "sttModel") ?? "large-v3-v20240930_626MB"
                let llmModel = UserDefaults.standard.string(forKey: "translationModel") ?? "mlx-community/Qwen3-8B-4bit"
                sendJSON(["version": "VideoLingo", "effective_performance": ["stt_concurrency": 1, "llm_concurrency": 1,
                          "max_upload_mb": 200, "max_audio_seconds": 10800],
                          "defaults": ["stt_model": sttModel, "llm_model": llmModel],
                          "runtime": ["in_flight": ["stt_waiting": activeRequests, "llm_waiting": 0]]], connection: connection)
            case ("POST", "/v1/audio/transcriptions"):
                let multipart = try request.multipartFile()
                let tempURL = FileManager.default.temporaryDirectory.appending(path: "videolingo-api-\(UUID().uuidString).m4a")
                try multipart.data.write(to: tempURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                let paths = try AppPaths()
                let model = UserDefaults.standard.string(forKey: "sttModel") ?? "large-v3-v20240930_626MB"
                let result = try await directSTT(DirectSTTRequest(audioURL: tempURL, language: multipart.fields["language"], modelID: model, modelsURL: paths.models))
                sendEncodable(result, connection: connection)
            case ("POST", "/v1/translate"):
                let json = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
                let texts = json?["text"] as? [String] ?? (json?["text"] as? String).map { [$0] } ?? []
                guard !texts.isEmpty, let target = json?["target_lang"] as? String else { throw APIError.badRequest("text와 target_lang이 필요합니다.") }
                let paths = try AppPaths()
                let model = UserDefaults.standard.string(forKey: "translationModel") ?? "mlx-community/Qwen3-8B-4bit"
                let result = try await directTranslation(DirectTranslationRequest(texts: texts, sourceLanguage: json?["source_lang"] as? String, targetLanguage: target, modelID: model, modelsURL: paths.models))
                sendJSON(["translations": result.translations.map { ["text": $0] }, "processing_seconds": result.processingSeconds], connection: connection)
            default:
                responseStatus = 404
                sendJSON(["error": ["message": "지원하지 않는 API 경로입니다."]], status: 404, connection: connection)
            }
        } catch {
            responseStatus = error is APIError ? 400 : 500
            lastError = error.localizedDescription
            sendJSON(["error": ["message": error.localizedDescription]], status: responseStatus, connection: connection)
        }
    }

    private func beginRequest(_ request: HTTPRequest) -> UUID {
        let record = RequestRecord(id: UUID(), method: request.method, path: request.path, startedAt: .now)
        totalRequests += 1
        activeRequests += 1
        if request.path == "/v1/audio/transcriptions" { activeSTTRequests += 1 }
        if request.path == "/v1/translate" { activeTranslationRequests += 1 }
        recentRequests.insert(record, at: 0)
        if recentRequests.count > 50 { recentRequests.removeLast(recentRequests.count - 50) }
        return record.id
    }

    private func finishRequest(_ id: UUID, status: Int, path: String) {
        activeRequests = max(0, activeRequests - 1)
        if path == "/v1/audio/transcriptions" { activeSTTRequests = max(0, activeSTTRequests - 1) }
        if path == "/v1/translate" { activeTranslationRequests = max(0, activeTranslationRequests - 1) }
        if (200..<400).contains(status) { successfulRequests += 1 }
        else if status != 401 { failedRequests += 1 }
        guard let index = recentRequests.firstIndex(where: { $0.id == id }) else { return }
        recentRequests[index].completedAt = .now
        recentRequests[index].statusCode = status
    }

    private func directSTT(_ request: DirectSTTRequest) async throws -> DirectSTTResponse {
        let payload = try WireCodec.encode(request)
        return try await callXPC(payload, method: { $0.transcribeDirect($1, withReply: $2) })
    }

    private func directTranslation(_ request: DirectTranslationRequest) async throws -> DirectTranslationResponse {
        let payload = try WireCodec.encode(request)
        return try await callXPC(payload, method: { $0.translateDirect($1, withReply: $2) })
    }

    private func callXPC<T: Decodable & Sendable>(_ payload: Data, method: @escaping @Sendable (VideoLingoAIServiceProtocol, Data, @escaping @Sendable (Data?, String?) -> Void) -> Void) async throws -> T {
        let connection = NSXPCConnection(serviceName: "com.vvv.VideoLingo.AIService")
        connection.remoteObjectInterface = NSXPCInterface(with: VideoLingoAIServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            guard let service = connection.remoteObjectProxyWithErrorHandler({ error in continuation.resume(throwing: error) }) as? VideoLingoAIServiceProtocol else {
                continuation.resume(throwing: APIError.badRequest("내장 AI 서비스에 연결할 수 없습니다.")); return
            }
            method(service, payload) { data, error in
                do {
                    if let error { throw APIError.badRequest(error) }
                    guard let data else { throw APIError.badRequest("내장 AI 서비스 응답이 없습니다.") }
                    continuation.resume(returning: try WireCodec.decode(T.self, from: data))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func sendEncodable<T: Encodable>(_ value: T, connection: NWConnection) {
        do { send(data: try JSONEncoder().encode(value), status: 200, connection: connection) }
        catch { sendJSON(["error": ["message": error.localizedDescription]], status: 500, connection: connection) }
    }
    private func sendJSON(_ object: Any, status: Int = 200, connection: NWConnection) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        send(data: data, status: status, connection: connection)
    }
    private func send(data: Data, status: Int, connection: NWConnection) {
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func lanAddress() -> String? {
        var address: String?
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = item.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: interface.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: host)
        }
        return address
    }
}

private struct EmbeddedServerCredentialStore {
    private let service = "com.vvv.VideoLingo.EmbeddedSTTLMMServer"
    private let account = "external-api-key"

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = Data(token.utf8)
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 오류 \(status)"]
        )
    }
}

private enum APIError: LocalizedError { case badRequest(String); var errorDescription: String? { if case .badRequest(let value) = self { value } else { nil } } }

private struct HTTPRequest: Sendable {
    let method: String; let path: String; let headers: [String: String]; let body: Data
    func multipartFile() throws -> (data: Data, fields: [String: String]) {
        guard let contentType = headers["content-type"], let marker = contentType.range(of: "boundary=") else { throw APIError.badRequest("multipart boundary가 없습니다.") }
        let boundary = "--" + String(contentType[marker.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let parts = body.components(separatedBy: Data(boundary.utf8))
        var file: Data?; var fields: [String: String] = [:]
        for raw in parts {
            guard let divider = raw.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let header = String(decoding: raw[..<divider.lowerBound], as: UTF8.self)
            var value = Data(raw[divider.upperBound...]); if value.suffix(2) == Data("\r\n".utf8) { value.removeLast(2) }
            if header.contains("filename=") { file = value }
            else if let nameRange = header.range(of: "name=\"") {
                let rest = header[nameRange.upperBound...]; if let end = rest.firstIndex(of: "\"") { fields[String(rest[..<end])] = String(decoding: value, as: UTF8.self) }
            }
        }
        guard let file else { throw APIError.badRequest("업로드된 오디오 파일이 없습니다.") }
        return (file, fields)
    }
}

private extension Data {
    func components(separatedBy separator: Data) -> [Data] {
        guard !separator.isEmpty else { return [self] }
        var components: [Data] = []
        var cursor = startIndex
        while cursor < endIndex,
              let match = self[cursor...].range(of: separator) {
            let component = Data(self[cursor..<match.lowerBound])
            if !component.isEmpty { components.append(component) }
            cursor = match.upperBound
        }
        if cursor < endIndex {
            let component = Data(self[cursor..<endIndex])
            if !component.isEmpty { components.append(component) }
        }
        return components
    }
}

private final class HTTPConnectionReader: @unchecked Sendable {
    let connection: NWConnection; let completion: @Sendable (HTTPRequest?) -> Void; var buffer = Data(); var expected = 0
    init(connection: NWConnection, completion: @escaping @Sendable (HTTPRequest?) -> Void) { self.connection = connection; self.completion = completion }
    func start() { receive() }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            guard let self else { return }; if let data { buffer.append(data) }
            if expected == 0, let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                let length = header.split(separator: "\n").first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
                expected = range.upperBound + length
            }
            if (expected > 0 && buffer.count >= expected) || (complete && expected == 0) { completion(Self.parse(buffer)); return }
            if error != nil || buffer.count > 210 * 1024 * 1024 { completion(nil); return }
            receive()
        }
    }
    private static func parse(_ data: Data) -> HTTPRequest? {
        guard let divider = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<divider.lowerBound], as: UTF8.self).split(separator: "\r\n")
        guard let first = lines.first?.split(separator: " "), first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() { let pair = line.split(separator: ":", maxSplits: 1); if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) } }
        return HTTPRequest(method: String(first[0]), path: String(first[1]).split(separator: "?").first.map(String.init) ?? String(first[1]), headers: headers, body: Data(data[divider.upperBound...]))
    }
}
