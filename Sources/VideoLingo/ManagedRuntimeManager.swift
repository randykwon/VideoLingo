import Darwin
import Foundation
import Observation
import VideoLingoCore

struct ManagedRuntimeTransfer: Sendable {
    var progress: Double = 0
    var phase: String = "다운로드 중"
}

enum ManagedRuntimeServerPhase: String, Sendable {
    case stopping = "중지 중"
    case stopped = "중지됨"
    case starting = "모델 로딩 중"
    case ready = "실행 중"
    case failed = "오류"
    case unresponsive = "응답 없음"
}

struct ManagedRuntimeServerStatus: Sendable {
    var phase: ManagedRuntimeServerPhase = .stopped
    var pid: Int32?
    var startedAt: Date?
    var cpu: Double = 0
    var memoryMB: Double = 0
    var requests: Int = 0
    var lastLatencyMS: Int?
    var error: String?
}

/// SpikDoum의 ManagedModelManager와 동일한 방식으로
/// 자체 whisper-server(18882) · llama-server(18883)와 19종 검증 모델 + 로컬 .bin/.gguf 모델을 관리합니다.
@MainActor
@Observable
final class ManagedRuntimeManager {
    static let shared = ManagedRuntimeManager()

    private static let customModelsKey = "VideoLingo.customManagedModelsV1"
    private static let selectedSTTKey = "VideoLingo.managedSTTModel"
    private static let selectedTranslationKey = "VideoLingo.managedTranslationModel"

    private(set) var installed: Set<String> = []
    private(set) var customModels: [CustomManagedRuntimeModel] = []
    private(set) var transfers: [String: ManagedRuntimeTransfer] = [:]
    private(set) var servers: [ManagedRuntimeRole: ManagedRuntimeServerStatus] = [:]
    private(set) var logs: [ManagedRuntimeRole: String] = [:]
    var lastError: String?
    private(set) var selectedSTT: String
    private(set) var selectedTranslation: String

    let store: ManagedRuntimeModelStore
    private let defaults: UserDefaults
    private var downloads: [String: ManagedRuntimeModelDownload] = [:]
    private var processes: [ManagedRuntimeRole: Process] = [:]
    private var generations: [ManagedRuntimeRole: UUID] = [:]
    private var keys: [ManagedRuntimeRole: String] = [:]
    private var startIDs: [ManagedRuntimeRole: UUID] = [:]
    private var starts: [ManagedRuntimeRole: Task<Void, Error>] = [:]
    private var cpuSamples: [ManagedRuntimeRole: (pid: Int32, cpuNS: Double, at: Date)] = [:]
    private var monitor: Task<Void, Never>?

    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let defaultRoot = appSupport.appendingPathComponent("VideoLingo/ManagedModels", isDirectory: true)
        self.store = ManagedRuntimeModelStore(root: root ?? defaultRoot)
        self.selectedSTT = defaults.string(forKey: Self.selectedSTTKey) ?? "whisper-large-v3-turbo-q5"
        self.selectedTranslation = defaults.string(forKey: Self.selectedTranslationKey) ?? "gemma3-4b-q4"
        if let data = defaults.data(forKey: Self.customModelsKey),
           let loaded = try? JSONDecoder().decode([CustomManagedRuntimeModel].self, from: data) {
            self.customModels = loaded
        }
        refreshInstalled()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.poll()
            }
        }
    }

    var allModels: [ManagedRuntimeModel] {
        ManagedRuntimeModelCatalog.all + customModels.map(\.asManagedModel)
    }

    func models(for role: ManagedRuntimeRole) -> [ManagedRuntimeModel] {
        allModels.filter { $0.role == role }
    }

    func selected(_ role: ManagedRuntimeRole) -> ManagedRuntimeModel? {
        let id = role == .stt ? selectedSTT : selectedTranslation
        return allModels.first { $0.id == id }
    }

    func refreshInstalled() {
        installed = Set(allModels.filter { store.installed($0) }.map(\.id))
    }

    func executableURL(for role: ManagedRuntimeRole) -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let candidates: [URL] = [
            (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).appendingPathComponent("ManagedRuntime/\(role.executable)"),
            appSupport.appendingPathComponent("VideoLingo/ManagedRuntime/\(role.executable)"),
            URL(fileURLWithPath: "/Applications/SpikDoum.app/Contents/Resources/ManagedRuntime/\(role.executable)")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func hasRuntimeExecutable(for role: ManagedRuntimeRole) -> Bool {
        executableURL(for: role) != nil
    }

    @discardableResult
    func importCustomModel(from sourceURL: URL, role: ManagedRuntimeRole) throws -> ManagedRuntimeModel {
        let ext = sourceURL.pathExtension.lowercased()
        let required = role.customFileExtension
        guard ext == required else {
            throw VideoLingoError.modelUnavailable("\(role.title) 모델은 .\(required) 파일만 추가할 수 있습니다.")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw VideoLingoError.modelUnavailable("비어 있는 모델 파일은 추가할 수 없습니다.")
        }

        let customFolder = store.root.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: customFolder, withIntermediateDirectories: true)
        let sanitizedBase = sourceURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let uniqueFilename = "\(sanitizedBase.isEmpty ? "model" : sanitizedBase)-\(UUID().uuidString.prefix(6)).\(required)"
        let destination = customFolder.appendingPathComponent(uniqueFilename)
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        let entry = CustomManagedRuntimeModel(
            id: "custom-\(role.rawValue)-\(UUID().uuidString.prefix(8).lowercased())",
            name: sourceURL.deletingPathExtension().lastPathComponent,
            role: role,
            filename: uniqueFilename,
            bytes: size
        )
        customModels.append(entry)
        saveCustomModels()
        refreshInstalled()
        return entry.asManagedModel
    }

    private func saveCustomModels() {
        if let data = try? JSONEncoder().encode(customModels) {
            defaults.set(data, forKey: Self.customModelsKey)
        }
    }

    func select(_ model: ManagedRuntimeModel) async {
        guard installed.contains(model.id) else {
            lastError = "모델을 먼저 다운로드해주세요."
            return
        }
        if selected(model.role)?.id != model.id {
            await stop(model.role)
        }
        if model.role == .stt {
            selectedSTT = model.id
            defaults.set(model.id, forKey: Self.selectedSTTKey)
        } else {
            selectedTranslation = model.id
            defaults.set(model.id, forKey: Self.selectedTranslationKey)
        }
    }

    func download(_ model: ManagedRuntimeModel) async throws {
        guard downloads[model.id] == nil else {
            throw VideoLingoError.modelUnavailable("이미 다운로드 중입니다.")
        }
        if store.installed(model) {
            refreshInstalled()
            return
        }
        lastError = nil
        transfers[model.id] = ManagedRuntimeTransfer()
        let download = ManagedRuntimeModelDownload(model: model, store: store)
        downloads[model.id] = download
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            download.progress = { [weak self] value, verifying in
                Task { @MainActor in
                    guard let self, self.downloads[model.id] != nil else { return }
                    self.transfers[model.id] = ManagedRuntimeTransfer(
                        progress: value,
                        phase: verifying ? "SHA-256 검증 중" : "다운로드 중"
                    )
                }
            }
            download.completion = { [weak self] result in
                Task { @MainActor in
                    self?.downloads[model.id] = nil
                    self?.transfers[model.id] = nil
                    self?.refreshInstalled()
                    if case .failure(let error) = result,
                       !(error is CancellationError),
                       (error as? URLError)?.code != .cancelled {
                        self?.lastError = error.localizedDescription
                    }
                    continuation.resume(with: result)
                }
            }
            download.start()
        }
    }

    func cancelDownload(_ id: String) {
        downloads[id]?.cancel()
    }

    func remove(_ model: ManagedRuntimeModel) async {
        if selected(model.role)?.id == model.id {
            await stop(model.role)
        }
        do {
            try store.remove(model)
            if model.isCustom {
                customModels.removeAll { $0.id == model.id }
                saveCustomModels()
                if model.role == .stt && selectedSTT == model.id {
                    selectedSTT = "whisper-large-v3-turbo-q5"
                    defaults.set(selectedSTT, forKey: Self.selectedSTTKey)
                } else if model.role == .translation && selectedTranslation == model.id {
                    selectedTranslation = "gemma3-4b-q4"
                    defaults.set(selectedTranslation, forKey: Self.selectedTranslationKey)
                }
            }
            refreshInstalled()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func ensureReady(_ role: ManagedRuntimeRole) async throws {
        if let starting = starts[role] {
            return try await starting.value
        }
        if let process = processes[role], process.isRunning {
            guard servers[role]?.phase == .ready else {
                throw VideoLingoError.modelUnavailable("\(role.title) 서버가 아직 준비되지 않았습니다. 모델·서버 관리에서 상태를 확인해주세요.")
            }
            return
        }
        guard servers[role]?.phase != .stopping else {
            throw VideoLingoError.modelUnavailable("서버를 중지 중입니다. 잠시 후 다시 시도해주세요.")
        }
        let id = UUID()
        startIDs[role] = id
        let task = Task { try await self.launch(role) }
        starts[role] = task
        defer {
            if startIDs[role] == id {
                starts[role] = nil
                startIDs[role] = nil
            }
        }
        try await task.value
    }

    func authorization(for role: ManagedRuntimeRole) -> String {
        keys[role] ?? ""
    }

    private func launch(_ role: ManagedRuntimeRole) async throws {
        guard let model = selected(role), store.installed(model) else {
            throw VideoLingoError.modelUnavailable("자체 모델·서버 관리에서 \(role.title) 모델을 먼저 다운로드하고 적용해주세요.")
        }
        guard let executable = executableURL(for: role) else {
            throw VideoLingoError.modelUnavailable("\(role.executable) 실행 파일을 찾지 못했습니다. ./scripts/build_managed_runtimes.sh를 실행해 런타임을 준비하세요.")
        }
        guard Self.portAvailable(role.port) else {
            throw VideoLingoError.modelUnavailable("로컬 포트 \(role.port)가 이미 사용 중입니다.")
        }
        try Task.checkCancellation()
        let generation = UUID()
        generations[role] = generation
        var status = ManagedRuntimeServerStatus()
        status.phase = .starting
        servers[role] = status

        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(role: role, model: store.file(model))
        let key = UUID().uuidString + UUID().uuidString
        keys[role] = key

        var environment = ProcessInfo.processInfo.environment
        let parentPID = String(ProcessInfo.processInfo.processIdentifier)
        environment["VIDEOLINGO_PARENT_PID"] = parentPID
        environment["VIDEOLINGO_API_KEY"] = key
        environment["SPIKDOUM_PARENT_PID"] = parentPID
        environment["SPIKDOUM_API_KEY"] = key
        environment["LLAMA_API_KEY"] = key
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.generations[role] == generation else { return }
                self.logs[role] = String(((self.logs[role] ?? "") + text).suffix(24_000))
            }
        }
        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self, self.generations[role] == generation else { return }
                self.processes[role] = nil
                var updated = self.servers[role] ?? ManagedRuntimeServerStatus()
                updated.phase = .failed
                updated.error = "서버 종료 · 코드 \(terminated.terminationStatus)"
                updated.pid = nil
                self.servers[role] = updated
            }
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        processes[role] = process
        status.pid = process.processIdentifier
        status.startedAt = Date()
        servers[role] = status

        do {
            for _ in 0..<120 {
                try Task.checkCancellation()
                guard generations[role] == generation, process.isRunning else {
                    throw VideoLingoError.modelUnavailable("\(role.title) 서버가 시작 중 종료되었습니다. 로그를 확인해주세요.")
                }
                if await Self.healthy(role) {
                    guard generations[role] == generation, process.isRunning else { throw CancellationError() }
                    servers[role]?.phase = .ready
                    servers[role]?.error = nil
                    return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw VideoLingoError.modelUnavailable("\(role.title) 모델 로딩 시간이 초과되었습니다. 로그를 확인하고 재시작해주세요.")
        } catch {
            if generations[role] == generation {
                await stop(role)
                servers[role]?.phase = .failed
                servers[role]?.error = error.localizedDescription
            }
            throw error
        }
    }

    nonisolated static func arguments(role: ManagedRuntimeRole, model: URL) -> [String] {
        let common = ["-m", model.path, "--host", "127.0.0.1", "--port", String(role.port)]
        return role == .stt
            ? common + ["-l", "auto", "-t", "4"]
            : common + ["-c", "8192", "-ngl", "99", "-t", "4", "--parallel", "1", "--reasoning", "off"]
    }

    func stop(_ role: ManagedRuntimeRole) async {
        if servers[role]?.phase == .stopping { return }
        servers[role]?.phase = .stopping
        starts[role]?.cancel()
        startIDs[role] = nil
        generations[role] = UUID()
        let process = processes.removeValue(forKey: role)
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<30 {
                if !process.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        starts[role] = nil
        cpuSamples[role] = nil
        servers[role] = ManagedRuntimeServerStatus()
    }

    func restart(_ role: ManagedRuntimeRole) async throws {
        await stop(role)
        try await ensureReady(role)
    }

    func shutdown() {
        monitor?.cancel()
        for download in downloads.values { download.cancel() }
        for role in ManagedRuntimeRole.allCases {
            starts[role]?.cancel()
            generations[role] = UUID()
            if let process = processes[role], process.isRunning {
                process.terminate()
            }
        }
        processes = [:]
    }

    private func poll() async {
        for role in ManagedRuntimeRole.allCases {
            guard let process = processes[role], process.isRunning else { continue }
            let pid = process.processIdentifier
            let generation = generations[role]
            let now = Date()
            let metrics = Self.processMetrics(pid)
            let isHealthy = await Self.healthy(role)
            guard generations[role] == generation, processes[role]?.processIdentifier == pid else { continue }
            if let metrics {
                var cpuPercent = servers[role]?.cpu ?? 0
                if let previous = cpuSamples[role], previous.pid == pid {
                    let elapsed = now.timeIntervalSince(previous.at)
                    if elapsed > 0.05 {
                        cpuPercent = max(0, (metrics.cpuNS - previous.cpuNS) / (elapsed * 1_000_000_000) * 100)
                    }
                }
                cpuSamples[role] = (pid, metrics.cpuNS, now)
                servers[role]?.cpu = cpuPercent
                servers[role]?.memoryMB = metrics.memoryMB
            }
            if servers[role]?.phase != .starting {
                servers[role]?.phase = isHealthy ? .ready : .unresponsive
            }
        }
    }

    nonisolated private static func processMetrics(_ pid: Int32) -> (cpuNS: Double, memoryMB: Double)? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let scale = timebase.denom == 0 ? 1.0 : Double(timebase.numer) / Double(timebase.denom)
        let cpuNS = Double(info.pti_total_user &+ info.pti_total_system) * scale
        let memoryMB = Double(info.pti_resident_size) / (1024 * 1024)
        return (cpuNS, memoryMB)
    }

    nonisolated private static func healthy(_ role: ManagedRuntimeRole) async -> Bool {
        var request = URLRequest(url: role.baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    nonisolated private static func portAvailable(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
