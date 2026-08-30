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
            var request = URLRequest(url: worker.baseURL.appending(path: RemoteWorkerAPI.statusPath))
            request.timeoutInterval = 5
            request.setValue("Bearer \(worker.authenticationToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let status = try WireCodec.decode(RemoteWorkerStatus.self, from: data)
            guard status.apiVersion == RemoteWorkerAPI.version else {
                throw NSError(domain: "VideoLingo.RemoteWorker", code: 1, userInfo: [NSLocalizedDescriptionKey: "지원하지 않는 Worker API 버전입니다."])
            }
            states[id] = .available(status)
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
