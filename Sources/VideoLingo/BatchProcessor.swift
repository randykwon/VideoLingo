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
    var automaticallyAdjustConcurrentJobs: Bool = UserDefaults.standard.object(forKey: "batchAutomaticallyAdjustConcurrentJobs") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticallyAdjustConcurrentJobs, forKey: "batchAutomaticallyAdjustConcurrentJobs") }
    }

    var recommendedConcurrentJobs: Int {
        let process = ProcessInfo.processInfo
        let memoryGB = Double(process.physicalMemory) / 1_073_741_824
        let memoryLimit: Int
        switch memoryGB {
        case ..<12: memoryLimit = 1
        case ..<20: memoryLimit = 2
        case ..<28: memoryLimit = 3
        case ..<48: memoryLimit = 4
        default: memoryLimit = 5
        }
        let hardwareLimit = min(memoryLimit, max(1, min(5, process.activeProcessorCount / 3)))
        switch process.thermalState {
        case .fair: return min(2, hardwareLimit)
        case .serious, .critical: return 1
        case .nominal: return hardwareLimit
        @unknown default: return min(2, hardwareLimit)
        }
    }

    var effectiveConcurrentJobs: Int {
        automaticallyAdjustConcurrentJobs ? recommendedConcurrentJobs : maximumConcurrentJobs
    }

    var automaticConcurrencySummary: String {
        let process = ProcessInfo.processInfo
        let memoryGB = Int((Double(process.physicalMemory) / 1_073_741_824).rounded())
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = String(localized: "정상")
        case .fair: thermal = String(localized: "주의")
        case .serious: thermal = String(localized: "높음")
        case .critical: thermal = String(localized: "위험")
        @unknown default: thermal = String(localized: "알 수 없음")
        }
        return String(localized: "메모리 \(memoryGB)GB · CPU \(process.activeProcessorCount)코어 · 열 상태 \(thermal)")
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
    var batchSTTModelName: String { options.sttModel }
    var batchTranslationModelName: String { options.translationModel }
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
        let concurrency = effectiveConcurrentJobs
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
                // 고빈도 실시간 갱신은 재설계 전까지 중단하고 저빈도 상태 확인만 유지합니다.
                try? await Task.sleep(for: .seconds(2))
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
    @State private var showingDuplicateCleanupConfirmation = false
    @State private var showingStartConfirmation = false
    @State private var pendingStartIDs: Set<UUID> = []
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
                    VStack(alignment: .trailing, spacing: 4) {
                        Toggle("Mac 성능에 맞게 자동 조정", isOn: $processor.automaticallyAdjustConcurrentJobs)
                            .disabled(processor.isRunning)
                        Stepper(value: $processor.maximumConcurrentJobs, in: 1...10) {
                            Text(processor.automaticallyAdjustConcurrentJobs
                                ? "자동 동시 처리 \(processor.effectiveConcurrentJobs)개"
                                : "수동 동시 처리 \(processor.maximumConcurrentJobs)개")
                                .monospacedDigit()
                        }
                        .disabled(processor.isRunning || processor.automaticallyAdjustConcurrentJobs)
                        Text(processor.automaticConcurrencySummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .help("메모리·CPU·열 상태를 기준으로 안전한 동시 처리 수를 정합니다")
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
                            requestStart(ids: selection)
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
                        Button("대량 번역 시작", systemImage: "play.fill") {
                            requestStart(ids: Set(processor.items.filter { !$0.isFinished }.map(\.id)))
                        }
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
        .sheet(isPresented: $showingDuplicateCleanupConfirmation) {
            DuplicateBatchCleanupView()
                .environment(processor)
        }
        .sheet(isPresented: $showingStartConfirmation) {
            BatchStartConfirmationView(itemIDs: pendingStartIDs) {
                let ids = pendingStartIDs
                pendingStartIDs.removeAll()
                processor.start(ids: ids)
            }
            .environment(processor)
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
                Button("멀티 화면 모니터", systemImage: "rectangle.grid.2x2") {
                    openWindow(id: "batch-monitor")
                }
                .disabled(processor.items.isEmpty)
                .help("여러 영상과 STT·번역 진행 상황을 한 화면에서 확인")
                Button("기존 번역 확인", systemImage: "checkmark.magnifyingglass") {
                    processor.refreshExistingResults()
                }
                .disabled(processor.isRunning || processor.isCheckingExistingResults || processor.items.isEmpty)
                .help("현재 모델과 언어 기준으로 저장된 STT·번역 다시 확인")
                Menu("중복 파일 정리", systemImage: "doc.on.doc") {
                    Button("중복 전체 일괄 제거", systemImage: "rectangle.stack.badge.minus") {
                        showingDuplicateCleanupConfirmation = true
                    }
                    Button("경로별로 검토…", systemImage: "list.bullet.rectangle") {
                        showingDuplicateReview = true
                    }
                }
                .disabled(processor.isRunning || processor.duplicateFilenameGroups.isEmpty)
                .help(processor.duplicateFilenameGroups.isEmpty
                    ? "동일한 파일명의 영상이 없습니다"
                    : "\(processor.duplicateFilenameGroups.count)개 중복 그룹에서 \(processor.duplicateFilenameRemovalCount)개를 정리")
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

    private func requestStart(ids: Set<UUID>) {
        let availableIDs = Set(processor.items.filter {
            ids.contains($0.id) && $0.status != .completed && !$0.isProcessing
        }.map(\.id))
        guard !availableIDs.isEmpty else { return }
        pendingStartIDs = availableIDs
        showingStartConfirmation = true
    }
}

private struct BatchStartConfirmationView: View {
    @Environment(BatchProcessor.self) private var processor
    @Environment(\.dismiss) private var dismiss
    let itemIDs: Set<UUID>
    let onStart: () -> Void

    var body: some View {
        @Bindable var processor = processor
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Label("대량 번역 시작 전 확인", systemImage: "checklist.checked")
                    .font(.title2.weight(.semibold))
                Text("STT 원어와 번역 대상 언어가 올바른지 확인한 뒤 시작하세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                BatchLanguageSettingsView()
                    .padding(4)
            } label: {
                Label("언어 설정", systemImage: "globe")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("실행 대상") {
                        Text("\(startableCount)개 영상")
                            .monospacedDigit()
                    }
                    LabeledContent("STT 모델") {
                        Text(processor.batchSTTModelName)
                            .lineLimit(1)
                    }
                    LabeledContent("번역 모델") {
                        Text(processor.batchTranslationModelName)
                            .lineLimit(1)
                    }
                    LabeledContent("동시 처리") {
                        VStack(alignment: .trailing, spacing: 6) {
                            Toggle("Mac 성능에 맞게 자동 조정", isOn: $processor.automaticallyAdjustConcurrentJobs)
                            Stepper(value: $processor.maximumConcurrentJobs, in: 1...10) {
                                Text(processor.automaticallyAdjustConcurrentJobs
                                    ? "자동 \(processor.effectiveConcurrentJobs)개"
                                    : "수동 \(processor.maximumConcurrentJobs)개")
                                    .monospacedDigit()
                            }
                            .disabled(processor.automaticallyAdjustConcurrentJobs)
                            Text(processor.automaticConcurrencySummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(4)
            } label: {
                Label("처리 설정", systemImage: "gearshape.2")
            }

            if processor.isCheckingExistingResults {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("변경한 언어 설정으로 기존 결과를 다시 확인 중…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if processor.batchSourceLanguage.isEmpty {
                Label("STT 원어는 영상마다 자동 감지됩니다.", systemImage: "waveform.badge.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("확인하고 번역 시작", systemImage: "play.fill") {
                    dismiss()
                    onStart()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(processor.isCheckingExistingResults || processor.batchTargetLanguages.isEmpty || startableCount == 0)
                .help(processor.isCheckingExistingResults ? "기존 결과 확인이 끝나면 시작할 수 있습니다" : "확인한 설정으로 대량 번역 시작")
            }
        }
        .padding(24)
        .frame(width: 600)
        .interactiveDismissDisabled(processor.isCheckingExistingResults)
    }

    private var startableCount: Int {
        processor.items.filter {
            itemIDs.contains($0.id) && $0.status != .completed && !$0.isProcessing
        }.count
    }
}

private enum BatchMonitorFilter: String, CaseIterable, Identifiable {
    case active
    case all
    case completed

    var id: Self { self }
    var title: String {
        switch self {
        case .active: "실행 중"
        case .all: "전체"
        case .completed: "완료"
        }
    }
}

/// 여러 영상 화면과 실시간 STT·번역 결과를 한 창에서 동시에 관찰하는 대시보드입니다.
struct BatchMultiMonitorView: View {
    @Environment(BatchProcessor.self) private var processor
    @Environment(\.openWindow) private var openWindow
    @AppStorage("batchMonitorColumnCount") private var columnCount = 2
    @State private var filter: BatchMonitorFilter = .active
    @State private var playbackSelection: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            monitorHeader
            Divider()

            if processor.items.isEmpty {
                ContentUnavailableView(
                    "모니터링할 영상이 없습니다",
                    systemImage: "rectangle.grid.2x2",
                    description: Text("대량 번역 창에서 영상을 추가하면 각 영상과 STT·번역 진행 상황을 함께 볼 수 있습니다.")
                )
            } else if visibleItems.isEmpty {
                ContentUnavailableView(
                    filter == .active ? "현재 실행 중인 영상이 없습니다" : "완료된 영상이 없습니다",
                    systemImage: filter == .active ? "pause.circle" : "checkmark.circle",
                    description: Text(filter == .active
                        ? "대량 번역을 시작하거나 ‘전체’ 화면을 선택하세요."
                        : "번역이 끝난 영상은 이곳에 자동으로 나타납니다.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(visibleItems) { item in
                            BatchMonitorTile(
                                item: item,
                                playsVideo: playbackBinding(for: item.id),
                                onShowDetails: { openWindow(id: "batch-detail", value: item.id) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("STT·번역 멀티 화면")
        .frame(minWidth: 880, minHeight: 600)
        .onChange(of: Set(processor.items.map(\.id))) { _, availableIDs in
            playbackSelection.formIntersection(availableIDs)
        }
    }

    private var monitorHeader: some View {
        HStack(spacing: 16) {
            Picker("표시 항목", selection: $filter) {
                ForEach(BatchMonitorFilter.allCases) { option in
                    Text("\(option.title) \(count(for: option))").tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 400)

            Spacer()

            Label("실행 \(processor.runningCount) · 대기 \(processor.pendingCount) · 완료 \(processor.completedCount)",
                  systemImage: processor.isRunning ? "dot.radiowaves.left.and.right" : "chart.bar")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text("재생 선택 \(visiblePlaybackSelectionCount)개")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button(allVisibleItemsSelected ? "표시 영상 선택 해제" : "표시 영상 전체 선택",
                   systemImage: allVisibleItemsSelected ? "checkmark.square.fill" : "square.stack") {
                if allVisibleItemsSelected {
                    playbackSelection.subtract(visibleItems.map(\.id))
                } else {
                    playbackSelection.formUnion(visibleItems.map(\.id))
                }
            }
            .disabled(visibleItems.isEmpty)
            .help("현재 필터에 표시된 영상의 음소거 재생을 한 번에 선택하거나 해제")

            Stepper(value: $columnCount, in: 1...4) {
                Text("한 줄 \(columnCount)개")
                    .monospacedDigit()
            }
            .frame(width: 125)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var visibleItems: [BatchProcessor.Item] {
        switch filter {
        case .active: processor.items.filter(\.isProcessing)
        case .all: processor.items
        case .completed: processor.items.filter { $0.status == .completed }
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: columnCount)
    }

    private var visiblePlaybackSelectionCount: Int {
        visibleItems.filter { playbackSelection.contains($0.id) }.count
    }

    private var allVisibleItemsSelected: Bool {
        !visibleItems.isEmpty && visibleItems.allSatisfy { playbackSelection.contains($0.id) }
    }

    private func playbackBinding(for itemID: UUID) -> Binding<Bool> {
        Binding(
            get: { playbackSelection.contains(itemID) },
            set: { selected in
                if selected {
                    playbackSelection.insert(itemID)
                } else {
                    playbackSelection.remove(itemID)
                }
            }
        )
    }

    private func count(for option: BatchMonitorFilter) -> Int {
        switch option {
        case .active: processor.runningCount
        case .all: processor.items.count
        case .completed: processor.completedCount
        }
    }
}

private struct BatchMonitorTile: View {
    let item: BatchProcessor.Item
    @Binding var playsVideo: Bool
    let onShowDetails: () -> Void
    @State private var player: AVPlayer

    init(item: BatchProcessor.Item, playsVideo: Binding<Bool>, onShowDetails: @escaping () -> Void) {
        self.item = item
        _playsVideo = playsVideo
        self.onShowDetails = onShowDetails
        _player = State(initialValue: AVPlayer(url: item.url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                BatchMonitorPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(.black)

                HStack(spacing: 6) {
                    Image(systemName: statusSymbol)
                    Text(statusText)
                    Spacer()
                    Text(item.progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.58))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Toggle("미리보기 재생", isOn: $playsVideo)
                        .toggleStyle(.checkbox)
                        .help("선택한 영상만 소리 없이 재생합니다")
                    Text(item.url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if item.totalChunks > 0 {
                        Text("청크 \(min(item.currentChunk + 1, item.totalChunks))/\(item.totalChunks)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button("상세 진행 보기", systemImage: "arrow.up.right.square", action: onShowDetails)
                        .labelStyle(.iconOnly)
                        .help("이 영상의 상세 진행 창 열기")
                }

                monitorProgress(title: "STT", value: item.sttProgress, icon: "waveform")
                monitorProgress(title: "번역", value: item.translationProgress, icon: "character.book.closed")

                liveText(title: "실시간 STT", text: item.liveTranscriptText ?? item.lastTranscriptText)
                liveText(title: "실시간 번역", text: item.liveTranslationText ?? item.lastTranslationText)
            }
            .padding(12)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(playsVideo ? Color.accentColor : item.isProcessing ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.2))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { updatePlayback() }
        .onDisappear { player.pause() }
        .onChange(of: playsVideo) { _, _ in updatePlayback() }
    }

    private func monitorProgress(title: String, value: Double, icon: String) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .frame(width: 62, alignment: .leading)
            ProgressView(value: min(1, max(0, value)))
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func liveText(title: String, text: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text?.isEmpty == false ? text! : "결과를 기다리는 중…")
                .font(.caption)
                .foregroundStyle(text?.isEmpty == false ? .primary : .tertiary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func updatePlayback() {
        player.isMuted = true
        if playsVideo { player.play() } else { player.pause() }
    }

    private var statusText: String {
        switch item.status {
        case .queued: item.isProcessing ? "준비 중" : "대기 중"
        case .extracting: "음성 추출"
        case .transcribing: "STT 처리"
        case .translating: "LLM 번역"
        case .synthesizing: "음성 생성"
        case .refining: "품질 개선"
        case .completed: "완료"
        case .paused: "일시 정지"
        case .cancelled: "취소됨"
        case .failed: "실패"
        }
    }

    private var statusSymbol: String {
        switch item.status {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled, .paused: "pause.circle.fill"
        case .queued where !item.isProcessing: "clock"
        default: "dot.radiowaves.left.and.right"
        }
    }
}

private struct BatchMonitorPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
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
    @State private var showingTrashConfirmation = false
    @State private var isMovingToTrash = false
    @State private var trashStatusMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("동일한 이름의 영상 확인")
                    .font(.title2.weight(.semibold))
                Text("경로를 비교해 제외할 영상을 선택하세요. 기본 동작은 목록에서만 제거하며, 필요하면 실제 파일을 macOS 휴지통으로 이동할 수 있습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !trashStatusMessage.isEmpty {
                    Text(trashStatusMessage)
                        .font(.caption)
                        .foregroundStyle(trashStatusMessage.contains("실패") ? .red : .secondary)
                        .textSelection(.enabled)
                }
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
                Button("중복 전체 선택") {
                    removalSelection = processor.recommendedDuplicateRemovalIDs
                }
                .disabled(processor.recommendedDuplicateRemovalIDs.isEmpty || isMovingToTrash)
                Button("선택 해제") {
                    removalSelection.removeAll()
                }
                .disabled(removalSelection.isEmpty || isMovingToTrash)
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("실제 영상을 휴지통으로 이동", systemImage: "trash", role: .destructive) {
                    showingTrashConfirmation = true
                }
                .disabled(removalSelection.isEmpty || processor.isRunning || isMovingToTrash)
                .help("선택한 실제 영상 파일을 macOS 휴지통으로 이동합니다")
                Button("선택 항목 목록에서 제거", systemImage: "rectangle.badge.minus", role: .destructive) {
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
        .confirmationDialog(
            "선택한 실제 영상 \(removalSelection.count)개를 휴지통으로 이동할까요?",
            isPresented: $showingTrashConfirmation
        ) {
            Button("영상 파일을 휴지통으로 이동", role: .destructive) {
                moveSelectionToTrash()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("영상은 대량 번역 목록에서도 제거됩니다. STT·번역 데이터베이스 결과는 유지되며, 영상 파일은 Finder의 휴지통에서 복구할 수 있습니다.")
        }
    }

    private func moveSelectionToTrash() {
        let ids = removalSelection
        isMovingToTrash = true
        trashStatusMessage = String(localized: "선택한 영상 파일을 휴지통으로 이동 중…")
        Task {
            let result = await processor.moveVideosToTrash(ids: ids)
            isMovingToTrash = false
            removalSelection.subtract(ids)
            if let failure = result.failureMessage {
                trashStatusMessage = String(localized: "\(result.movedCount)개 이동 후 실패: \(failure)")
            } else {
                trashStatusMessage = String(localized: "영상 \(result.movedCount)개를 휴지통으로 이동했습니다.")
                if processor.duplicateFilenameGroups.isEmpty { dismiss() }
            }
        }
    }
}

private struct DuplicateBatchCleanupView: View {
    @Environment(BatchProcessor.self) private var processor
    @Environment(\.dismiss) private var dismiss
    @State private var alsoMoveActualFilesToTrash = false
    @State private var isCleaning = false
    @State private var statusMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Label("중복 파일 일괄 정리", systemImage: "doc.on.doc")
                    .font(.title2.weight(.semibold))
                Text("동일한 파일명마다 첫 번째 영상 1개를 남기고 나머지 \(processor.duplicateFilenameRemovalCount)개를 정리합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("중복 그룹") {
                        Text("\(processor.duplicateFilenameGroups.count)개")
                            .monospacedDigit()
                    }
                    LabeledContent("남겨 둘 영상") {
                        Text("그룹마다 1개")
                            .foregroundStyle(.green)
                    }
                    LabeledContent("제거 대상") {
                        Text("\(processor.duplicateFilenameRemovalCount)개")
                            .monospacedDigit()
                    }
                }
                .padding(4)
            } label: {
                Label("정리 대상 확인", systemImage: "checklist")
            }

            Toggle(isOn: $alsoMoveActualFilesToTrash) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("실제 영상 파일도 휴지통으로 이동")
                        .font(.body.weight(.medium))
                    Text(alsoMoveActualFilesToTrash
                        ? "유지본 1개를 제외한 실제 영상 파일을 Finder 휴지통으로 이동합니다."
                        : "대량 번역 목록에서만 제거하며 실제 영상 파일은 그대로 둡니다.")
                        .font(.caption)
                        .foregroundStyle(alsoMoveActualFilesToTrash ? Color.orange : Color.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(isCleaning)

            if isCleaning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCleaning)
                Button(alsoMoveActualFilesToTrash ? "확인 후 휴지통으로 이동" : "목록에서 일괄 제거",
                       systemImage: alsoMoveActualFilesToTrash ? "trash" : "rectangle.stack.badge.minus",
                       role: .destructive) {
                    performCleanup()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(processor.recommendedDuplicateRemovalIDs.isEmpty || isCleaning)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(isCleaning)
    }

    private func performCleanup() {
        let ids = processor.recommendedDuplicateRemovalIDs
        guard !ids.isEmpty else { return }
        if alsoMoveActualFilesToTrash {
            isCleaning = true
            statusMessage = String(localized: "유지본을 제외한 실제 영상 파일을 휴지통으로 이동 중…")
            Task {
                let result = await processor.moveVideosToTrash(ids: ids)
                isCleaning = false
                if let failure = result.failureMessage {
                    statusMessage = String(localized: "\(result.movedCount)개 이동 후 실패: \(failure)")
                } else {
                    dismiss()
                }
            }
        } else {
            processor.remove(ids: ids)
            dismiss()
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
