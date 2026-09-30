import Foundation
import Observation
import Security
import VideoLingoCore

struct RemoteWorkerConfiguration: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var baseURL: URL
    var authenticationToken: String
    var usesAuthentication: Bool
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, baseURL: URL, authenticationToken: String, usesAuthentication: Bool = true, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.authenticationToken = authenticationToken
        self.usesAuthentication = usesAuthentication
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, authenticationToken, usesAuthentication, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        authenticationToken = try container.decode(String.self, forKey: .authenticationToken)
        // 기존 설정은 이전과 동일하게 인증을 사용하도록 마이그레이션합니다.
        usesAuthentication = try container.decodeIfPresent(Bool.self, forKey: .usesAuthentication) ?? true
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
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
    private var activeLeases: [Lease: Int] = [:]
    private var cooldownUntil: [UUID: Date] = [:]
    private(set) var recoveringWorkerIDs: Set<UUID> = []
    @ObservationIgnored private var recoveryTasks: [UUID: Task<Void, Never>] = [:]
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
            guard cooldownUntil[worker.id, default: .distantPast] <= .now,
                  !recoveringWorkerIDs.contains(worker.id) else { return nil }
            // 서버 자체 대기열이 모든 STT·번역 슬롯을 차지한 경우 새 요청을 보내지 않습니다.
            let combinedSlots = max(1, status.capabilities.sttSlots + status.capabilities.translationSlots)
            guard status.activeJobs < combinedSlots else { return nil }
            return (worker, status)
        }
    }

    /// 지금 연결이 확인된 서버가 하나라도 있는지. 추출 전에 원격 경로를 택할지 판단할 때 씁니다.
    var hasUsableWorker: Bool { !availableWorkers.isEmpty }

    /// 원격 STT 경로로 보내기로 예약한 건수입니다. 추출이 끝나기 전에도 세어야
    /// 원격 자리를 초과해 몰리지 않고, 남는 항목이 내장 서버로 흘러갑니다.
    private var sttReservations = 0

    /// 원격 경로 자리를 예약합니다. 실패하면 호출자는 내장 서버로 처리해야 합니다.
    /// 추출이 진행되는 동안 서버가 굶지 않도록 요청 배수만큼 대기열을 유지합니다.
    func reserveRemoteSTT(queueMultiplier: Int = 1) -> Bool {
        let slots = totalSTTSlots
        guard slots > 0 else { return false }
        let reservationLimit = slots * min(4, max(1, queueMultiplier))
        guard sttReservations < reservationLimit else { return false }
        sttReservations += 1
        return true
    }

    func releaseRemoteSTTReservation() {
        sttReservations = max(0, sttReservations - 1)
    }

    var remoteSTTReservationCount: Int { sttReservations }

    var totalSTTSlots: Int { availableWorkers.reduce(0) { $0 + $1.1.capabilities.sttSlots } }
    var totalTranslationSlots: Int { availableWorkers.reduce(0) { $0 + $1.1.capabilities.translationSlots } }

    /// 임대 용도입니다. STT와 번역은 서버에서 쓰는 자원과 동시 처리 수가 다르므로 따로 셉니다.
    enum Purpose: Hashable {
        case stt, translation

        func slots(in capabilities: RemoteWorkerCapabilities) -> Int {
            switch self {
            case .stt: capabilities.sttSlots
            case .translation: capabilities.translationSlots
            }
        }
    }

    /// 여러 서버에 고르게 분산합니다. 용도별 빈 자리가 있는 서버 중 가장 한가한 곳을 고릅니다.
    /// 예전에는 STT·번역 중 작은 쪽으로 용량을 잡아 서버의 절반만 쓰기도 했습니다.
    func acquire(for purpose: Purpose, excluding excluded: Set<UUID> = []) -> RemoteWorkerConfiguration? {
        let candidates = availableWorkers.filter { worker, status in
            guard !excluded.contains(worker.id) else { return false }
            guard cooldownUntil[worker.id, default: .distantPast] <= .now else { return false }
            let limit = max(1, purpose.slots(in: status.capabilities))
            return activeLeases[Lease(worker: worker.id, purpose: purpose), default: 0] < limit
        }
        // 단순 임대 건수로 비교하면 4슬롯 서버와 1슬롯 서버가 같은 비율로 선택되어
        // 느린 서버에 대기열이 몰립니다. 용도별 사용률을 비교해 서버가 알린 처리 용량에
        // 비례하도록 분산하고, 동률일 때만 전체 임대 수를 보조 기준으로 사용합니다.
        guard let selected = candidates.min(by: { lhs, rhs in
            let lhsSlots = max(1, purpose.slots(in: lhs.1.capabilities))
            let rhsSlots = max(1, purpose.slots(in: rhs.1.capabilities))
            let lhsLeases = activeLeases[Lease(worker: lhs.0.id, purpose: purpose), default: 0]
            let rhsLeases = activeLeases[Lease(worker: rhs.0.id, purpose: purpose), default: 0]
            let lhsUtilization = Double(lhsLeases) / Double(lhsSlots)
            let rhsUtilization = Double(rhsLeases) / Double(rhsSlots)
            if lhsUtilization != rhsUtilization { return lhsUtilization < rhsUtilization }
            if lhsLeases != rhsLeases { return lhsLeases < rhsLeases }
            return totalLeases(for: lhs.0.id) < totalLeases(for: rhs.0.id)
        })?.0 else {
            return nil
        }
        activeLeases[Lease(worker: selected.id, purpose: purpose), default: 0] += 1
        return workerUsingDefaultTokenIfNeeded(selected)
    }

    /// 서버가 잠시 가득 찼을 때 바로 내장 서버로 돌아가지 않고 빈 슬롯을 기다립니다.
    /// 연결 가능한 후보가 사라졌거나 모든 서버가 이미 실패 후보로 제외되면 즉시 반환합니다.
    func acquireWaiting(
        for purpose: Purpose,
        excluding excluded: Set<UUID> = [],
        timeout: Duration = .seconds(20)
    ) async -> RemoteWorkerConfiguration? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !Task.isCancelled {
            if let worker = acquire(for: purpose, excluding: excluded) { return worker }
            let hasEligibleWorker = availableWorkers.contains { worker, status in
                !excluded.contains(worker.id)
                    && cooldownUntil[worker.id, default: .distantPast] <= .now
                    && purpose.slots(in: status.capabilities) > 0
            }
            guard hasEligibleWorker, clock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    func release(_ id: UUID, purpose: Purpose) {
        let key = Lease(worker: id, purpose: purpose)
        activeLeases[key] = max(0, activeLeases[key, default: 0] - 1)
    }

    /// 제한 시간을 넘긴 서버를 잠시 배정 대상에서 제외해 같은 장애 서버로 즉시 재시도하지 않습니다.
    func quarantine(_ id: UUID, for duration: TimeInterval = 600) {
        cooldownUntil[id] = Date.now.addingTimeInterval(duration)
        recoveringWorkerIDs.insert(id)
        recoveryTasks[id]?.cancel()
        recoveryTasks[id] = Task { [weak self] in
            // 서버가 방금 취소된 작업을 정리할 시간을 준 뒤 30초마다 상태를 확인합니다.
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                guard let self,
                      let worker = self.workers.first(where: { $0.id == id }),
                      worker.isEnabled else { break }
                await self.refresh(id)
                if case let .available(status) = self.states[id] {
                    let combinedSlots = max(1, status.capabilities.sttSlots + status.capabilities.translationSlots)
                    if status.activeJobs < combinedSlots {
                        self.cooldownUntil[id] = nil
                        self.recoveringWorkerIDs.remove(id)
                        self.recoveryTasks[id] = nil
                        return
                    }
                }
                // 접속 불가 또는 서버 대기열 포화면 자동 감시를 계속합니다.
                self.cooldownUntil[id] = Date.now.addingTimeInterval(60)
                try? await Task.sleep(for: .seconds(30))
            }
            self?.recoveringWorkerIDs.remove(id)
            self?.recoveryTasks[id] = nil
        }
    }

    func cooldownRemaining(for id: UUID) -> TimeInterval {
        max(0, cooldownUntil[id, default: .distantPast].timeIntervalSinceNow)
    }

    func isRecovering(_ id: UUID) -> Bool { recoveringWorkerIDs.contains(id) }

    /// 화면에 서버별 현재 부하를 보여 주기 위한 값입니다.
    func activeLeaseCount(for id: UUID) -> Int { totalLeases(for: id) }

    private func totalLeases(for id: UUID) -> Int {
        activeLeases[Lease(worker: id, purpose: .stt), default: 0]
            + activeLeases[Lease(worker: id, purpose: .translation), default: 0]
    }

    struct Lease: Hashable {
        let worker: UUID
        let purpose: Purpose
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

    func add(name: String, address: String, token: String, usesAuthentication: Bool = true) throws {
        let configuration = try configuration(name: name, address: address, token: token, usesAuthentication: usesAuthentication)
        workers.append(configuration)
        persist()
    }

    /// 별도 VideoLingo Worker 설치 없이 실행 중인 STTLMMServer를 확인한 뒤 저장합니다.
    @discardableResult
    func connectAndAdd(name: String, address: String, token: String, usesAuthentication: Bool = true) async throws -> RemoteWorkerStatus {
        let worker = try configuration(name: name, address: address, token: token, usesAuthentication: usesAuthentication)
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
        recoveryTasks[id]?.cancel()
        recoveryTasks[id] = nil
        recoveringWorkerIDs.remove(id)
        cooldownUntil[id] = nil
        workers.removeAll { $0.id == id }
        states[id] = nil
        persist()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = workers.firstIndex(where: { $0.id == id }) else { return }
        workers[index].isEnabled = enabled
        if !enabled {
            recoveryTasks[id]?.cancel()
            recoveryTasks[id] = nil
            recoveringWorkerIDs.remove(id)
            cooldownUntil[id] = nil
            states[id] = .unchecked
        }
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

    private func configuration(name: String, address: String, token: String, usesAuthentication: Bool) throws -> RemoteWorkerConfiguration {
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
            authenticationToken: usesAuthentication ? token.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            usesAuthentication: usesAuthentication
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
        if worker.usesAuthentication && !worker.authenticationToken.isEmpty {
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
        guard worker.usesAuthentication, worker.authenticationToken.isEmpty,
              let token = credentialStore.load(), !token.isEmpty else { return worker }
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
