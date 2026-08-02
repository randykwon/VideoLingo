import Foundation
import Darwin
import Hub
import MLXLMCommon
import TTSKit
import VideoLingoCore
import WhisperKit

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let service = VideoLingoAIService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: VideoLingoAIServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

final class VideoLingoAIService: NSObject, VideoLingoAIServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var snapshots: [UUID: JobSnapshot] = [:]
    private var modelDownloadTasks: [String: Task<Void, Never>] = [:]
    private var modelRecords: [String: ManagedModelRecord] = [:]
    private let startedAt = Date.now

    func ping(withReply reply: @escaping @Sendable (String) -> Void) {
        reply("VideoLingo AI Service ready")
    }

    func serviceStatus(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        let status = AIServiceStatus(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            startedAt: startedAt,
            activeJobCount: lock.withLock { tasks.count },
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        )
        do { reply(try WireCodec.encode(status), nil) }
        catch { reply(nil, error.localizedDescription) }
    }

    func restart(withReply reply: @escaping @Sendable (Bool) -> Void) {
        let activeTasks = lock.withLock { Array(tasks.values) }
        activeTasks.forEach { $0.cancel() }
        reply(true)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
            exit(EXIT_SUCCESS)
        }
    }

    func modelManagerSnapshot(at modelsPath: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        do {
            let modelsURL = URL(filePath: modelsPath, directoryHint: .isDirectory)
            try loadModelManifests(from: modelsURL)
            let records = lock.withLock { modelRecords.values.sorted { $0.id < $1.id } }
            reply(try WireCodec.encode(ModelManagerSnapshot(models: records)), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func startModelDownload(_ payload: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        do {
            let request = try WireCodec.decode(ModelManagementRequest.self, from: payload)
            guard lock.withLock({ tasks.isEmpty }) else {
                reply(nil, "실행 중인 STT·번역 작업이 있어 모델 다운로드를 시작할 수 없습니다.")
                return
            }
            let key = modelKey(kind: request.kind, modelID: request.modelID)
            let initial = ManagedModelRecord(kind: request.kind, modelID: request.modelID, state: .downloading)
            let started = lock.withLock { () -> Bool in
                guard modelDownloadTasks[key] == nil else { return false }
                modelRecords[key] = initial
                modelDownloadTasks[key] = Task(priority: .utility) { [weak self] in
                    await self?.downloadModel(request, key: key)
                }
                return true
            }
            let record = lock.withLock { modelRecords[key] ?? initial }
            reply(try WireCodec.encode(record), started ? nil : "이미 다운로드 중입니다.")
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func deleteManagedModel(_ payload: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        do {
            let request = try WireCodec.decode(ModelManagementRequest.self, from: payload)
            let key = modelKey(kind: request.kind, modelID: request.modelID)
            guard lock.withLock({ tasks.isEmpty }) else {
                reply(nil, "실행 중인 STT·번역 작업이 있어 모델을 삭제할 수 없습니다.")
                return
            }
            lock.withLock { modelDownloadTasks[key]?.cancel() }
            try loadModelManifests(from: request.modelsURL)
            if let localURL = lock.withLock({ modelRecords[key]?.localURL }) {
                let root = request.modelsURL.standardizedFileURL.path
                let target = localURL.standardizedFileURL.path
                guard target.hasPrefix(root + "/") else {
                    reply(nil, "관리 폴더 밖의 모델은 삭제할 수 없습니다.")
                    return
                }
                try? FileManager.default.removeItem(at: localURL)
            }
            try? FileManager.default.removeItem(at: manifestURL(for: request, key: key))
            let deleted = ManagedModelRecord(kind: request.kind, modelID: request.modelID)
            lock.withLock {
                modelRecords[key] = deleted
                modelDownloadTasks[key] = nil
            }
            reply(try WireCodec.encode(deleted), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func startJob(_ payload: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        do {
            let request = try WireCodec.decode(StartJobRequest.self, from: payload)
            if let active = activeSnapshot(for: request.jobID) {
                reply(try WireCodec.encode(active), nil)
                return
            }
            let initial = (try? JobStore(url: request.databaseURL).snapshot(jobID: request.jobID))
                ?? JobSnapshot(id: request.jobID)
            setSnapshot(initial)

            let started = installTaskIfAbsent(for: request.jobID) { [weak self] in
                guard let self else { return }
                let pipeline = MediaPipeline(
                    onSnapshot: { [weak self] snapshot in self?.setSnapshot(snapshot) },
                    onLiveTranscript: { [weak self] jobID, index, total, text in
                        self?.setLiveTranscript(jobID: jobID, index: index, total: total, text: text)
                    },
                    onLiveTranslation: { [weak self] jobID, index, total, language, text in
                        self?.setLiveTranslation(jobID: jobID, index: index, total: total, language: language, text: text)
                    }
                )
                await pipeline.run(request)
                self.removeTask(request.jobID)
            }
            if !started, let active = activeSnapshot(for: request.jobID) {
                reply(try WireCodec.encode(active), nil)
                return
            }
            reply(try WireCodec.encode(initial), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func snapshot(for jobID: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard let id = UUID(uuidString: jobID) else {
            reply(nil, VideoLingoError.invalidPayload.localizedDescription)
            return
        }
        lock.withLock {
            guard let snapshot = snapshots[id] else {
                reply(nil, "작업 상태가 없습니다.")
                return
            }
            do { reply(try WireCodec.encode(snapshot), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func cancelJob(_ jobID: String, withReply reply: @escaping @Sendable (Bool) -> Void) {
        guard let id = UUID(uuidString: jobID) else { reply(false); return }
        let task = lock.withLock { tasks[id] }
        task?.cancel()
        reply(task != nil)
    }

    private func installTaskIfAbsent(for id: UUID, operation: @escaping @Sendable () async -> Void) -> Bool {
        lock.withLock {
            guard tasks[id] == nil else { return false }
            tasks[id] = Task(priority: .utility) { await operation() }
            return true
        }
    }

    private func removeTask(_ id: UUID) {
        lock.withLock { tasks[id] = nil }
    }

    private func setSnapshot(_ snapshot: JobSnapshot) {
        lock.withLock { snapshots[snapshot.id] = snapshot }
    }

    private func setLiveTranscript(jobID: UUID, index: Int, total: Int, text: String) {
        lock.withLock {
            guard tasks[jobID] != nil, var snapshot = snapshots[jobID] else { return }
            snapshot.status = .transcribing
            snapshot.currentChunk = index
            snapshot.totalChunks = total
            snapshot.liveTranscriptText = text
            snapshot.message = "STT \(index + 1)/\(total) 실시간 추출 중"
            snapshot.updatedAt = .now
            snapshots[jobID] = snapshot
        }
    }

    private func setLiveTranslation(jobID: UUID, index: Int, total: Int, language: String, text: String) {
        lock.withLock {
            guard tasks[jobID] != nil, var snapshot = snapshots[jobID] else { return }
            snapshot.status = .translating
            snapshot.currentChunk = index
            snapshot.totalChunks = total
            snapshot.liveTranslationText = text
            snapshot.message = "\(language.uppercased()) 번역 \(index + 1)/\(total) 실시간 생성 중"
            snapshot.updatedAt = .now
            snapshots[jobID] = snapshot
        }
    }

    private func activeSnapshot(for id: UUID) -> JobSnapshot? {
        lock.withLock {
            guard tasks[id] != nil else { return nil }
            return snapshots[id] ?? JobSnapshot(id: id, status: .queued, message: "이미 실행 중인 작업입니다.")
        }
    }

    private func downloadModel(_ request: ModelManagementRequest, key: String) async {
        do {
            try FileManager.default.createDirectory(at: request.modelsURL, withIntermediateDirectories: true)
            let localURL: URL
            switch request.kind {
            case .stt:
                localURL = try await WhisperKit.download(
                    variant: request.modelID,
                    downloadBase: request.modelsURL,
                    progressCallback: { [weak self] progress in
                        self?.updateModelProgress(key: key, progress: progress.fractionCompleted)
                    }
                )
            case .tts:
                localURL = try await TTSKit.download(
                    variant: .qwen3TTS_0_6b,
                    downloadBase: request.modelsURL,
                    progressCallback: { [weak self] progress in
                        self?.updateModelProgress(key: key, progress: progress.fractionCompleted)
                    }
                )
            case .translation:
                let hub = HubApi(downloadBase: request.modelsURL)
                localURL = try await MLXLMCommon.downloadModel(
                    hub: hub,
                    configuration: ModelConfiguration(id: request.modelID),
                    progressHandler: { [weak self] progress in
                        self?.updateModelProgress(key: key, progress: progress.fractionCompleted)
                    }
                )
            }
            let record = ManagedModelRecord(
                kind: request.kind,
                modelID: request.modelID,
                state: .downloaded,
                progress: 1,
                localURL: localURL,
                sizeInBytes: folderSize(localURL)
            )
            try saveModelManifest(record, request: request, key: key)
            lock.withLock {
                modelRecords[key] = record
                modelDownloadTasks[key] = nil
            }
        } catch is CancellationError {
            lock.withLock {
                modelRecords[key] = ManagedModelRecord(kind: request.kind, modelID: request.modelID)
                modelDownloadTasks[key] = nil
            }
        } catch {
            let failed = ManagedModelRecord(
                kind: request.kind,
                modelID: request.modelID,
                state: .failed,
                error: error.localizedDescription
            )
            lock.withLock {
                modelRecords[key] = failed
                modelDownloadTasks[key] = nil
            }
        }
    }

    private func updateModelProgress(key: String, progress: Double) {
        lock.withLock {
            guard var record = modelRecords[key] else { return }
            record.state = .downloading
            record.progress = min(1, max(0, progress))
            record.updatedAt = .now
            modelRecords[key] = record
        }
    }

    private func loadModelManifests(from modelsURL: URL) throws {
        let directory = modelsURL.appending(path: "Manifests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var record = try? WireCodec.decode(ManagedModelRecord.self, from: data) else { continue }
            if let localURL = record.localURL, !FileManager.default.fileExists(atPath: localURL.path) {
                record.state = .notDownloaded
                record.progress = 0
                record.localURL = nil
                record.sizeInBytes = 0
            }
            let key = modelKey(kind: record.kind, modelID: record.modelID)
            lock.withLock {
                if modelDownloadTasks[key] == nil { modelRecords[key] = record }
            }
        }
    }

    private func saveModelManifest(_ record: ManagedModelRecord, request: ModelManagementRequest, key: String) throws {
        let url = manifestURL(for: request, key: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WireCodec.encode(record).write(to: url, options: .atomic)
    }

    private func manifestURL(for request: ModelManagementRequest, key: String) -> URL {
        let safeName = key.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        return request.modelsURL.appending(path: "Manifests", directoryHint: .isDirectory).appending(path: "\(safeName).json")
    }

    private func modelKey(kind: ManagedModelKind, modelID: String) -> String {
        "\(kind.rawValue):\(modelID)"
    }

    private func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
