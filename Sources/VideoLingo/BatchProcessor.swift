import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VideoLingoCore

/// 여러 영상을 큐에 넣고 설정된 동시 처리 수만큼 STT·LLM 번역을 병렬 실행합니다.
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
        var sttProgress: Double = 0
        var translationProgress: Double = 0
        var currentChunk: Int = 0
        var totalChunks: Int = 0
        var liveTranscriptText: String?
        var liveTranslationText: String?
        var lastTranscriptText: String?
        var lastTranslationText: String?
        var message: String = ""
        var isProcessing = false

        var isFinished: Bool { [.completed, .failed, .cancelled].contains(status) }
    }

    var items: [Item] = []
    var isRunning = false
    var isScanningFolders = false
    var folderScanMessage = ""
    var maximumConcurrentJobs: Int = {
        let stored = UserDefaults.standard.integer(forKey: "batchMaximumConcurrentJobs")
        return stored == 0 ? 5 : min(10, max(1, stored))
    }() {
        didSet {
            UserDefaults.standard.set(
                min(10, max(1, maximumConcurrentJobs)),
                forKey: "batchMaximumConcurrentJobs"
            )
        }
    }

    private var options = ProcessingOptions()
    private var connection: NSXPCConnection?
    private var runTask: Task<Void, Never>?
    private var folderScanTask: Task<Void, Never>?
    private var activeJobIDs: Set<UUID> = []

    private init() {}

    var pendingCount: Int { items.filter { !$0.isFinished && !$0.isProcessing }.count }
    var runningCount: Int { items.filter(\.isProcessing).count }
    var completedCount: Int { items.filter { $0.status == .completed }.count }
    var overallProgress: Double {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0) { $0 + ($1.isFinished ? 1 : $1.progress) } / Double(items.count)
    }
    var optionsSummary: String {
        let languages = options.targetLanguages.map { $0.uppercased() }.joined(separator: ", ")
        return "\(options.sttModel) · \(options.translationModel) · \(languages)"
    }

    func configure(options: ProcessingOptions) {
        guard !isRunning else { return }
        self.options = options
    }

    // MARK: 큐 편집

    func addFiles() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "일괄 처리할 MP4 영상을 선택하세요")
        panel.allowedContentTypes = [.mpeg4Movie, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "하위 영상을 검색할 폴더를 선택하세요")
        panel.prompt = String(localized: "폴더 검색")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        scanFolders(panel.urls)
    }

    @discardableResult
    func addDroppedURLs(_ urls: [URL]) -> Bool {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let files = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        let addedFiles = add(files)
        if !folders.isEmpty { scanFolders(folders) }
        return addedFiles > 0 || !folders.isEmpty
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var addedCount = 0
        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            guard isSupportedVideo(url), !items.contains(where: { $0.url.standardizedFileURL == url }) else { continue }
            items.append(Item(url: url))
            addedCount += 1
        }
        return addedCount
    }

    private func isSupportedVideo(_ url: URL) -> Bool {
        Self.isSupportedVideoURL(url)
    }

    func cancelFolderScan() {
        folderScanTask?.cancel()
    }

    private func scanFolders(_ roots: [URL]) {
        guard !isScanningFolders, !roots.isEmpty else { return }
        isScanningFolders = true
        folderScanMessage = roots.count == 1
            ? String(localized: "\(roots[0].lastPathComponent) 하위 영상 검색 중…")
            : String(localized: "선택한 \(roots.count)개 폴더의 하위 영상 검색 중…")

        folderScanTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try Self.discoverVideos(in: roots)
            }
            do {
                let discovered = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self else { return }
                let added = self.add(discovered)
                self.folderScanMessage = String(localized: "영상 \(discovered.count)개 발견 · 새로 \(added)개 추가")
            } catch is CancellationError {
                self?.folderScanMessage = String(localized: "폴더 검색을 취소했습니다.")
            } catch {
                self?.folderScanMessage = String(localized: "폴더를 검색하지 못했습니다: \(error.localizedDescription)")
            }
            self?.isScanningFolders = false
            self?.folderScanTask = nil
        }
    }

    nonisolated private static func discoverVideos(in roots: [URL]) throws -> [URL] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey]
        var discovered: [URL] = []

        for root in roots {
            try Task.checkCancellation()
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isSymbolicLink == true {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true, isSupportedVideoURL(url, contentType: values.contentType) else { continue }
                discovered.append(url.standardizedFileURL)
            }
        }

        return Array(Set(discovered)).sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    nonisolated private static func isSupportedVideoURL(_ url: URL, contentType: UTType? = nil) -> Bool {
        if let type = contentType ?? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) {
            return type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true
    }

    func remove(at offsets: IndexSet) {
        guard !isRunning else { return }   // 실행 중에는 인덱스 무효화 방지를 위해 편집 금지
        items.remove(atOffsets: offsets)
    }

    func clearFinished() {
        guard !isRunning else { return }
        items.removeAll { $0.isFinished }
    }

    func retry(_ id: UUID) {
        guard !isRunning, let index = items.firstIndex(where: { $0.id == id }), items[index].isFinished else { return }
        items[index].status = .queued
        items[index].progress = 0
        items[index].sttProgress = 0
        items[index].translationProgress = 0
        items[index].currentChunk = 0
        items[index].totalChunks = 0
        items[index].liveTranscriptText = nil
        items[index].liveTranslationText = nil
        items[index].lastTranscriptText = nil
        items[index].lastTranslationText = nil
        items[index].message = ""
        items[index].jobID = nil
    }

    // MARK: 실행

    func start() {
        guard !isRunning, items.contains(where: { !$0.isFinished }) else { return }
        isRunning = true
        runTask = Task { [weak self] in await self?.runQueue() }
    }

    func cancelAll() {
        runTask?.cancel()
        let ids = activeJobIDs
        for id in ids { service()?.cancelJob(id.uuidString) { _ in } }
    }

    private func runQueue() async {
        let concurrency = maximumConcurrentJobs
        await withTaskGroup(of: Void.self) { group in
            var activeTasks = 0
            while !Task.isCancelled {
                while activeTasks < concurrency,
                      let index = items.firstIndex(where: { !$0.isFinished && !$0.isProcessing }) {
                    items[index].isProcessing = true
                    activeTasks += 1
                    group.addTask { [weak self] in await self?.process(index) }
                }
                guard activeTasks > 0 else { break }
                await group.next()
                activeTasks -= 1
            }
            group.cancelAll()
        }
        for index in items.indices where items[index].isProcessing {
            items[index].isProcessing = false
            if !items[index].isFinished { items[index].status = .cancelled }
        }
        activeJobIDs.removeAll()
        isRunning = false
        runTask = nil
    }

    private func process(_ index: Int) async {
        defer { items[index].isProcessing = false }
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
            activeJobIDs.insert(jobID)
            defer { activeJobIDs.remove(jobID) }
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
                items[index].sttProgress = snapshot.sttProgress
                items[index].translationProgress = snapshot.translationProgress
                items[index].currentChunk = snapshot.currentChunk
                items[index].totalChunks = snapshot.totalChunks
                items[index].liveTranscriptText = snapshot.liveTranscriptText
                items[index].liveTranslationText = snapshot.liveTranslationText
                items[index].lastTranscriptText = snapshot.lastTranscriptText
                items[index].lastTranslationText = snapshot.lastTranslationText
                items[index].status = snapshot.status
                items[index].message = snapshot.message
                if snapshot.status == .refining {
                    // 품질 개선 단계는 결과가 이미 나온 상태이므로 배치에서는 완료로 간주하고 다음 파일로 넘어갑니다.
                    items[index].status = .completed
                    items[index].progress = 1
                    items[index].message = String(localized: "STT·번역 완료 · 품질 개선은 백그라운드에서 계속됩니다.")
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

struct BatchTranslationView: View {
    @Environment(BatchProcessor.self) private var processor
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var processor = processor
        VStack(spacing: 0) {
            if processor.items.isEmpty {
                ContentUnavailableView {
                    Label("대량 번역할 영상을 추가하세요", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("Finder에서 영상을 끌어 놓거나 직접 선택하면 현재 STT·LLM 설정으로 동시에 처리합니다.")
                } actions: {
                    HStack {
                        Button("영상 추가…", systemImage: "plus") { processor.addFiles() }
                            .buttonStyle(.borderedProminent)
                        Button("폴더 추가…", systemImage: "folder.badge.plus") { processor.addFolders() }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                }
            } else {
                List {
                    ForEach(processor.items) { item in
                        BatchTranslationRow(item: item) {
                            processor.retry(item.id)
                        }
                    }
                    .onDelete(perform: processor.remove)
                }
            }

            Divider()
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("처리 설정")
                            .font(.headline)
                        Text(processor.optionsSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Stepper(value: $processor.maximumConcurrentJobs, in: 1...10) {
                        Text("동시 처리 \(processor.maximumConcurrentJobs)개")
                            .monospacedDigit()
                    }
                    .disabled(processor.isRunning)
                    .help("로컬 메모리와 GPU 사용량에 맞춰 1~10개 사이에서 설정합니다")
                }

                if processor.isRunning || processor.completedCount > 0 {
                    HStack(spacing: 12) {
                        ProgressView(value: processor.overallProgress)
                        Text("실행 \(processor.runningCount) · 대기 \(processor.pendingCount) · 완료 \(processor.completedCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if processor.isScanningFolders || !processor.folderScanMessage.isEmpty {
                    HStack(spacing: 8) {
                        if processor.isScanningFolders { ProgressView().controlSize(.small) }
                        Text(processor.folderScanMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if processor.isScanningFolders {
                            Button("검색 취소", role: .cancel) { processor.cancelFolderScan() }
                                .controlSize(.small)
                        }
                    }
                }

                HStack {
                    Button("완료 항목 지우기", systemImage: "clear") { processor.clearFinished() }
                        .disabled(processor.isRunning || processor.completedCount == 0)
                    Spacer()
                    if processor.isRunning {
                        Button("전체 취소", systemImage: "stop.fill", role: .destructive) {
                            processor.cancelAll()
                        }
                    } else {
                        Button("대량 번역 시작", systemImage: "play.fill") { processor.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!processor.items.contains(where: { !$0.isFinished }))
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(16)
            .background(.bar)
        }
        .navigationTitle("대량 번역")
        .dropDestination(for: URL.self) { urls, _ in
            processor.addDroppedURLs(urls)
        } isTargeted: { targeted in
            withAnimation(.snappy) { isDropTargeted = targeted }
        }
        .overlay {
            if isDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.thinMaterial)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.largeTitle)
                            .foregroundStyle(Color.accentColor)
                        Text("여기에 영상을 놓아 추가")
                            .font(.headline)
                        Text("폴더를 놓으면 하위 영상까지 검색합니다. 중복과 영상이 아닌 파일은 제외됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("폴더 추가…", systemImage: "folder.badge.plus") { processor.addFolders() }
                    .disabled(processor.isScanningFolders)
                    .help("폴더와 하위 폴더에서 영상 검색")
                Button("영상 추가…", systemImage: "plus") { processor.addFiles() }
                    .help("여러 영상 추가")
            }
        }
    }
}

private struct BatchTranslationRow: View {
    let item: BatchProcessor.Item
    let onRetry: () -> Void
    @State private var showLiveDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .frame(width: 20)
                    .accessibilityLabel(statusText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.url.lastPathComponent)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(item.message.isEmpty ? statusText : item.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if item.totalChunks > 0 {
                    Text("청크 \(min(item.currentChunk + 1, item.totalChunks))/\(item.totalChunks)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(item.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.callout.monospacedDigit().weight(.medium))
                if hasLiveDetails {
                    Button(showLiveDetails ? "실시간 내용 감추기" : "실시간 내용 보기", systemImage: "waveform") {
                        withAnimation(.snappy) { showLiveDetails.toggle() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(showLiveDetails ? "실시간 내용 감추기" : "실시간 STT·번역 내용 보기")
                }
                if item.isFinished && item.status != .completed {
                    Button("다시 시도", systemImage: "arrow.clockwise", action: onRetry)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("이 영상 다시 시도")
                }
            }

            BatchPipelineView(item: item)

            if showLiveDetails, hasLiveDetails {
                BatchLiveTextView(
                    transcript: item.liveTranscriptText ?? item.lastTranscriptText,
                    translation: item.liveTranslationText ?? item.lastTranslationText
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
        .animation(.smooth, value: item.status)
    }

    private var hasLiveDetails: Bool {
        [item.liveTranscriptText, item.liveTranslationText, item.lastTranscriptText, item.lastTranslationText]
            .contains { text in text?.isEmpty == false }
    }

    private var statusText: String {
        switch item.status {
        case .queued: "대기 중"
        case .completed: "완료"
        case .failed: "실패"
        case .cancelled: "취소됨"
        default: "처리 중"
        }
    }

    private var statusSymbol: String {
        switch item.status {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        case .queued where !item.isProcessing: "clock"
        default: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        case .queued where !item.isProcessing: .secondary
        default: .blue
        }
    }
}

private struct BatchPipelineView: View {
    let item: BatchProcessor.Item

    var body: some View {
        HStack(spacing: 10) {
            stage(
                title: "STT",
                icon: "waveform",
                progress: item.sttProgress,
                isActive: [.extracting, .transcribing].contains(item.status)
            )
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(item.sttProgress >= 1 ? Color.green : Color.secondary.opacity(0.45))
            stage(
                title: "LLM 번역",
                icon: "character.book.closed",
                progress: item.translationProgress,
                isActive: [.translating, .refining].contains(item.status)
            )
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(item.translationProgress >= 1 ? Color.green : Color.secondary.opacity(0.45))
            Label(item.status == .completed ? "완료" : "결과", systemImage: item.status == .completed ? "checkmark.circle.fill" : "circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(item.status == .completed ? Color.green : Color.secondary)
                .frame(minWidth: 58)
        }
    }

    private func stage(title: String, icon: String, progress: Double, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: isActive ? "dot.radiowaves.left.and.right" : icon)
                    .foregroundStyle(isActive ? Color.accentColor : progress >= 1 ? Color.green : Color.secondary)
                Text(title)
                    .font(.caption.weight(.medium))
                Spacer(minLength: 4)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, max(0, progress)))
                .tint(progress >= 1 ? .green : .accentColor)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.35) : Color.clear)
        }
    }
}

private struct BatchLiveTextView: View {
    let transcript: String?
    let translation: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            liveColumn(title: "실시간 STT", icon: "waveform", text: transcript)
            liveColumn(title: "실시간 LLM 번역", icon: "character.book.closed", text: translation)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func liveColumn(title: String, icon: String, text: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(text?.isEmpty == false ? text! : "결과를 기다리는 중…")
                .font(.caption)
                .foregroundStyle(text?.isEmpty == false ? .primary : .tertiary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
