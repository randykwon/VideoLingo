import AppKit
import Foundation
import Observation
import VideoLingoCore

/// 여러 MP4를 큐에 넣어 현재 설정으로 순차 STT·번역 처리하는 배치 매니저.
/// XPC 서비스는 작업을 동시 실행할 수 있지만, 로컬 자원(STT/번역 모델) 부하를 고려해 한 번에 하나씩 처리합니다.
@MainActor
@Observable
final class BatchProcessor {
    static let shared = BatchProcessor()

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var jobID: UUID?
        var status: JobStatus = .queued
        var progress: Double = 0
        var message: String = ""

        var isFinished: Bool { [.completed, .failed, .cancelled].contains(status) }
    }

    var items: [Item] = []
    var isRunning = false

    private var options = ProcessingOptions()
    private var connection: NSXPCConnection?
    private var runTask: Task<Void, Never>?
    private var activeJobID: UUID?

    private init() {}

    // MARK: 큐 편집

    func addFiles() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "일괄 처리할 MP4 영상을 선택하세요")
        panel.allowedContentTypes = [.mpeg4Movie, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.append(Item(url: url))
        }
    }

    func remove(at offsets: IndexSet) {
        guard !isRunning else { return }   // 실행 중에는 인덱스 무효화 방지를 위해 편집 금지
        items.remove(atOffsets: offsets)
    }

    func clearFinished() {
        guard !isRunning else { return }
        items.removeAll { $0.isFinished }
    }

    // MARK: 실행

    func start(options: ProcessingOptions) {
        guard !isRunning, items.contains(where: { !$0.isFinished }) else { return }
        self.options = options
        isRunning = true
        runTask = Task { [weak self] in await self?.runQueue() }
    }

    func cancelAll() {
        runTask?.cancel()
        if let id = activeJobID { service()?.cancelJob(id.uuidString) { _ in } }
        isRunning = false
    }

    private func runQueue() async {
        // 실행 중에는 추가(맨 뒤 append)만 허용하므로 인덱스가 어긋나지 않습니다.
        while !Task.isCancelled, let index = items.firstIndex(where: { !$0.isFinished }) {
            await process(index)
        }
        activeJobID = nil
        isRunning = false
    }

    private func process(_ index: Int) async {
        let url = items[index].url
        guard let service = service() else {
            items[index].status = .failed
            items[index].message = String(localized: "내장 AI 서버에 연결할 수 없습니다.")
            return
        }
        do {
            let paths = try AppPaths()
            let jobID = AppModel.stableJobID(
                forPath: url.path,
                sttModel: options.sttModel,
                sourceLanguage: options.sourceLanguage ?? "",
                chunkDuration: options.chunkDuration
            )
            items[index].jobID = jobID
            activeJobID = jobID
            let workspace = paths.workspace(for: jobID)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let request = StartJobRequest(
                jobID: jobID,
                mediaURL: url,
                securityScopedBookmark: bookmark,
                options: options,
                databaseURL: paths.database,
                workspaceURL: workspace
            )
            try JobStore(url: paths.database).createJob(id: jobID, mediaURL: url, options: options)
            items[index].status = .queued
            items[index].message = String(localized: "AI 서비스에 작업 전달 중")

            _ = try await send(service, payload: WireCodec.encode(request))

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let snapshot = await snapshot(service, jobID: jobID) else { continue }
                items[index].progress = snapshot.progress
                items[index].status = snapshot.status
                items[index].message = snapshot.message
                if snapshot.status == .refining {
                    // 품질 개선 단계는 결과가 이미 나온 상태이므로 배치에서는 완료로 간주하고 다음 파일로 넘어갑니다.
                    break
                }
                if [.completed, .failed, .cancelled].contains(snapshot.status) { break }
            }
            if Task.isCancelled, !items[index].isFinished {
                items[index].status = .cancelled
            }
        } catch {
            items[index].status = .failed
            items[index].message = error.localizedDescription
        }
    }

    // MARK: XPC

    private func service() -> VideoLingoAIServiceProtocol? {
        if connection == nil {
            let connection = NSXPCConnection(serviceName: "com.vvv.VideoLingo.AIService")
            connection.remoteObjectInterface = NSXPCInterface(with: VideoLingoAIServiceProtocol.self)
            connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in } as? VideoLingoAIServiceProtocol
    }

    private func send(_ service: VideoLingoAIServiceProtocol, payload: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            service.startJob(payload) { _, error in
                if let error { continuation.resume(throwing: NSError(domain: "VideoLingo", code: 1, userInfo: [NSLocalizedDescriptionKey: error])) }
                else { continuation.resume() }
            }
        }
    }

    private func snapshot(_ service: VideoLingoAIServiceProtocol, jobID: UUID) async -> JobSnapshot? {
        await withCheckedContinuation { (continuation: CheckedContinuation<JobSnapshot?, Never>) in
            service.snapshot(for: jobID.uuidString) { data, _ in
                continuation.resume(returning: data.flatMap { try? WireCodec.decode(JobSnapshot.self, from: $0) })
            }
        }
    }
}
