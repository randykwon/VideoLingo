import Foundation
import Observation
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
    private var activeLeases: [UUID: Int] = [:]

    private init() {
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
        return selected
    }

    func release(_ id: UUID) {
        activeLeases[id] = max(0, activeLeases[id, default: 0] - 1)
    }

    func add(name: String, address: String, token: String) throws {
        let normalized = address.contains("://") ? address : "https://\(address)"
        guard let url = URL(string: normalized), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw URLError(.badURL)
        }
        workers.append(RemoteWorkerConfiguration(name: name.trimmingCharacters(in: .whitespacesAndNewlines), baseURL: url, authenticationToken: token))
        persist()
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
            // STTLMMServer의 공개 health/system API를 사용합니다.
            var healthRequest = URLRequest(url: worker.baseURL.appending(path: "/health"))
            healthRequest.timeoutInterval = 5
            let (healthData, healthResponse) = try await URLSession.shared.data(for: healthRequest)
            guard let healthHTTP = healthResponse as? HTTPURLResponse, healthHTTP.statusCode == 200,
                  let health = try JSONSerialization.jsonObject(with: healthData) as? [String: Any],
                  let healthStatus = health["status"] as? String,
                  healthStatus == "ok" || healthStatus == "degraded" else {
                throw NSError(domain: "VideoLingo.STTLMMServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "STTLMMServer health 확인에 실패했습니다."])
            }

            var systemRequest = URLRequest(url: worker.baseURL.appending(path: "/v1/system"))
            systemRequest.timeoutInterval = 5
            if !worker.authenticationToken.isEmpty {
                systemRequest.setValue("Bearer \(worker.authenticationToken)", forHTTPHeaderField: "Authorization")
            }
            let (systemData, systemResponse) = try await URLSession.shared.data(for: systemRequest)
            guard let systemHTTP = systemResponse as? HTTPURLResponse, systemHTTP.statusCode == 200,
                  let system = try JSONSerialization.jsonObject(with: systemData) as? [String: Any] else {
                throw NSError(domain: "VideoLingo.STTLMMServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "API 키 또는 /v1/system 접근을 확인하세요."])
            }
            let performance = system["effective_performance"] as? [String: Any] ?? [:]
            let runtime = system["runtime"] as? [String: Any] ?? [:]
            let inFlight = runtime["in_flight"] as? [String: Any] ?? [:]
            let sttActive = inFlight["stt_active"] as? Int ?? 0
            let llmActive = inFlight["llm_active"] as? Int ?? 0
            let defaults = system["defaults"] as? [String: Any] ?? [:]
            let version = health["version"] as? String ?? "STTLMMServer"
            let accelerator = health["accelerator"] as? String ?? "unknown"
            states[id] = .available(RemoteWorkerStatus(
                workerID: id,
                name: worker.name.isEmpty ? worker.baseURL.host() ?? "STTLMMServer" : worker.name,
                version: "\(version) · \(accelerator)",
                activeJobs: max(sttActive, llmActive),
                capabilities: RemoteWorkerCapabilities(
                    sttSlots: performance["stt_concurrency"] as? Int ?? 1,
                    translationSlots: performance["llm_concurrency"] as? Int ?? 1,
                    sttModels: [defaults["stt_model"] as? String].compactMap { $0 },
                    translationModels: [defaults["llm_model"] as? String].compactMap { $0 }
                )
            ))
        } catch {
            states[id] = .unavailable(error.localizedDescription)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(workers) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
