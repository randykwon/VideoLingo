import AppKit
import AVKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VideoLingoCore

private struct BatchResultCandidate: Sendable {
    let itemID: UUID
    let jobID: UUID
}

private struct BatchTrashCandidate: Sendable {
    let itemID: UUID
    let url: URL
}

struct BatchTrashResult: Sendable {
    let movedCount: Int
    let failureMessage: String?
}

private enum BatchListFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case completed

    var id: Self { self }
    var title: String {
        switch self {
        case .all: "전체"
        case .active: "진행·대기"
        case .completed: "번역 완료"
        }
    }
}

/// 여러 영상을 큐에 넣고 설정된 동시 처리 수만큼 STT·LLM 번역을 병렬 실행합니다.
@MainActor
@Observable
final class BatchProcessor {
    static let shared = BatchProcessor()

    struct DuplicateFilenameGroup: Identifiable {
        let id: String
        let displayName: String
        let items: [Item]
    }

    enum ExistingResultState: Equatable, Sendable {
        case checking
        case notFound
        case transcriptOnly(count: Int)
        case partial(completedLanguages: [String], missingLanguages: [String], fraction: Double)
        case complete(languages: [String])
        case error(String)

        var isComplete: Bool {
            if case .complete = self { return true }
            return false
        }
    }

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
        var existingResult: ExistingResultState = .checking
        var message: String = ""
        var isProcessing = false

        var isFinished: Bool { [.completed, .failed, .cancelled].contains(status) }
    }

    var items: [Item] = []
    var isRunning = false
    var isScanningFolders = false
    var isCheckingExistingResults = false
    var folderScanMessage = ""
    var resultCheckMessage = ""
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
    private var resultCheckTask: Task<Void, Never>?
    private var activeJobIDsByItem: [UUID: UUID] = [:]
    private var scheduledItemIDs: Set<UUID> = []

    private init() {}

    let availableSourceLanguages = [
        "", "ko", "ja", "en", "zh", "es", "fr", "de", "pt", "it",
        "ru", "ar", "hi", "vi", "th", "id", "tr", "nl", "pl", "sv"
    ]
    let availableTargetLanguages = ["ko", "en", "ja", "zh", "es", "fr", "de", "pt", "it"]

    var pendingCount: Int { items.filter { !$0.isFinished && !$0.isProcessing }.count }
    var runningCount: Int { items.filter(\.isProcessing).count }
    var completedCount: Int { items.filter { $0.status == .completed }.count }
    var alreadyTranslatedCount: Int { items.filter { $0.existingResult.isComplete }.count }
    var duplicateFilenameGroups: [DuplicateFilenameGroup] {
        let grouped = Dictionary(grouping: items) { item in
            item.url.lastPathComponent.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
        }
        return grouped.compactMap { key, groupedItems in
            guard groupedItems.count > 1 else { return nil }
            return DuplicateFilenameGroup(
                id: key,
                displayName: groupedItems[0].url.lastPathComponent,
                items: groupedItems
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    var recommendedDuplicateRemovalIDs: Set<UUID> {
        Set(duplicateFilenameGroups.flatMap { $0.items.dropFirst().map(\.id) })
    }
    var duplicateFilenameRemovalCount: Int { recommendedDuplicateRemovalIDs.count }
    var overallProgress: Double {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0) { $0 + ($1.isFinished ? 1 : $1.progress) } / Double(items.count)
    }
    var optionsSummary: String {
        let languages = options.targetLanguages.map { $0.uppercased() }.joined(separator: ", ")
        let source = options.sourceLanguage.map { $0.uppercased() } ?? String(localized: "자동 감지")
        return "원어 \(source) → \(languages) · \(options.sttModel) · \(options.translationModel)"
    }
    var batchSourceLanguage: String { options.sourceLanguage ?? "" }
    var batchTargetLanguages: [String] { options.targetLanguages }
    var reviewOptions: ProcessingOptions { options }

    func sourceLanguageName(_ code: String) -> String {
        guard !code.isEmpty else { return String(localized: "자동 감지") }
        let localized = Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
        return "\(localized) (\(code.uppercased()))"
    }

    func setBatchSourceLanguage(_ language: String) {
        guard !isRunning, availableSourceLanguages.contains(language) else { return }
        options.sourceLanguage = language.isEmpty ? nil : language
        refreshExistingResults()
    }

    func toggleBatchTargetLanguage(_ language: String) {
        guard !isRunning, availableTargetLanguages.contains(language) else { return }
        if options.targetLanguages.contains(language) {
            guard options.targetLanguages.count > 1 else { return }
            options.targetLanguages.removeAll { $0 == language }
        } else {
            options.targetLanguages.append(language)
            options.targetLanguages.sort {
                (availableTargetLanguages.firstIndex(of: $0) ?? .max)
                    < (availableTargetLanguages.firstIndex(of: $1) ?? .max)
            }
        }
        refreshExistingResults()
    }

    func configure(options: ProcessingOptions) {
        guard !isRunning else { return }
        self.options = options
        refreshExistingResults()
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
        if addedCount > 0 { refreshExistingResults() }
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
                let duplicates = self.duplicateFilenameRemovalCount
                self.folderScanMessage = duplicates > 0
                    ? String(localized: "영상 \(discovered.count)개 발견 · 새로 \(added)개 추가 · 동일 이름 \(duplicates)개 확인 필요")
                    : String(localized: "영상 \(discovered.count)개 발견 · 새로 \(added)개 추가 · 동일 이름 없음")
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

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        stop(ids: ids)
        items.removeAll { ids.contains($0.id) }
    }

    func moveVideosToTrash(ids: Set<UUID>) async -> BatchTrashResult {
        guard !isRunning, !ids.isEmpty else {
            return BatchTrashResult(movedCount: 0, failureMessage: String(localized: "실행 중에는 영상 파일을 이동할 수 없습니다."))
        }
        let candidates = items.compactMap { item in
            ids.contains(item.id) ? BatchTrashCandidate(itemID: item.id, url: item.url.standardizedFileURL) : nil
        }
        guard candidates.count == ids.count else {
            return BatchTrashResult(movedCount: 0, failureMessage: String(localized: "선택 항목 일부를 목록에서 찾을 수 없습니다."))
        }

        let outcome = await Task.detached(priority: .userInitiated) {
            var movedIDs: [UUID] = []
            var failure: String?
            for candidate in candidates {
                do {
                    let values = try candidate.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw NSError(
                            domain: "VideoLingo.BatchTrash",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "일반 영상 파일이 아니거나 심볼릭 링크입니다."]
                        )
                    }
                    let accessed = candidate.url.startAccessingSecurityScopedResource()
                    defer { if accessed { candidate.url.stopAccessingSecurityScopedResource() } }
                    try FileManager.default.trashItem(at: candidate.url, resultingItemURL: nil)
                    movedIDs.append(candidate.itemID)
                } catch {
                    failure = "\(candidate.url.path): \(error.localizedDescription)"
                    break
                }
            }
            return (movedIDs, failure)
        }.value

        let movedSet = Set(outcome.0)
        items.removeAll { movedSet.contains($0.id) }
        return BatchTrashResult(movedCount: movedSet.count, failureMessage: outcome.1)
    }

    func duplicateNameCount(for itemID: UUID) -> Int {
        duplicateFilenameGroups.first(where: { group in group.items.contains { $0.id == itemID } })?.items.count ?? 0
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
        items[index].existingResult = .notFound
        items[index].message = ""
        items[index].jobID = nil
    }

    // MARK: 실행

    func refreshExistingResults() {
        guard !isRunning, !items.isEmpty else { return }
        resultCheckTask?.cancel()

        let currentOptions = options
        var candidates: [BatchResultCandidate] = []
        for index in items.indices where !items[index].isProcessing {
            let jobID = AppModel.stableJobID(
                forPath: items[index].url.path,
                sttModel: currentOptions.sttModel,
                sourceLanguage: currentOptions.sourceLanguage ?? "",
                chunkDuration: currentOptions.chunkDuration
            )
            items[index].jobID = jobID
            items[index].existingResult = .checking
            items[index].status = .queued
            items[index].progress = 0
            items[index].sttProgress = 0
            items[index].translationProgress = 0
            items[index].message = String(localized: "기존 번역 결과 확인 중…")
            candidates.append(BatchResultCandidate(itemID: items[index].id, jobID: jobID))
        }

        isCheckingExistingResults = true
        resultCheckMessage = String(localized: "\(candidates.count)개 영상의 기존 STT·번역 확인 중…")
        let worker = Self.makeExistingResultInspectionTask(
            candidates: candidates,
            options: currentOptions
        )
        resultCheckTask = Task { [weak self] in
            do {
                let results = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self else { return }
                for (itemID, result) in results {
                    guard let index = self.items.firstIndex(where: { $0.id == itemID }), !self.items[index].isProcessing else { continue }
                    self.applyExistingResult(result, at: index)
                }
                self.resultCheckMessage = String(localized: "확인 완료 · 이미 번역된 영상 \(self.alreadyTranslatedCount)개")
            } catch is CancellationError {
                self?.resultCheckMessage = String(localized: "기존 결과 확인을 취소했습니다.")
            } catch {
                self?.resultCheckMessage = String(localized: "기존 결과를 확인하지 못했습니다: \(error.localizedDescription)")
            }
            self?.isCheckingExistingResults = false
            self?.resultCheckTask = nil
        }
    }

    nonisolated private static func makeExistingResultInspectionTask(
        candidates: [BatchResultCandidate],
        options: ProcessingOptions
    ) -> Task<[(UUID, ExistingResultState)], Error> {
        Task.detached(priority: .userInitiated) {
            try inspectExistingResults(candidates: candidates, options: options)
        }
    }

    private func applyExistingResult(_ result: ExistingResultState, at index: Int) {
        items[index].existingResult = result
        switch result {
        case .complete:
            items[index].status = .completed
            items[index].progress = 1
            items[index].sttProgress = 1
            items[index].translationProgress = 1
            items[index].message = String(localized: "이미 STT·번역 완료 · 처리에서 제외")
        case .partial(_, _, let fraction):
            items[index].status = .queued
            items[index].sttProgress = 1
            items[index].translationProgress = fraction
            items[index].progress = 0.5 + fraction * 0.5
            items[index].message = String(localized: "기존 번역 일부 있음 · 누락 결과부터 재개")
        case .transcriptOnly:
            items[index].status = .queued
            items[index].sttProgress = 1
            items[index].message = String(localized: "기존 STT 있음 · 번역부터 재개")
        case .notFound:
            items[index].status = .queued
            items[index].message = String(localized: "새 작업")
        case .error(let message):
            items[index].status = .queued
            items[index].message = String(localized: "확인 실패 · 시작 시 다시 확인: \(message)")
        case .checking:
            break
        }
    }

    nonisolated private static func inspectExistingResults(
        candidates: [BatchResultCandidate],
        options: ProcessingOptions
    ) throws -> [(UUID, ExistingResultState)] {
        let paths = try AppPaths()
        let store = try JobStore(url: paths.database)
        var results: [(UUID, ExistingResultState)] = []

        for candidate in candidates {
            try Task.checkCancellation()
            do {
                let transcripts = try store.transcript(jobID: candidate.jobID)
                guard !transcripts.isEmpty else {
                    results.append((candidate.itemID, .notFound))
                    continue
                }

                let transcriptIDs = Set(transcripts.map(\.id))
                var completedLanguages: [String] = []
                var missingLanguages: [String] = []
                var translatedSegments = 0

                for language in options.targetLanguages {
                    let translations = try store.translations(
                        jobID: candidate.jobID,
                        language: language,
                        modelID: options.translationModel
                    )
                    let completed = transcriptIDs.filter {
                        translations[$0]?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    }.count
                    translatedSegments += completed
                    if completed == transcriptIDs.count {
                        completedLanguages.append(language)
                    } else {
                        missingLanguages.append(language)
                    }
                }

                if options.targetLanguages.isEmpty || translatedSegments == 0 {
                    results.append((candidate.itemID, .transcriptOnly(count: transcripts.count)))
                } else if missingLanguages.isEmpty {
                    results.append((candidate.itemID, .complete(languages: completedLanguages)))
                } else {
                    let denominator = max(1, transcriptIDs.count * options.targetLanguages.count)
                    results.append((candidate.itemID, .partial(
                        completedLanguages: completedLanguages,
                        missingLanguages: missingLanguages,
                        fraction: Double(translatedSegments) / Double(denominator)
                    )))
                }
            } catch {
                results.append((candidate.itemID, .error(error.localizedDescription)))
            }
        }
        return results
    }

    func start() {
        start(ids: Set(items.filter { !$0.isFinished }.map(\.id)))
    }

    func start(ids: Set<UUID>) {
        guard !isCheckingExistingResults, !ids.isEmpty else { return }
        var eligible: Set<UUID> = []
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }), items[index].status != .completed else { continue }
            if [.failed, .cancelled].contains(items[index].status) {
                resetForRetry(at: index)
            }
            guard !items[index].isProcessing else { continue }
            eligible.insert(id)
        }
        guard !eligible.isEmpty else { return }
        scheduledItemIDs.formUnion(eligible)
        guard !isRunning else { return }
        isRunning = true
        runTask = Task { [weak self] in await self?.runQueue() }
    }

    func stop(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        scheduledItemIDs.subtract(ids)
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            if items[index].isProcessing {
                items[index].message = String(localized: "중단 요청 중… 저장된 결과는 유지됩니다.")
                if let jobID = activeJobIDsByItem[id] {
                    service()?.cancelJob(jobID.uuidString) { _ in }
                }
            } else if !items[index].isFinished {
                items[index].status = .cancelled
                items[index].message = String(localized: "사용자가 선택 작업을 중단했습니다. 저장된 결과에서 재개할 수 있습니다.")
            }
        }
    }

    func cancelAll() {
        runTask?.cancel()
        scheduledItemIDs.removeAll()
        let ids = activeJobIDsByItem.values
        for id in ids { service()?.cancelJob(id.uuidString) { _ in } }
    }

    private func resetForRetry(at index: Int) {
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
        items[index].message = String(localized: "저장된 결과부터 다시 시작 대기 중")
    }

    private func runQueue() async {
        let concurrency = maximumConcurrentJobs
        await withTaskGroup(of: Void.self) { group in
            var activeTasks = 0
            while !Task.isCancelled {
                while activeTasks < concurrency,
                      let index = items.firstIndex(where: {
                          scheduledItemIDs.contains($0.id) && !$0.isFinished && !$0.isProcessing
                      }) {
                    let itemID = items[index].id
                    items[index].isProcessing = true
                    activeTasks += 1
                    group.addTask { [weak self] in await self?.process(itemID) }
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
        activeJobIDsByItem.removeAll()
        scheduledItemIDs.removeAll()
        isRunning = false
        runTask = nil
    }

    private func process(_ itemID: UUID) async {
        guard let initialIndex = items.firstIndex(where: { $0.id == itemID }) else { return }
        defer {
            scheduledItemIDs.remove(itemID)
            activeJobIDsByItem.removeValue(forKey: itemID)
            if let index = items.firstIndex(where: { $0.id == itemID }) {
                items[index].isProcessing = false
            }
        }
        let url = items[initialIndex].url
        guard let service = service() else {
            if let index = items.firstIndex(where: { $0.id == itemID }) {
                items[index].status = .failed
                items[index].message = String(localized: "내장 AI 서버에 연결할 수 없습니다.")
            }
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
            guard let requestIndex = items.firstIndex(where: { $0.id == itemID }) else { return }
            items[requestIndex].jobID = jobID
            activeJobIDsByItem[itemID] = jobID
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
            items[requestIndex].status = .queued
            items[requestIndex].message = String(localized: "AI 서비스에 작업 전달 중")

            _ = try await send(service, payload: WireCodec.encode(request))

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let snapshot = await snapshot(service, jobID: jobID) else { continue }
                guard let index = items.firstIndex(where: { $0.id == itemID }) else {
                    service.cancelJob(jobID.uuidString) { _ in }
                    break
                }
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
                    items[index].existingResult = .complete(languages: options.targetLanguages)
                    break
                }
                if snapshot.status == .completed {
                    items[index].existingResult = .complete(languages: options.targetLanguages)
                }
                if [.completed, .failed, .cancelled].contains(snapshot.status) { break }
            }
            if Task.isCancelled,
               let index = items.firstIndex(where: { $0.id == itemID }),
               !items[index].isFinished {
                items[index].status = .cancelled
                items[index].message = String(localized: "대량 번역을 중단했습니다. 저장된 결과에서 재개할 수 있습니다.")
            }
        } catch {
            if let index = items.firstIndex(where: { $0.id == itemID }) {
                items[index].status = .failed
                items[index].message = error.localizedDescription
            }
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
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false
    @State private var selection: Set<UUID> = []
    @State private var showingActiveDeleteConfirmation = false
    @State private var showingDuplicateReview = false
    @State private var listFilter: BatchListFilter = .all

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
                VStack(spacing: 0) {
                    Picker("목록 보기", selection: $listFilter) {
                        ForEach(BatchListFilter.allCases) { filter in
                            Text(filterTitle(filter)).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider()

                    if filteredItems.isEmpty {
                        ContentUnavailableView(
                            listFilter == .completed ? "완료된 번역이 없습니다" : "표시할 작업이 없습니다",
                            systemImage: listFilter == .completed ? "checkmark.circle" : "tray",
                            description: Text(listFilter == .completed
                                ? "번역이 완료되면 이곳에서 영상을 재생하고 결과를 확인할 수 있습니다."
                                : "다른 목록 보기를 선택하거나 영상을 추가하세요.")
                        )
                    } else {
                        List(selection: $selection) {
                            ForEach(filteredItems) { item in
                                BatchTranslationRow(
                                    item: item,
                                    duplicateNameCount: processor.duplicateNameCount(for: item.id),
                                    onRetry: { processor.retry(item.id) },
                                    onShowDetails: { openWindow(id: "batch-detail", value: item.id) },
                                    onPreview: item.status == .completed
                                        ? { openWindow(id: "batch-preview", value: item.id) }
                                        : nil
                                )
                                .tag(item.id)
                            }
                        }
                    }
                }
            }

            Divider()
            VStack(spacing: 12) {
                BatchLanguageSettingsView()

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

                if processor.isCheckingExistingResults || !processor.resultCheckMessage.isEmpty {
                    HStack(spacing: 8) {
                        if processor.isCheckingExistingResults { ProgressView().controlSize(.small) }
                        Text(processor.resultCheckMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if !processor.isRunning {
                            Button("다시 확인", systemImage: "arrow.clockwise") {
                                processor.refreshExistingResults()
                            }
                            .controlSize(.small)
                            .disabled(processor.isCheckingExistingResults || processor.items.isEmpty)
                        }
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

                if !selection.isEmpty {
                    HStack(spacing: 8) {
                        Text("\(selection.count)개 선택")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("선택 시작", systemImage: "play.fill") {
                            processor.start(ids: selection)
                        }
                        .disabled(processor.isCheckingExistingResults || !canStartSelection)
                        .help(canStartSelection ? "선택한 영상만 번역 시작 또는 재개" : "선택 항목 중 시작할 작업이 없습니다")
                        Button("선택 중단", systemImage: "stop.fill", role: .destructive) {
                            processor.stop(ids: selection)
                        }
                        .disabled(!processor.isRunning || !canStopSelection)
                        .help(processor.isRunning ? "선택한 작업만 안전하게 중단하고 중간 결과 유지" : "현재 실행 중인 대량 번역이 없습니다")
                        Spacer()
                        Button("목록에서 삭제", systemImage: "trash", role: .destructive) {
                            requestSelectedRemoval()
                        }
                        .keyboardShortcut(.delete, modifiers: [])
                        .help("선택한 영상을 대량 번역 목록에서 삭제")
                    }
                    .controlSize(.small)
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
                            .disabled(processor.isCheckingExistingResults || !processor.items.contains(where: { !$0.isFinished }))
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(16)
            .background(.bar)
        }
        .navigationTitle("대량 번역")
        .onChange(of: selection) { _, newSelection in
            if newSelection.count == 1, let id = newSelection.first {
                if listFilter == .completed,
                   processor.items.first(where: { $0.id == id })?.status == .completed {
                    openWindow(id: "batch-preview", value: id)
                } else {
                    openWindow(id: "batch-detail", value: id)
                }
            }
        }
        .onChange(of: listFilter) { _, _ in selection.removeAll() }
        .onChange(of: Set(processor.items.map(\.id))) { _, availableIDs in
            selection.formIntersection(availableIDs)
        }
        .confirmationDialog(
            "실행 중인 선택 작업을 중단하고 삭제할까요?",
            isPresented: $showingActiveDeleteConfirmation
        ) {
            Button("중단하고 목록에서 삭제", role: .destructive) {
                removeSelection()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("완료된 STT·번역 결과는 저장소에 유지되며, 선택한 영상은 대량 번역 목록에서 제거됩니다.")
        }
        .sheet(isPresented: $showingDuplicateReview) {
            DuplicateFilenameReviewView()
                .environment(processor)
        }
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
                Button("기존 번역 확인", systemImage: "checkmark.magnifyingglass") {
                    processor.refreshExistingResults()
                }
                .disabled(processor.isRunning || processor.isCheckingExistingResults || processor.items.isEmpty)
                .help("현재 모델과 언어 기준으로 저장된 STT·번역 다시 확인")
                Button("동일 이름 확인", systemImage: "doc.on.doc") {
                    showingDuplicateReview = true
                }
                .disabled(processor.isRunning || processor.duplicateFilenameGroups.isEmpty)
                .help(processor.duplicateFilenameGroups.isEmpty ? "동일한 파일명의 영상이 없습니다" : "동일한 파일명의 영상을 경로별로 검토")
                Button("폴더 추가…", systemImage: "folder.badge.plus") { processor.addFolders() }
                    .disabled(processor.isScanningFolders)
                    .help("폴더와 하위 폴더에서 영상 검색")
                Button("영상 추가…", systemImage: "plus") { processor.addFiles() }
                    .help("여러 영상 추가")
            }
        }
    }

    private var selectedItems: [BatchProcessor.Item] {
        processor.items.filter { selection.contains($0.id) }
    }

    private var filteredItems: [BatchProcessor.Item] {
        switch listFilter {
        case .all: processor.items
        case .active: processor.items.filter { $0.status != .completed }
        case .completed: processor.items.filter { $0.status == .completed }
        }
    }

    private func filterTitle(_ filter: BatchListFilter) -> String {
        let count: Int
        switch filter {
        case .all: count = processor.items.count
        case .active: count = processor.items.filter { $0.status != .completed }.count
        case .completed: count = processor.completedCount
        }
        return "\(filter.title) \(count)"
    }

    private var canStartSelection: Bool {
        selectedItems.contains { $0.status != .completed && !$0.isProcessing }
    }

    private var canStopSelection: Bool {
        selectedItems.contains { $0.isProcessing || !$0.isFinished }
    }

    private func requestSelectedRemoval() {
        guard !selection.isEmpty else { return }
        if selectedItems.contains(where: \.isProcessing) {
            showingActiveDeleteConfirmation = true
        } else {
            removeSelection()
        }
    }

    private func removeSelection() {
        let ids = selection
        selection.removeAll()
        processor.remove(ids: ids)
    }
}

private struct BatchTranslationRow: View {
    let item: BatchProcessor.Item
    let duplicateNameCount: Int
    let onRetry: () -> Void
    let onShowDetails: () -> Void
    let onPreview: (() -> Void)?
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
                    ExistingResultBadge(state: item.existingResult)
                    if duplicateNameCount > 1 {
                        Label("동일 이름 \(duplicateNameCount)개", systemImage: "doc.on.doc.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .help("다른 폴더에 같은 이름의 영상이 있습니다")
                    }
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
                Button("상세 진행 보기", systemImage: "doc.text.magnifyingglass", action: onShowDetails)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("STT·번역 상세 진행 창 열기")
                if let onPreview {
                    Button("번역 결과 재생", systemImage: "play.rectangle.fill", action: onPreview)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("영상을 재생하며 원문·번역 자막 확인")
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
        .contentShape(Rectangle())
        .help("클릭하여 선택 · 돋보기 버튼으로 상세 진행 보기")
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

private struct BatchLanguageSettingsView: View {
    @Environment(BatchProcessor.self) private var processor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("STT 원어", selection: sourceBinding) {
                    ForEach(processor.availableSourceLanguages, id: \.self) { language in
                        Text(processor.sourceLanguageName(language)).tag(language)
                    }
                }
                .frame(maxWidth: 300)
                .help("자동 감지하거나 모든 대량 번역 영상에 공통으로 사용할 원어를 선택합니다")

                Menu {
                    ForEach(processor.availableTargetLanguages, id: \.self) { language in
                        Button {
                            processor.toggleBatchTargetLanguage(language)
                        } label: {
                            Label(
                                processor.sourceLanguageName(language),
                                systemImage: processor.batchTargetLanguages.contains(language)
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                        }
                        .disabled(
                            processor.batchTargetLanguages.count == 1
                                && processor.batchTargetLanguages.contains(language)
                        )
                    }
                } label: {
                    Label(
                        "번역 언어 · \(processor.batchTargetLanguages.map { $0.uppercased() }.joined(separator: ", "))",
                        systemImage: "globe"
                    )
                }
                .help("하나 이상의 번역 대상 언어를 선택합니다")

                Spacer(minLength: 8)
                if processor.isRunning {
                    Label("실행 중 변경 잠김", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(processor.isRunning || processor.isCheckingExistingResults)

            Text("대량 번역 전체 파일에 적용됩니다. 변경하면 현재 설정 기준으로 기존 STT·번역 결과를 다시 확인합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sourceBinding: Binding<String> {
        Binding(
            get: { processor.batchSourceLanguage },
            set: { processor.setBatchSourceLanguage($0) }
        )
    }
}

private struct DuplicateFilenameReviewView: View {
    @Environment(BatchProcessor.self) private var processor
    @Environment(\.dismiss) private var dismiss
    @State private var removalSelection: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("동일한 이름의 영상 확인")
                    .font(.title2.weight(.semibold))
                Text("경로를 비교해 목록에서 제외할 영상을 선택하세요. 원본 영상 파일은 디스크에서 삭제되지 않습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            if processor.duplicateFilenameGroups.isEmpty {
                ContentUnavailableView(
                    "동일한 이름의 영상이 없습니다",
                    systemImage: "checkmark.circle",
                    description: Text("현재 대량 번역 목록의 파일명은 모두 고유합니다.")
                )
            } else {
                List {
                    ForEach(processor.duplicateFilenameGroups) { group in
                        Section("\(group.displayName) · \(group.items.count)개") {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { offset, item in
                                Button {
                                    if removalSelection.contains(item.id) {
                                        removalSelection.remove(item.id)
                                    } else {
                                        removalSelection.insert(item.id)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: removalSelection.contains(item.id) ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(removalSelection.contains(item.id) ? Color.accentColor : Color.secondary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.url.lastPathComponent)
                                                .foregroundStyle(.primary)
                                            Text(item.url.deletingLastPathComponent().path)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer(minLength: 12)
                                        if offset == 0 && !removalSelection.contains(item.id) {
                                            Text("유지 권장")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.green)
                                        } else if removalSelection.contains(item.id) {
                                            Text("목록에서 제외")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text("\(removalSelection.count)개 선택")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("선택 항목 목록에서 제거", systemImage: "trash", role: .destructive) {
                    processor.remove(ids: removalSelection)
                    removalSelection.removeAll()
                    if processor.duplicateFilenameGroups.isEmpty { dismiss() }
                }
                .disabled(removalSelection.isEmpty || processor.isRunning)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 720, height: 560)
        .onAppear {
            removalSelection = processor.recommendedDuplicateRemovalIDs
        }
    }
}

struct BatchCompletedPreviewView: View {
    @Environment(BatchProcessor.self) private var processor
    @State private var model = AppModel(autoloadLastVideo: false)
    let itemID: UUID?

    private var item: BatchProcessor.Item? {
        processor.items.first { $0.id == itemID }
    }

    var body: some View {
        Group {
            if let item, item.status == .completed {
                HSplitView {
                    playerPane(item)
                        .frame(minWidth: 560)
                    resultList
                        .frame(minWidth: 320, idealWidth: 380, maxWidth: 480)
                }
                .task(id: item.id) {
                    model.loadBatchReviewVideo(item.url, options: processor.reviewOptions)
                }
            } else {
                ContentUnavailableView(
                    "완료된 번역을 찾을 수 없습니다",
                    systemImage: "play.slash",
                    description: Text("완료 목록에서 영상을 다시 선택하세요.")
                )
            }
        }
        .navigationTitle(item?.url.lastPathComponent ?? String(localized: "번역 결과 검토"))
        .onDisappear { model.player.pause() }
    }

    private func playerPane(_ item: BatchProcessor.Item) -> some View {
        VStack(spacing: 0) {
            VideoPlayer(player: model.player)
                .background(.black)
                .overlay(alignment: .bottom) {
                    if model.subtitlesEnabled, !model.activeSubtitle.isEmpty {
                        VStack(spacing: 6) {
                            BatchReviewCaption(text: model.activeSubtitle, isOriginal: false)
                            if model.showOriginalWithTranslation,
                               model.activeTranslationSubtitle != nil,
                               !model.activeOriginalSubtitle.isEmpty {
                                BatchReviewCaption(text: model.activeOriginalSubtitle, isOriginal: true)
                                    .opacity(model.originalSubtitleTranslucent ? 0.68 : 1)
                            }
                        }
                        .padding(.bottom, 44)
                        .allowsHitTesting(false)
                    }
                }

            Divider()
            HStack(spacing: 12) {
                Picker("번역 언어", selection: languageBinding) {
                    ForEach(processor.batchTargetLanguages, id: \.self) { language in
                        Text(language.uppercased()).tag(language)
                    }
                }
                .frame(maxWidth: 220)
                Toggle("원문 함께 보기", isOn: $model.showOriginalWithTranslation)
                Spacer()
                Label("STT \(model.transcript.count)", systemImage: "waveform")
                Label("번역 \(model.translations.count)", systemImage: "character.book.closed")
            }
            .font(.caption)
            .padding(12)
            .background(.bar)
        }
    }

    private var resultList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("번역 결과")
                        .font(.headline)
                    Text("문장을 선택하면 해당 구간으로 이동합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()

            if model.transcript.isEmpty {
                ContentUnavailableView(
                    "자막을 불러오는 중",
                    systemImage: "captions.bubble",
                    description: Text("저장된 STT·번역 결과를 확인하고 있습니다.")
                )
            } else {
                List(model.transcript) { segment in
                    Button {
                        model.player.seek(
                            to: CMTime(seconds: segment.startTime, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(timeText(segment.startTime))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(segment.text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if let translation = model.translations[segment.id]?.text,
                               !translation.isEmpty {
                                Text(translation)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                            } else {
                                Label("번역 없음", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        model.activeTranscriptSegment?.id == segment.id
                            ? Color.accentColor.opacity(0.10)
                            : Color.clear
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { model.selectedLanguage },
            set: {
                model.selectedLanguage = $0
                model.refreshResults()
            }
        )
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct BatchReviewCaption: View {
    let text: String
    let isOriginal: Bool

    var body: some View {
        Text(text)
            .font(isOriginal ? .callout.italic() : .title3.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, isOriginal ? 12 : 16)
            .padding(.vertical, isOriginal ? 6 : 8)
            .background(.black.opacity(isOriginal ? 0.32 : 0.52), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 24)
            .shadow(color: .black.opacity(0.8), radius: 3)
    }
}

struct BatchTranslationDetailView: View {
    @Environment(BatchProcessor.self) private var processor
    let itemID: UUID?

    private var item: BatchProcessor.Item? {
        processor.items.first { $0.id == itemID }
    }

    var body: some View {
        Group {
            if let item {
                detail(item)
            } else {
                ContentUnavailableView(
                    "작업을 찾을 수 없습니다",
                    systemImage: "doc.questionmark",
                    description: Text("대량 번역 목록에서 항목이 제거되었거나 아직 선택되지 않았습니다.")
                )
            }
        }
        .navigationTitle(item?.url.lastPathComponent ?? String(localized: "번역 상세 진행"))
    }

    private func detail(_ item: BatchProcessor.Item) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(item)
                    GroupBox("대량 번역 언어 설정") {
                        BatchLanguageSettingsView()
                            .padding(12)
                    }
                    BatchPipelineView(item: item)
                    metrics(item)
                    liveResults(item)
                }
                .padding(20)
            }

            Divider()
            HStack {
                Label(statusText(item), systemImage: statusSymbol(item))
                    .foregroundStyle(statusColor(item))
                Text(item.message.isEmpty ? statusText(item) : item.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if item.isFinished && item.status != .completed {
                    Button("다시 시도", systemImage: "arrow.clockwise") {
                        processor.retry(item.id)
                    }
                    .disabled(processor.isRunning)
                    .help(processor.isRunning ? "대량 번역 실행이 끝난 뒤 다시 시도할 수 있습니다" : "저장된 결과부터 다시 시도")
                }
            }
            .padding(16)
            .background(.bar)
        }
    }

    private func header(_ item: BatchProcessor.Item) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusSymbol(item))
                    .font(.title2)
                    .foregroundStyle(statusColor(item))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.url.lastPathComponent)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    Text(item.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Text(item.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.title2.monospacedDigit().weight(.medium))
            }
            ProgressView(value: min(1, max(0, item.progress)))
                .controlSize(.large)
            Text(item.message.isEmpty ? statusText(item) : item.message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func metrics(_ item: BatchProcessor.Item) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                metric("현재 상태", value: statusText(item), icon: statusSymbol(item))
                metric("현재 청크", value: chunkText(item), icon: "square.stack.3d.up")
            }
            GridRow {
                metric("STT 진행률", value: item.sttProgress.formatted(.percent.precision(.fractionLength(0))), icon: "waveform")
                metric("번역 진행률", value: item.translationProgress.formatted(.percent.precision(.fractionLength(0))), icon: "character.book.closed")
            }
        }
    }

    private func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit().weight(.medium))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func liveResults(_ item: BatchProcessor.Item) -> some View {
        HStack(alignment: .top, spacing: 16) {
            livePanel(
                title: "실시간 STT",
                icon: "waveform",
                current: item.liveTranscriptText,
                latest: item.lastTranscriptText
            )
            livePanel(
                title: "실시간 LLM 번역",
                icon: "character.book.closed",
                current: item.liveTranslationText,
                latest: item.lastTranslationText
            )
        }
    }

    private func livePanel(title: String, icon: String, current: String?, latest: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.tint)
            liveSection("현재 생성 중", text: current)
            Divider()
            liveSection("최근 완료 내용", text: latest)
        }
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func liveSection(_ title: String, text: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text?.isEmpty == false ? text! : "결과를 기다리는 중…")
                .font(.body)
                .foregroundStyle(text?.isEmpty == false ? .primary : .tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        }
    }

    private func chunkText(_ item: BatchProcessor.Item) -> String {
        guard item.totalChunks > 0 else { return "대기 중" }
        return "\(min(item.currentChunk + 1, item.totalChunks)) / \(item.totalChunks)"
    }

    private func statusText(_ item: BatchProcessor.Item) -> String {
        switch item.status {
        case .queued: item.isProcessing ? "작업 준비 중" : "대기 중"
        case .extracting: "오디오 추출 중"
        case .transcribing: "STT 진행 중"
        case .translating: "LLM 번역 중"
        case .synthesizing: "번역 음성 생성 중"
        case .refining: "번역 품질 개선 중"
        case .paused: "일시 정지됨"
        case .completed: "완료"
        case .failed: "실패"
        case .cancelled: "취소됨"
        }
    }

    private func statusSymbol(_ item: BatchProcessor.Item) -> String {
        switch item.status {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        case .queued where !item.isProcessing: "clock"
        case .extracting: "waveform.badge.magnifyingglass"
        case .transcribing: "waveform"
        case .translating, .refining: "character.book.closed"
        case .synthesizing: "waveform.circle"
        case .paused: "pause.circle.fill"
        default: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    private func statusColor(_ item: BatchProcessor.Item) -> Color {
        switch item.status {
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        case .queued where !item.isProcessing: .secondary
        default: .accentColor
        }
    }
}

private struct ExistingResultBadge: View {
    let state: BatchProcessor.ExistingResultState

    var body: some View {
        HStack(spacing: 5) {
            if case .checking = state {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: symbol)
            }
            Text(label)
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .checking: "기존 결과 확인 중"
        case .notFound: "미처리"
        case .transcriptOnly(let count): "STT \(count)구간 있음 · 번역 필요"
        case .partial(let completed, let missing, _):
            completed.isEmpty
                ? "번역 일부 있음 · \(missing.map { $0.uppercased() }.joined(separator: ", ")) 미완료"
                : "\(completed.map { $0.uppercased() }.joined(separator: ", ")) 완료 · 나머지 재개"
        case .complete(let languages):
            "이미 번역 완료 · \(languages.map { $0.uppercased() }.joined(separator: ", "))"
        case .error: "기존 결과 확인 실패"
        }
    }

    private var symbol: String {
        switch state {
        case .complete: "checkmark.seal.fill"
        case .partial, .transcriptOnly: "clock.badge.checkmark"
        case .notFound: "circle.dashed"
        case .error: "exclamationmark.triangle.fill"
        case .checking: "clock"
        }
    }

    private var color: Color {
        switch state {
        case .complete: .green
        case .partial, .transcriptOnly: .orange
        case .error: .red
        case .checking, .notFound: .secondary
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
