import Foundation
import Observation
import VideoLingoCore

/// 번역 모드의 미디어 목록에서 선택한 영상들을 플레이어 재생과 독립적으로
/// 백그라운드 XPC 큐에서 순차 STT·번역하는 관리자입니다.
@MainActor
@Observable
final class BackgroundTranslationManager {
    static let shared = BackgroundTranslationManager()

    struct BackgroundJob: Identifiable, Sendable {
        let id: String // standardized file path
        let url: URL
        let jobID: UUID
        var options: ProcessingOptions
        var status: JobStatus = .queued
        var progress: Double = 0
        var sttProgress: Double = 0
        var translationProgress: Double = 0
        var message: String = "백그라운드 대기 중"
        var error: String?
        var updatedAt: Date = .now

        var isActive: Bool {
            [.queued, .extracting, .transcribing, .translating, .synthesizing, .refining].contains(status)
        }
    }

    private(set) var jobs: [String: BackgroundJob] = [:]
    private var queueOrder: [String] = []
    private var activeKey: String?
    @ObservationIgnored private var workerTask: Task<Void, Never>?
    @ObservationIgnored private var connection: NSXPCConnection?

    var orderedJobs: [BackgroundJob] {
        queueOrder.compactMap { jobs[$0] }
    }

    var activeCount: Int {
        jobs.values.filter(\.isActive).count
    }

    var completedCount: Int {
        jobs.values.filter { $0.status == .completed }.count
    }

    var failedCount: Int {
        jobs.values.filter { $0.status == .failed }.count
    }

    var hasJobs: Bool {
        !jobs.isEmpty
    }

    func key(for url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }

    func job(for url: URL) -> BackgroundJob? {
        jobs[key(for: url)]
    }

    func isProcessing(_ url: URL) -> Bool {
        jobs[key(for: url)]?.isActive == true
    }

    /// 특정 영상을 현재 앱의 STT·번역 설정으로 백그라운드 대기열에 등록하고 즉시 실행을 시작합니다.
    @discardableResult
    func enqueue(url: URL, options: ProcessingOptions) -> Bool {
        let standardized = url.standardizedFileURL
        let itemKey = key(for: standardized)
        if let existing = jobs[itemKey], existing.isActive {
            return false
        }
        if AppModel.videoIsBeingProcessed(standardized) {
            return false
        }
        let jobID = AppModel.stableJobID(
            forPath: standardized.path,
            sttModel: options.sttModel,
            sourceLanguage: options.sourceLanguage ?? "",
            chunkDuration: options.chunkDuration
        )
        let job = BackgroundJob(
            id: itemKey,
            url: standardized,
            jobID: jobID,
            options: options,
            status: .queued,
            progress: 0,
            message: "백그라운드 STT·번역 대기 중"
        )
        jobs[itemKey] = job
        if !queueOrder.contains(itemKey) {
            queueOrder.append(itemKey)
        }
        startWorkerIfNeeded()
        return true
    }

    func cancel(url: URL) {
        let itemKey = key(for: url)
        guard var job = jobs[itemKey], job.isActive else { return }
        job.status = .cancelled
        job.message = "백그라운드 작업이 중지되었습니다."
        job.updatedAt = .now
        jobs[itemKey] = job
        if activeKey == itemKey {
            remoteService()?.cancelJob(job.jobID.uuidString) { _ in }
        }
    }

    func cancelAll() {
        for itemKey in queueOrder {
            guard var job = jobs[itemKey], job.isActive else { continue }
            job.status = .cancelled
            job.message = "백그라운드 작업이 중지되었습니다."
            job.updatedAt = .now
            jobs[itemKey] = job
            if activeKey == itemKey {
                remoteService()?.cancelJob(job.jobID.uuidString) { _ in }
            }
        }
    }

    func clearFinished() {
        let finishedKeys = queueOrder.filter { key in
            guard let job = jobs[key] else { return true }
            return !job.isActive
        }
        for key in finishedKeys {
            jobs.removeValue(forKey: key)
        }
        queueOrder.removeAll { jobs[$0] == nil }
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.runQueueLoop()
        }
    }

    private func runQueueLoop() async {
        defer {
            activeKey = nil
            workerTask = nil
        }
        while !Task.isCancelled {
            guard let nextKey = queueOrder.first(where: { jobs[$0]?.status == .queued }) else {
                break
            }
            activeKey = nextKey
            await runSingleJob(key: nextKey)
            activeKey = nil
        }
    }

    private func runSingleJob(key itemKey: String) async {
        guard var job = jobs[itemKey], job.status == .queued else { return }
        do {
            // 자체 whisper-server / llama-server가 선택된 경우 먼저 기동하고 최신 토큰을 반영합니다.
            let runtime = ManagedRuntimeManager.shared
            if job.options.effectiveSTTEngine == .managedWhisper {
                job.message = "자체 whisper.cpp 서버 준비 중…"
                jobs[itemKey] = job
                try await runtime.ensureReady(.stt)
                job.options.managedSTTURL = ManagedRuntimeRole.stt.baseURL.absoluteString
                job.options.managedSTTAPIKey = runtime.authorization(for: .stt)
            }
            if job.options.effectiveTranslationEngine == .managedLlama {
                job.message = "자체 llama.cpp 서버 준비 중…"
                jobs[itemKey] = job
                try await runtime.ensureReady(.translation)
                job.options.managedTranslationURL = ManagedRuntimeRole.translation.baseURL.appendingPathComponent("v1/chat/completions").absoluteString
                job.options.managedTranslationAPIKey = runtime.authorization(for: .translation)
            }

            // 서버 준비 중 사용자가 취소했는지 다시 확인합니다.
            guard jobs[itemKey]?.status != .cancelled else { return }

            let paths = try AppPaths()
            let workspace = paths.workspace(for: job.jobID)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let store = try JobStore(url: paths.database)
            try store.createJob(id: job.jobID, mediaURL: job.url, options: job.options)

            let bookmark = try? job.url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let request = StartJobRequest(
                jobID: job.jobID,
                mediaURL: job.url,
                securityScopedBookmark: bookmark,
                options: job.options,
                databaseURL: paths.database,
                workspaceURL: workspace
            )
            let payload = try WireCodec.encode(request)
            guard let service = remoteService() else {
                throw VideoLingoError.serviceUnavailable
            }

            let initialSnapshot = try await startJobRPC(service: service, payload: payload)
            apply(snapshot: initialSnapshot, for: itemKey)

            var lastSTTProgress = initialSnapshot.sttProgress
            var lastTranslationProgress = initialSnapshot.translationProgress

            while !Task.isCancelled {
                if jobs[itemKey]?.status == .cancelled {
                    service.cancelJob(job.jobID.uuidString) { _ in }
                    break
                }
                try? await Task.sleep(for: .milliseconds(1500))
                guard let currentService = remoteService() else {
                    throw VideoLingoError.serviceUnavailable
                }
                guard let snapshot = try await snapshotRPC(service: currentService, jobID: job.jobID) else {
                    continue
                }
                apply(snapshot: snapshot, for: itemKey)

                let progressAdvanced = snapshot.sttProgress > lastSTTProgress || snapshot.translationProgress > lastTranslationProgress
                if progressAdvanced {
                    lastSTTProgress = snapshot.sttProgress
                    lastTranslationProgress = snapshot.translationProgress
                    MediaLibrary.shared.refreshResultSummary(for: job.url)
                    AppModel.refreshOpenWindows(for: job.url)
                }

                if [.completed, .failed, .cancelled].contains(snapshot.status) {
                    MediaLibrary.shared.refreshResultSummary(for: job.url)
                    AppModel.refreshOpenWindows(for: job.url)
                    break
                }
            }
        } catch is CancellationError {
            if var current = jobs[itemKey] {
                current.status = .cancelled
                current.message = "백그라운드 작업이 취소되었습니다."
                current.updatedAt = .now
                jobs[itemKey] = current
            }
        } catch {
            if var current = jobs[itemKey] {
                current.status = .failed
                current.error = error.localizedDescription
                current.message = "실패 · \(error.localizedDescription)"
                current.updatedAt = .now
                jobs[itemKey] = current
            }
        }
    }

    private func apply(snapshot: JobSnapshot, for itemKey: String) {
        guard var job = jobs[itemKey] else { return }
        // 사용자가 이미 취소한 상태면 일시적 중간 스냅샷으로 덮어쓰지 않습니다.
        if job.status == .cancelled && ![.cancelled, .completed, .failed].contains(snapshot.status) {
            return
        }
        job.status = snapshot.status
        job.progress = snapshot.progress
        job.sttProgress = snapshot.sttProgress
        job.translationProgress = snapshot.translationProgress
        job.message = snapshot.message
        job.error = snapshot.error
        job.updatedAt = .now
        jobs[itemKey] = job
    }

    private func remoteService() -> VideoLingoAIServiceProtocol? {
        if connection == nil {
            let conn = NSXPCConnection(serviceName: "com.vvv.VideoLingo.AIService")
            conn.remoteObjectInterface = NSXPCInterface(with: VideoLingoAIServiceProtocol.self)
            conn.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            conn.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            conn.resume()
            connection = conn
        }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.connection = nil }
        } as? VideoLingoAIServiceProtocol
    }

    private func startJobRPC(service: VideoLingoAIServiceProtocol, payload: Data) async throws -> JobSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            service.startJob(payload) { data, error in
                if let error {
                    continuation.resume(throwing: VideoLingoError.modelUnavailable(error))
                } else if let data {
                    do {
                        continuation.resume(returning: try WireCodec.decode(JobSnapshot.self, from: data))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: VideoLingoError.invalidPayload)
                }
            }
        }
    }

    private func snapshotRPC(service: VideoLingoAIServiceProtocol, jobID: UUID) async throws -> JobSnapshot? {
        try await withCheckedThrowingContinuation { continuation in
            service.snapshot(for: jobID.uuidString) { data, error in
                if let data {
                    continuation.resume(returning: try? WireCodec.decode(JobSnapshot.self, from: data))
                } else if error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
