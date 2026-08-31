import Foundation
import Observation
import Security
import VideoLingoCore

struct RemoteWorkerConfiguration: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var baseURL: URL
    var authenticationToken: String
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, baseURL: URL, authenticationToken: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.authenticationToken = authenticationToken
        self.isEnabled = isEnabled
    }
}

enum RemoteWorkerConnectionState: Equatable {
    case unchecked
    case checking
    case available(RemoteWorkerStatus)
    case unavailable(String)
}

@MainActor
@Observable
final class RemoteWorkerPool {
    static let shared = RemoteWorkerPool()

    private(set) var workers: [RemoteWorkerConfiguration] = []
    private(set) var states: [UUID: RemoteWorkerConnectionState] = [:]
    private let defaultsKey = "remoteWorkerConfigurations.v1"
    private let credentialStore = RemoteServerCredentialStore()
    private var activeLeases: [UUID: Int] = [:]
    private(set) var hasDefaultAuthenticationToken = false

    private init() {
        hasDefaultAuthenticationToken = credentialStore.hasToken
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([RemoteWorkerConfiguration].self, from: data) else { return }
        workers = decoded
    }

    var availableWorkers: [(RemoteWorkerConfiguration, RemoteWorkerStatus)] {
        workers.compactMap { worker in
            guard worker.isEnabled, case let .available(status) = states[worker.id] else { return nil }
            return (worker, status)
        }
    }

    var totalSTTSlots: Int { availableWorkers.reduce(0) { $0 + $1.1.capabilities.sttSlots } }
    var totalTranslationSlots: Int { availableWorkers.reduce(0) { $0 + $1.1.capabilities.translationSlots } }

    func acquire() -> RemoteWorkerConfiguration? {
        let candidates = availableWorkers.filter { worker, status in
            activeLeases[worker.id, default: 0] < max(1, min(status.capabilities.sttSlots, status.capabilities.translationSlots))
        }
        guard let selected = candidates.min(by: {
            activeLeases[$0.0.id, default: 0] < activeLeases[$1.0.id, default: 0]
        })?.0 else { return nil }
        activeLeases[selected.id, default: 0] += 1
        return workerUsingDefaultTokenIfNeeded(selected)
    }

    func release(_ id: UUID) {
        activeLeases[id] = max(0, activeLeases[id, default: 0] - 1)
    }

    func saveDefaultAuthenticationToken(_ token: String) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw NSError(
                domain: "VideoLingo.STTLMMServer",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "저장할 API 키를 입력하세요."]
            )
        }
        try credentialStore.save(value)
        hasDefaultAuthenticationToken = true
    }

    func clearDefaultAuthenticationToken() throws {
        try credentialStore.clear()
        hasDefaultAuthenticationToken = false
    }

    func add(name: String, address: String, token: String) throws {
        let configuration = try configuration(name: name, address: address, token: token)
        workers.append(configuration)
        persist()
    }

    /// 별도 VideoLingo Worker 설치 없이 실행 중인 STTLMMServer를 확인한 뒤 저장합니다.
    @discardableResult
    func connectAndAdd(name: String, address: String, token: String) async throws -> RemoteWorkerStatus {
        let worker = try configuration(name: name, address: address, token: token)
        guard !workers.contains(where: { $0.baseURL == worker.baseURL }) else {
            throw NSError(
                domain: "VideoLingo.STTLMMServer",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "이미 추가된 STTLMMServer 주소입니다."]
            )
        }
        states[worker.id] = .checking
        do {
            let status = try await checkConnection(to: workerUsingDefaultTokenIfNeeded(worker))
            workers.append(worker)
            states[worker.id] = .available(status)
            persist()
            return status
        } catch {
            states[worker.id] = nil
            throw error
        }
    }

    func remove(_ id: UUID) {
        workers.removeAll { $0.id == id }
        states[id] = nil
        persist()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = workers.firstIndex(where: { $0.id == id }) else { return }
        workers[index].isEnabled = enabled
        if !enabled { states[id] = .unchecked }
        persist()
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for worker in workers where worker.isEnabled {
                group.addTask { await self.refresh(worker.id) }
            }
        }
    }

    func refresh(_ id: UUID) async {
        guard let worker = workers.first(where: { $0.id == id }), worker.isEnabled else { return }
        states[id] = .checking
        do {
            states[id] = .available(try await checkConnection(to: workerUsingDefaultTokenIfNeeded(worker)))
        } catch {
            states[id] = .unavailable(error.localizedDescription)
        }
    }

    private func configuration(name: String, address: String, token: String) throws -> RemoteWorkerConfiguration {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let suppliedScheme = value.contains("://")
        if !suppliedScheme { value = "http://\(value)" }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil else {
            throw URLError(.badURL)
        }
        if !suppliedScheme && components.port == nil { components.port = 8848 }
        components.scheme = scheme
        guard let url = components.url else { throw URLError(.badURL) }
        return RemoteWorkerConfiguration(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: url,
            authenticationToken: token.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func checkConnection(to worker: RemoteWorkerConfiguration) async throws -> RemoteWorkerStatus {
        // STTLMMServer 자체의 공개 API만 사용하므로 VideoLingo용 Worker 설치가 필요 없습니다.
        var healthRequest = URLRequest(url: worker.baseURL.appending(path: "/health"))
        healthRequest.timeoutInterval = 5
        let (healthData, healthResponse) = try await URLSession.shared.data(for: healthRequest)
        guard let healthHTTP = healthResponse as? HTTPURLResponse, healthHTTP.statusCode == 200,
              let health = try JSONSerialization.jsonObject(with: healthData) as? [String: Any],
              let healthStatus = health["status"] as? String,
              healthStatus == "ok" || healthStatus == "degraded" else {
            throw NSError(domain: "VideoLingo.STTLMMServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "STTLMMServer /health 확인에 실패했습니다."])
        }

        var systemRequest = URLRequest(url: worker.baseURL.appending(path: "/v1/system"))
        systemRequest.timeoutInterval = 5
        if !worker.authenticationToken.isEmpty {
            systemRequest.setValue("Bearer \(worker.authenticationToken)", forHTTPHeaderField: "Authorization")
        }
        let (systemData, systemResponse) = try await URLSession.shared.data(for: systemRequest)
        guard let systemHTTP = systemResponse as? HTTPURLResponse, systemHTTP.statusCode == 200,
              let system = try JSONSerialization.jsonObject(with: systemData) as? [String: Any] else {
            throw NSError(domain: "VideoLingo.STTLMMServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "STTLMMServer /v1/system 접근 또는 API 키를 확인하세요."])
        }
        let performance = system["effective_performance"] as? [String: Any] ?? [:]
        let runtime = system["runtime"] as? [String: Any] ?? [:]
        let inFlight = runtime["in_flight"] as? [String: Any] ?? [:]
        let sttActive = inFlight["stt_waiting"] as? Int ?? 0
        let llmActive = inFlight["llm_waiting"] as? Int ?? 0
        let defaults = system["defaults"] as? [String: Any] ?? [:]
        let version = health["version"] as? String ?? "STTLMMServer"
        let accelerator = health["accelerator"] as? String ?? "unknown"
        return RemoteWorkerStatus(
            workerID: worker.id,
            name: worker.name.isEmpty ? worker.baseURL.host() ?? "STTLMMServer" : worker.name,
            version: "\(version) · \(accelerator)",
            activeJobs: max(sttActive, llmActive),
            capabilities: RemoteWorkerCapabilities(
                sttSlots: performance["stt_concurrency"] as? Int ?? 1,
                translationSlots: performance["llm_concurrency"] as? Int ?? 1,
                sttModels: [defaults["stt_model"] as? String].compactMap { $0 },
                translationModels: [defaults["llm_model"] as? String].compactMap { $0 }
            )
        )
    }

    private func workerUsingDefaultTokenIfNeeded(_ worker: RemoteWorkerConfiguration) -> RemoteWorkerConfiguration {
        guard worker.authenticationToken.isEmpty, let token = credentialStore.load(), !token.isEmpty else { return worker }
        var authenticatedWorker = worker
        authenticatedWorker.authenticationToken = token
        return authenticatedWorker
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(workers) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

private struct RemoteServerCredentialStore {
    private let service = "com.vvv.VideoLingo.STTLMMServer"
    private let account = "default-api-key"

    var hasToken: Bool { load() != nil }

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
