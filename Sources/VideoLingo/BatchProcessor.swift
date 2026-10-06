import AppKit
import AVKit
import Darwin
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
    case active
    case all
    case completed

    var id: Self { self }
    var title: String {
        switch self {
        case .active: "완료 숨기기"
        case .all: "전체"
        case .completed: "번역 완료"
        }
    }
}

/// 여러 영상을 큐에 넣고 설정된 동시 처리 수만큼 STT·LLM 번역을 병렬 실행합니다.
@MainActor
@Observable
final class BatchProcessor {
    static let shared = BatchProcessor()

    private static let snapshotPollingInterval = Duration.seconds(2)
    private static let missingSnapshotRecoveryThreshold = 3
    private static let maximumServiceRecoveryAttempts = 3
    private static let slowProgressWarningInterval: TimeInterval = 90
    private static let stalledProgressRecoveryInterval: TimeInterval = 300
    private static let remoteFailureRetryInterval = Duration.seconds(10 * 60)
    private static let rememberedVideoPathsKey = "batchRememberedVideoPaths"
    private static let autoResumePathsKey = "batchAutoResumePaths"

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

    /// 대량 번역을 STT 레인과 번역 레인으로 나눠 처리하기 위한 단계 구분입니다.
    /// STT는 ANE, 번역은 GPU/LLM을 주로 쓰므로 서로 기다리지 않게 분리하면 처리량이 오릅니다.
    enum JobPhase { case stt, translation }

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
        /// STT 레인을 통과해 번역 레인 차례를 기다리는 중인지.
        var sttCompleted = false

        var isFinished: Bool { [.completed, .failed, .cancelled].contains(status) }
    }

    var items: [Item] = []
    var isRunning = false
    var isPaused = false
    var isScanningFolders = false
    var isCheckingExistingResults = false
    var folderScanMessage = ""
    var resultCheckMessage = ""
    var automaticallyResumeOnLaunch: Bool = UserDefaults.standard.object(forKey: "batchAutomaticallyResumeOnLaunch") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(automaticallyResumeOnLaunch, forKey: "batchAutomaticallyResumeOnLaunch")
            if automaticallyResumeOnLaunch, isRunning {
                persistAutoResumeState()
            } else if !automaticallyResumeOnLaunch {
                clearAutoResumeState()
            }
        }
    }
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
    var prefersRemoteWorkers: Bool = UserDefaults.standard.object(forKey: "batchPrefersRemoteWorkers") as? Bool ?? true {
        didSet { UserDefaults.standard.set(prefersRemoteWorkers, forKey: "batchPrefersRemoteWorkers") }
    }
    /// 한 영상을 STT부터 번역까지 끝낸 뒤 다음 영상으로 넘어갑니다.
    /// 사용 가능한 원격 서버를 우선 사용해 '완료된 영상'을 빠르게 늘리는 모드입니다.
    var focusedTranslationMode: Bool = UserDefaults.standard.object(forKey: "batchFocusedTranslationMode") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(focusedTranslationMode, forKey: "batchFocusedTranslationMode")
            if focusedTranslationMode { prefersRemoteWorkers = true }
        }
    }
    var remoteRequestMultiplier: Int = {
        let stored = UserDefaults.standard.integer(forKey: "batchRemoteRequestMultiplier")
        return stored == 0 ? 2 : min(4, max(1, stored))
    }() {
        didSet {
            UserDefaults.standard.set(min(4, max(1, remoteRequestMultiplier)), forKey: "batchRemoteRequestMultiplier")
        }
    }
    var localCPUUsageLimit: Int = {
        let stored = UserDefaults.standard.integer(forKey: "batchLocalCPUUsageLimit")
        return stored == 0 ? 50 : min(90, max(20, stored))
    }() {
        didSet {
            UserDefaults.standard.set(min(90, max(20, localCPUUsageLimit)), forKey: "batchLocalCPUUsageLimit")
        }
    }
    var usesChunkedAudioUpload: Bool = UserDefaults.standard.object(forKey: "batchUsesChunkedAudioUpload") as? Bool ?? true {
        didSet { UserDefaults.standard.set(usesChunkedAudioUpload, forKey: "batchUsesChunkedAudioUpload") }
    }
    var chunkedAudioThresholdMB: Int = {
        let stored = UserDefaults.standard.integer(forKey: "batchChunkedAudioThresholdMB")
        return stored == 0 ? 100 : min(500, max(25, stored))
    }() {
        didSet {
            UserDefaults.standard.set(min(500, max(25, chunkedAudioThresholdMB)), forKey: "batchChunkedAudioThresholdMB")
        }
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

    /// STT 레인 동시 실행 수입니다. 번역보다 가볍고 다른 연산 자원을 쓰므로 더 많이 돌립니다.
    var maximumConcurrentSTTJobs: Int = {
        let stored = UserDefaults.standard.integer(forKey: "batchMaximumConcurrentSTTJobs")
        return stored == 0 ? 3 : min(10, max(1, stored))
    }() {
        didSet {
            UserDefaults.standard.set(min(10, max(1, maximumConcurrentSTTJobs)), forKey: "batchMaximumConcurrentSTTJobs")
        }
    }

    var effectiveSTTConcurrentJobs: Int {
        if focusedTranslationMode { return 1 }
        let local = automaticallyAdjustConcurrentJobs
            ? min(4, max(2, recommendedConcurrentJobs + 1))
            : maximumConcurrentSTTJobs
        let remote = RemoteWorkerPool.shared.totalSTTSlots
        return local + remote * (prefersRemoteWorkers ? remoteRequestMultiplier : 1)
    }

    var effectiveConcurrentJobs: Int {
        if focusedTranslationMode { return 1 }
        let local = automaticallyAdjustConcurrentJobs ? recommendedConcurrentJobs : maximumConcurrentJobs
        let remote = RemoteWorkerPool.shared.totalTranslationSlots
        return local + remote * (prefersRemoteWorkers ? remoteRequestMultiplier : 1)
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

    var workloadRoutingSummary: String {
        if focusedTranslationMode {
            let servers = RemoteWorkerPool.shared.availableWorkers.count
            return String(localized: "집중 모드 · 영상 1개씩 완료 · 연결된 원격 서버 \(servers)대 우선")
        }
        let remote = RemoteWorkerPool.shared.hasUsableWorker
            ? String(localized: "원격 요청 \(remoteRequestMultiplier)배 우선")
            : String(localized: "사용 가능한 원격 서버 없음")
        return String(localized: "\(remote) · 내장 서버 CPU \(localCPUUsageLimit)% 소프트 상한")
    }

    private var options = ProcessingOptions()
    /// 다음 실행에서 화자 분석을 다시 수행할 항목입니다. 요청을 보낼 때 소비합니다.
    private var speakerReanalysisItemIDs: Set<UUID> = []
    /// 파일명과 무관하게 내용이 같은 영상 묶음입니다.
    private(set) var contentDuplicateGroups: [ContentDuplicateGroup] = []
    private(set) var isScanningContentDuplicates = false
    private(set) var contentDuplicateMessage = ""
    private var connection: NSXPCConnection?
    private var runTask: Task<Void, Never>?
    private var folderScanTask: Task<Void, Never>?
    private var resultCheckTask: Task<Void, Never>?
    private var activeJobIDsByItem: [UUID: UUID] = [:]
    private var activeLocalSTTJobs = 0
    private var activeLocalTranslationJobs = 0
    private var localServiceCPUSample: (uptime: TimeInterval, cpuNanoseconds: UInt64)?
    private var localSTTRealtimeFactor: Double {
        let stored = UserDefaults.standard.double(forKey: "batchLocalSTTRealtimeFactor")
        return stored > 0 ? min(50, max(0.25, stored)) : 2
    }

    private struct STTRoutingDecision {
        let useRemote: Bool
        let audioDuration: TimeInterval
        let summary: String
    }
    private var scheduledItemIDs: Set<UUID> = []
    /// 집중 모드에서 STT와 번역 레인이 같은 영상을 끝까지 이어받도록 고정합니다.
    private var focusedItemID: UUID?
    private var pausedItemIDs: Set<UUID> = []
    private var pendingLaunchResumePaths: Set<String> = []
    @ObservationIgnored private var remoteFailureRetryTask: Task<Void, Never>?
    private var alternateResultDirectoryBookmark: Data?
    var alternateResultDirectoryURL: URL?

    private init() {
        if let bookmark = UserDefaults.standard.data(forKey: "batchAlternateResultDirectoryBookmark") {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                alternateResultDirectoryBookmark = bookmark
                alternateResultDirectoryURL = url
            }
        }

        let rememberedPaths = UserDefaults.standard.stringArray(forKey: Self.rememberedVideoPathsKey) ?? []
        if automaticallyResumeOnLaunch {
            pendingLaunchResumePaths = Set(UserDefaults.standard.stringArray(forKey: Self.autoResumePathsKey) ?? [])
        } else {
            clearAutoResumeState()
        }
        let rememberedURLs = rememberedPaths
            .map { URL(filePath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) && Self.isSupportedVideoURL($0) }
        items = Array(Set(rememberedURLs)).map { Item(url: $0) }.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        rememberCurrentVideoList()

        if !items.isEmpty {
            folderScanMessage = String(localized: "지난 검색 결과 영상 \(items.count)개를 복원했습니다.")
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.refreshExistingResults()
            }
        }

        // 원격 요청이 실패해도 사용자가 계속 지켜보며 재시도할 필요가 없도록 합니다.
        // 취소·일시 정지는 사용자의 명시적 선택이므로 실패 상태만 자동으로 재개합니다.
        remoteFailureRetryTask = Task { @MainActor [weak self] in
            await self?.monitorRemoteFailures()
        }
    }

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
    var alternateResultDirectoryDisplayPath: String? { alternateResultDirectoryURL?.path(percentEncoded: false) }

    /// 원본 옆에도, 지정한 폴더에도 쓸 수 없을 때 결과가 저장되는 앱 관리 폴더입니다.
    var managedResultsDisplayPath: String {
        MediaSidecarStore.managedResultsRootURL().path(percentEncoded: false)
    }

    /// 앱 관리 결과 폴더를 Finder에서 엽니다.
    func revealManagedResultsFolder() {
        let url = MediaSidecarStore.managedResultsRootURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 결과가 원본 옆이 아닌 곳에 저장될 때 항목에 덧붙일 안내 문구입니다.
    private func resultLocationNote(for mediaURL: URL) -> String? {
        guard needsAlternateResultDirectory(mediaURL) else { return nil }
        return alternateResultDirectoryURL == nil
            ? String(localized: "앱 폴더에 저장됨")
            : String(localized: "지정한 결과 폴더에 저장됨")
    }

    /// 주의가 필요한 항목입니다. 실패·취소·일시정지된 영상이 여기 들어옵니다.
    var attentionItems: [Item] {
        items.filter { [.failed, .cancelled, .paused].contains($0.status) }
    }

    func readOnlyItemCount(in ids: Set<UUID>? = nil) -> Int {
        items.filter { item in
            (ids == nil || ids?.contains(item.id) == true) && needsAlternateResultDirectory(item.url)
        }.count
    }

    func chooseAlternateResultDirectory() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "읽기 전용 영상의 STT·번역 결과 저장 폴더")
        panel.prompt = String(localized: "이 폴더 사용")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        PanelLocationMemory.restore(into: panel, purpose: .batchResultDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        PanelLocationMemory.remember(url, purpose: .batchResultDirectory)
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        alternateResultDirectoryURL = url.standardizedFileURL
        alternateResultDirectoryBookmark = bookmark
        UserDefaults.standard.set(bookmark, forKey: "batchAlternateResultDirectoryBookmark")
    }

    func clearAlternateResultDirectory() {
        guard !isRunning else { return }
        alternateResultDirectoryURL = nil
        alternateResultDirectoryBookmark = nil
        UserDefaults.standard.removeObject(forKey: "batchAlternateResultDirectoryBookmark")
    }

    func revealAlternateResultDirectory() {
        guard let alternateResultDirectoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([alternateResultDirectoryURL])
    }

    private func needsAlternateResultDirectory(_ mediaURL: URL) -> Bool {
        if (try? mediaURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            return true
        }
        return !FileManager.default.isWritableFile(atPath: mediaURL.deletingLastPathComponent().path)
    }

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
        PanelLocationMemory.restore(into: panel, purpose: .batchFiles)
        guard panel.runModal() == .OK else { return }
        PanelLocationMemory.remember(first: panel.urls, purpose: .batchFiles)
        add(panel.urls)
    }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "하위 영상을 검색할 폴더를 선택하세요")
        panel.prompt = String(localized: "폴더 검색")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        PanelLocationMemory.restore(into: panel, purpose: .batchFolders)
        guard panel.runModal() == .OK else { return }
        PanelLocationMemory.remember(first: panel.urls, purpose: .batchFolders)
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
        if addedCount > 0 {
            rememberCurrentVideoList()
            refreshExistingResults()
        }
        return addedCount
    }

    /// 폴더 검색과 파일 추가로 만든 목록을 다음 앱 실행에서도 복원합니다.
    private func rememberCurrentVideoList() {
        let paths = items.map { $0.url.standardizedFileURL.path(percentEncoded: false) }
        UserDefaults.standard.set(paths, forKey: Self.rememberedVideoPathsKey)
        if isRunning { persistAutoResumeState() }
    }

    private func persistAutoResumeState() {
        guard automaticallyResumeOnLaunch else { return }
        let paths = items.compactMap { item -> String? in
            guard scheduledItemIDs.contains(item.id), !item.isFinished else { return nil }
            return item.url.standardizedFileURL.path(percentEncoded: false)
        }
        if paths.isEmpty {
            clearAutoResumeState()
        } else {
            UserDefaults.standard.set(paths, forKey: Self.autoResumePathsKey)
        }
    }

    private func clearAutoResumeState() {
        UserDefaults.standard.removeObject(forKey: Self.autoResumePathsKey)
    }

    private func resumePreviousRunIfNeeded() {
        guard automaticallyResumeOnLaunch, !pendingLaunchResumePaths.isEmpty else { return }
        let paths = pendingLaunchResumePaths
        pendingLaunchResumePaths.removeAll()
        let ids = Set(items.compactMap { item -> UUID? in
            let path = item.url.standardizedFileURL.path(percentEncoded: false)
            return paths.contains(path) && item.status != .completed ? item.id : nil
        })
        guard !ids.isEmpty else {
            clearAutoResumeState()
            return
        }
        folderScanMessage = String(localized: "이전 대량 번역 \(ids.count)개를 저장된 지점부터 자동 재개합니다.")
        start(ids: ids)
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
        rememberCurrentVideoList()
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        stop(ids: ids)
        items.removeAll { ids.contains($0.id) }
        rememberCurrentVideoList()
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
        rememberCurrentVideoList()
        return BatchTrashResult(movedCount: movedSet.count, failureMessage: outcome.1)
    }

    /// 파일명이 달라도 내용이 같은 영상 묶음입니다.
    struct ContentDuplicateGroup: Identifiable {
        let id: String
        let byteCount: Int64
        let items: [Item]
    }

    /// 내용이 같은 영상을 찾습니다. 크기가 같은 것만 추려 앞뒤 일부만 해시하므로
    /// 수 GB 파일도 전체를 읽지 않고 빠르게 판별합니다.
    func scanContentDuplicates() async {
        guard !isRunning, !isScanningContentDuplicates else { return }
        isScanningContentDuplicates = true
        contentDuplicateMessage = String(localized: "크기가 같은 영상을 추리는 중…")
        defer { isScanningContentDuplicates = false }

        let candidates = items.map { (id: $0.id, url: $0.url.standardizedFileURL) }
        let fingerprints = await Task.detached(priority: .userInitiated) { () -> [UUID: String] in
            let fileManager = FileManager.default
            // 1단계: 크기로 후보를 좁힙니다. 크기가 다르면 내용도 다릅니다.
            var sizes: [UUID: Int64] = [:]
            for candidate in candidates {
                guard let values = try? candidate.url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, let size = values.fileSize, size > 0 else { continue }
                sizes[candidate.id] = Int64(size)
            }
            let sharedSizes = Set(
                Dictionary(grouping: sizes, by: { $0.value }).filter { $0.value.count > 1 }.keys
            )
            guard !sharedSizes.isEmpty else { return [:] }

            // 2단계: 앞뒤 4MB만 해시해 같은 크기 안에서 내용을 비교합니다.
            let sampleLength = 4 * 1024 * 1024
            var result: [UUID: String] = [:]
            for candidate in candidates {
                guard let size = sizes[candidate.id], sharedSizes.contains(size) else { continue }
                guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { continue }
                defer { try? handle.close() }
                var hasher = Hasher()
                hasher.combine(size)
                if let head = try? handle.read(upToCount: sampleLength) { hasher.combine(head) }
                if size > Int64(sampleLength) * 2 {
                    try? handle.seek(toOffset: UInt64(size - Int64(sampleLength)))
                    if let tail = try? handle.read(upToCount: sampleLength) { hasher.combine(tail) }
                }
                result[candidate.id] = "\(size)-\(hasher.finalize())"
                _ = fileManager
            }
            return result
        }.value

        let grouped = Dictionary(grouping: items.filter { fingerprints[$0.id] != nil }) { fingerprints[$0.id]! }
        contentDuplicateGroups = grouped.compactMap { key, groupedItems in
            guard groupedItems.count > 1 else { return nil }
            let size = (try? groupedItems[0].url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            return ContentDuplicateGroup(
                id: key,
                byteCount: size,
                items: groupedItems.sorted { $0.url.path < $1.url.path }
            )
        }
        .sorted { $0.byteCount > $1.byteCount }

        let removable = contentDuplicateRemovalIDs.count
        contentDuplicateMessage = contentDuplicateGroups.isEmpty
            ? String(localized: "내용이 같은 영상을 찾지 못했습니다.")
            : String(localized: "중복 \(contentDuplicateGroups.count)묶음 · 정리 가능 \(removable)개")
    }

    /// 묶음마다 첫 항목만 남기고 나머지를 정리 대상으로 봅니다.
    var contentDuplicateRemovalIDs: Set<UUID> {
        Set(contentDuplicateGroups.flatMap { $0.items.dropFirst().map(\.id) })
    }

    var contentDuplicateReclaimableBytes: Int64 {
        contentDuplicateGroups.reduce(0) { $0 + $1.byteCount * Int64($1.items.count - 1) }
    }

    func duplicateNameCount(for itemID: UUID) -> Int {
        duplicateFilenameGroups.first(where: { group in group.items.contains { $0.id == itemID } })?.items.count ?? 0
    }

    func clearFinished() {
        guard !isRunning else { return }
        items.removeAll { $0.isFinished }
        rememberCurrentVideoList()
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

    /// 원격 서버를 다시 확인하고, 유휴 상태라면 내장 XPC 연결도 다음 요청에서 새로 만들도록 정리합니다.
    /// 실행 중인 로컬 추론 연결은 끊지 않아 진행 중인 결과를 보호합니다.
    @discardableResult
    func reconnectServers() async -> Int {
        await RemoteWorkerPool.shared.refreshAll()
        if !isRunning {
            connection?.invalidate()
            connection = nil
        }
        return RemoteWorkerPool.shared.availableWorkers.count
    }

    /// 실패한 대량 번역을 10분마다 확인하고, 원격 서버가 정상일 때 저장된 결과부터 다시 시도합니다.
    /// 서버가 계속 비정상이면 항목을 건드리지 않고 다음 주기까지 기다립니다.
    private func monitorRemoteFailures() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.remoteFailureRetryInterval)
            } catch {
                break
            }
            guard prefersRemoteWorkers else { continue }

            await RemoteWorkerPool.shared.refreshAll()
            guard !RemoteWorkerPool.shared.availableWorkers.isEmpty else { continue }

            let failedIDs = Set(items.lazy.filter { $0.status == .failed }.map(\.id))
            guard !failedIDs.isEmpty else { continue }

            folderScanMessage = String(
                localized: "원격 서버 연결 정상 · 실패한 대량 번역 \(failedIDs.count)개를 자동 재시도합니다."
            )
            start(ids: failedIDs)
        }
    }

    /// 완료된 항목의 화자 이름을 다시 분석합니다.
    /// 저장된 STT·번역은 그대로 두고 화자 분석 단계만 다시 실행하므로 빠릅니다.
    func reanalyzeSpeakers(ids: [UUID]) {
        guard !isRunning else { return }
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }), items[index].isFinished else { continue }
            speakerReanalysisItemIDs.insert(id)
            resetItemForRerun(at: index, message: String(localized: "화자 다시 분석 대기 중"))
        }
    }

    /// 저장된 STT·번역 결과를 지우고 처음부터 다시 처리합니다.
    /// 결과를 지우지 않으면 파이프라인이 저장된 청크를 건너뛰어 실제로 다시 하지 않습니다.
    func redoFromScratch(ids: [UUID]) {
        guard !isRunning else { return }
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            let url = items[index].url
            do {
                let paths = try AppPaths()
                let store = try JobStore(url: paths.database)
                let jobID = AppModel.stableJobID(
                    forPath: url.path,
                    sttModel: options.sttModel,
                    sourceLanguage: options.sourceLanguage ?? "",
                    chunkDuration: options.chunkDuration
                )
                try? store.deleteJob(jobID: jobID)
                try? MediaSidecarStore.deleteAllGeneratedResults(for: url)
                speakerReanalysisItemIDs.remove(id)
                resetItemForRerun(at: index, message: String(localized: "STT·번역 다시 하기 대기 중"))
            } catch {
                items[index].message = error.localizedDescription
            }
        }
    }

    private func resetItemForRerun(at index: Int, message: String) {
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
        items[index].sttCompleted = false
        items[index].existingResult = .notFound
        items[index].message = message
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
            self?.resumePreviousRunIfNeeded()
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
        // 읽기 전용 위치라도 막지 않습니다. 결과는 지정한 폴더나 앱 관리 폴더에 자동으로 저장됩니다.
        // 예전에는 여기서 조용히 반환해, 시작 버튼을 눌러도 아무 일도 일어나지 않았습니다.
        var eligible: Set<UUID> = []
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }), items[index].status != .completed else { continue }
            if [.failed, .cancelled].contains(items[index].status) {
                resetForRetry(at: index)
            }
            if items[index].status == .paused {
                items[index].status = .queued
                items[index].sttCompleted = false
        items[index].message = String(localized: "저장된 결과부터 다시 시작 대기 중")
            }
            guard !items[index].isProcessing else { continue }
            pausedItemIDs.remove(id)
            eligible.insert(id)
        }
        guard !eligible.isEmpty else { return }
        scheduledItemIDs.formUnion(eligible)
        persistAutoResumeState()
        guard !isRunning else { return }
        isRunning = true
        isPaused = false
        runTask = Task { [weak self] in
            // 앱이 강제 종료되면 추출 파일 정리가 실행되지 않아 수백 MB가 남습니다. 시작할 때 걷어냅니다.
            let reclaimed = RemoteAudioWorkspaceCleaner.removeOrphans()
                + RemoteAudioWorkspaceCleaner.removeStagedCopies()
            if reclaimed > 0 {
                await MainActor.run {
                    self?.folderScanMessage = String(
                        localized: "이전 작업이 남긴 오디오 \(ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file))를 정리했습니다."
                    )
                }
            }
            await RemoteWorkerPool.shared.refreshAll()
            await self?.runQueue()
        }
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        clearAutoResumeState()
        for index in items.indices where !items[index].isProcessing && scheduledItemIDs.contains(items[index].id) {
            items[index].message = String(localized: "일시 정지됨 · 계속하면 자동으로 시작합니다.")
        }
    }

    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        persistAutoResumeState()
        for index in items.indices where !items[index].isProcessing && scheduledItemIDs.contains(items[index].id) {
            items[index].message = String(localized: "재개 대기 중")
        }
    }

    func stop(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pausedItemIDs.subtract(ids)
        scheduledItemIDs.subtract(ids)
        persistAutoResumeState()
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

    func pause(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pausedItemIDs.formUnion(ids)
        scheduledItemIDs.subtract(ids)
        persistAutoResumeState()
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isFinished else { continue }
            if items[index].isProcessing {
                items[index].message = String(localized: "일시 정지 요청 중… 저장된 결과는 유지됩니다.")
                if let jobID = activeJobIDsByItem[id] {
                    service()?.cancelJob(jobID.uuidString) { _ in }
                }
            } else {
                items[index].status = .paused
                items[index].message = String(localized: "일시 정지됨 · 저장된 결과부터 재시작할 수 있습니다.")
            }
        }
    }

    func cancelAll() {
        isPaused = false
        runTask?.cancel()
        scheduledItemIDs.removeAll()
        clearAutoResumeState()
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
        items[index].sttCompleted = false
        items[index].message = String(localized: "저장된 결과부터 다시 시작 대기 중")
    }

    private func waitsForSTT(_ item: Item) -> Bool {
        scheduledItemIDs.contains(item.id) && !item.isFinished && !item.isProcessing && !item.sttCompleted
    }

    private func waitsForTranslation(_ item: Item) -> Bool {
        scheduledItemIDs.contains(item.id) && !item.isFinished && !item.isProcessing && item.sttCompleted
    }

    /// 재개 가능한 결과가 많이 쌓인 작업부터 마무리해 완료 항목을 빠르게 늘립니다.
    /// 같은 진행률이면 청크 수, 마지막에는 원래 목록 순서를 사용해 순서가 흔들리지 않게 합니다.
    private func nextWaitingIndex(for phase: JobPhase) -> Int? {
        if focusedTranslationMode {
            if let focusedItemID,
               let index = items.firstIndex(where: { $0.id == focusedItemID }),
               scheduledItemIDs.contains(focusedItemID),
               !items[index].isFinished {
                switch phase {
                case .stt: return waitsForSTT(items[index]) ? index : nil
                case .translation: return waitsForTranslation(items[index]) ? index : nil
                }
            }

            let candidates = items.indices.filter {
                scheduledItemIDs.contains(items[$0].id) && !items[$0].isFinished && !items[$0].isProcessing
            }
            let selected = candidates.max { lhs, rhs in
                if items[lhs].progress != items[rhs].progress { return items[lhs].progress < items[rhs].progress }
                if items[lhs].currentChunk != items[rhs].currentChunk {
                    return items[lhs].currentChunk < items[rhs].currentChunk
                }
                return lhs > rhs
            }
            guard let selected else { return nil }
            focusedItemID = items[selected].id
            switch phase {
            case .stt: return waitsForSTT(items[selected]) ? selected : nil
            case .translation: return waitsForTranslation(items[selected]) ? selected : nil
            }
        }

        let candidates = items.indices.filter { index in
            switch phase {
            case .stt: waitsForSTT(items[index])
            case .translation: waitsForTranslation(items[index])
            }
        }
        return candidates.max { lhs, rhs in
            let leftProgress: Double
            let rightProgress: Double
            switch phase {
            case .stt:
                leftProgress = items[lhs].sttProgress
                rightProgress = items[rhs].sttProgress
            case .translation:
                leftProgress = items[lhs].translationProgress
                rightProgress = items[rhs].translationProgress
            }
            if leftProgress != rightProgress { return leftProgress < rightProgress }
            if items[lhs].currentChunk != items[rhs].currentChunk {
                return items[lhs].currentChunk < items[rhs].currentChunk
            }
            return lhs > rhs
        }
    }

    /// VideoLingoAIService 프로세스만 표본화해 다른 앱의 빌드나 렌더링 부하가
    /// 대량 번역의 로컬 큐를 불필요하게 막지 않도록 합니다.
    private func measuredLocalServiceCPUUsage() -> Double {
        var pids = [pid_t](repeating: 0, count: 4_096)
        let byteCount = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard byteCount > 0 else { return 0 }

        var totalNanoseconds: UInt64 = 0
        for pid in pids.prefix(Int(byteCount) / MemoryLayout<pid_t>.size) {
            var name = [CChar](repeating: 0, count: 128)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            let isLocalService = name.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return false }
                return strcmp(baseAddress, "VideoLingoAIService") == 0
            }
            guard isLocalService else { continue }
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            if result == 0 {
                totalNanoseconds &+= usage.ri_user_time &+ usage.ri_system_time
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        defer { localServiceCPUSample = (now, totalNanoseconds) }
        guard let previous = localServiceCPUSample,
              now > previous.uptime,
              totalNanoseconds >= previous.cpuNanoseconds else { return 0 }
        let elapsed = now - previous.uptime
        let consumed = Double(totalNanoseconds - previous.cpuNanoseconds) / 1_000_000_000
        return min(1_000, max(0, consumed / elapsed * 100))
    }

    private var localConcurrencyLimit: Int {
        let configured = automaticallyAdjustConcurrentJobs
            ? recommendedConcurrentJobs
            : max(maximumConcurrentSTTJobs, maximumConcurrentJobs)
        return max(1, Int((Double(configured) * Double(localCPUUsageLimit) / 100).rounded(.down)))
    }

    /// 이미 실행 중인 로컬 추론은 끊지 않고, CPU와 로컬 슬롯에 여유가 생길 때만 새 작업을 시작합니다.
    private func acquireLocalExecutionSlot(for phase: JobPhase, itemID: UUID) async throws {
        while !Task.isCancelled {
            let activeLocalJobs = activeLocalSTTJobs + activeLocalTranslationJobs
            let cpuUsage = measuredLocalServiceCPUUsage()
            if activeLocalJobs < localConcurrencyLimit, cpuUsage < Double(localCPUUsageLimit) {
                switch phase {
                case .stt: activeLocalSTTJobs += 1
                case .translation: activeLocalTranslationJobs += 1
                }
                return
            }
            if let index = items.firstIndex(where: { $0.id == itemID }) {
                items[index].message = String(
                    localized: "내장 서버 시작 대기 · CPU \(Int(cpuUsage.rounded()))% (상한 \(localCPUUsageLimit)%)"
                )
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw CancellationError()
    }

    private func releaseLocalExecutionSlot(for phase: JobPhase) {
        switch phase {
        case .stt: activeLocalSTTJobs = max(0, activeLocalSTTJobs - 1)
        case .translation: activeLocalTranslationJobs = max(0, activeLocalTranslationJobs - 1)
        }
    }

    /// 영상 길이와 32kbps 정규화 오디오 크기, 최근 서버 왕복 시간, 로컬 실측 속도를
    /// 같은 '예상 완료 시간' 단위로 바꿔 더 빨리 끝날 STT 경로를 고릅니다.
    private func sttRoutingDecision(for mediaURL: URL) async -> STTRoutingDecision {
        let duration = (try? await AVURLAsset(url: mediaURL).load(.duration).seconds) ?? 0
        guard duration.isFinite, duration > 0 else {
            return STTRoutingDecision(useRemote: prefersRemoteWorkers, audioDuration: 0, summary: String(localized: "STT 경로 계산 정보 부족"))
        }

        let localProcessing = duration / localSTTRealtimeFactor
        let localQueue = Double(activeLocalSTTJobs) / Double(max(1, localConcurrencyLimit)) * localProcessing
        let localTotal = localProcessing + localQueue
        let estimatedBytes = Int64((duration * 32_000 / 8).rounded(.up))
        let pool = RemoteWorkerPool.shared
        let candidates = pool.availableWorkers.filter { $0.1.capabilities.sttSlots > 0 }
        guard (prefersRemoteWorkers || focusedTranslationMode), !candidates.isEmpty else {
            return STTRoutingDecision(
                useRemote: false,
                audioDuration: duration,
                summary: String(localized: "STT 경로 · 내장 서버 예상 (formattedEstimate(localTotal)) · 사용 가능한 원격 없음")
            )
        }

        let best = candidates.map { worker, status -> (name: String, total: TimeInterval, transfer: TimeInterval) in
            let version = status.version.lowercased()
            let fallbackFactor: Double
            if version.contains("metal") { fallbackFactor = 12 }
            else if version.contains("cuda") || version.contains("gpu") { fallbackFactor = 10 }
            else if version.contains("cpu") { fallbackFactor = 1 }
            else { fallbackFactor = 3 }
            let estimate = RemoteServerMetrics.shared.estimatedSTTDuration(
                workerID: worker.id,
                audioDuration: duration,
                uploadBytes: estimatedBytes,
                fallbackRealtimeFactor: fallbackFactor,
                slots: status.capabilities.sttSlots
            )
            // 아직 전송을 시작하지 않은 예약도 원격 대기 시간에 포함합니다.
            let reservedAhead = max(0, pool.remoteSTTReservationCount - pool.totalSTTSlots)
            let reservationWait = Double(reservedAhead) / Double(max(1, pool.totalSTTSlots)) * estimate.total
            return (status.name, estimate.total + reservationWait, estimate.transferAndWait + reservationWait)
        }.min { $0.total < $1.total }

        guard let best else {
            return STTRoutingDecision(useRemote: false, audioDuration: duration, summary: String(localized: "STT 경로 · 내장 서버 선택"))
        }
        // 예측 오차 때문에 거의 같은 경우에는 사용자가 설정한 원격 우선 정책을 존중합니다.
        // 집중 모드는 처리량보다 한 영상의 빠른 완료가 목적이므로 연결된 STTLMM 서버를 먼저 씁니다.
        let useRemote = focusedTranslationMode || best.total <= localTotal * 1.1
        let route = useRemote ? String(localized: "원격 \(best.name)") : String(localized: "내장 서버")
        return STTRoutingDecision(
            useRemote: useRemote,
            audioDuration: duration,
            summary: String(
                localized: "STT 경로 계산 · 원격 \(formattedEstimate(best.total)) (전송·대기 \(formattedEstimate(best.transfer))) / 내장 \(formattedEstimate(localTotal)) → \(route)"
            )
        )
    }

    private func recordLocalSTTPerformance(audioDuration: TimeInterval, elapsed: TimeInterval) {
        guard audioDuration > 0, elapsed > 0.1 else { return }
        let measured = min(50, max(0.25, audioDuration / elapsed))
        let updated = localSTTRealtimeFactor * 0.7 + measured * 0.3
        UserDefaults.standard.set(updated, forKey: "batchLocalSTTRealtimeFactor")
    }

    private func formattedEstimate(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        if value < 60 { return String(localized: "(Int(value.rounded()))초") }
        return String(localized: "(Int((value / 60).rounded()))분")
    }

    private func runQueue() async {
        await withTaskGroup(of: JobPhase.self) { group in
            var sttActive = 0
            var translationActive = 0
            while !Task.isCancelled {
                // STT 레인: 번역이 밀려 있어도 다음 영상들의 STT를 계속 진행합니다.
                while !isPaused,
                      sttActive < effectiveSTTConcurrentJobs,
                      let index = nextWaitingIndex(for: .stt) {
                    let itemID = items[index].id
                    items[index].isProcessing = true
                    if group.addTaskUnlessCancelled(operation: { [weak self] in
                        await self?.process(itemID, phase: .stt)
                        return .stt
                    }) {
                        sttActive += 1
                    } else {
                        items[index].isProcessing = false
                        break
                    }
                }
                // 번역 레인: STT가 끝난 영상만 순서대로 처리합니다.
                while !isPaused,
                      translationActive < effectiveConcurrentJobs,
                      let index = nextWaitingIndex(for: .translation) {
                    let itemID = items[index].id
                    items[index].isProcessing = true
                    if group.addTaskUnlessCancelled(operation: { [weak self] in
                        await self?.process(itemID, phase: .translation)
                        return .translation
                    }) {
                        translationActive += 1
                    } else {
                        items[index].isProcessing = false
                        break
                    }
                }
                let activeTasks = sttActive + translationActive
                if isPaused {
                    let hasWaitingWork = items.contains {
                        scheduledItemIDs.contains($0.id) && !$0.isFinished && !$0.isProcessing
                    }
                    if activeTasks == 0 && !hasWaitingWork { break }
                    if activeTasks == 0 {
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                }
                guard activeTasks > 0 else { break }
                switch await group.next() {
                case .stt: sttActive -= 1
                case .translation: translationActive -= 1
                case nil: sttActive = 0; translationActive = 0
                }
            }
            group.cancelAll()
        }
        for index in items.indices where items[index].isProcessing {
            items[index].isProcessing = false
            if !items[index].isFinished { items[index].status = .cancelled }
        }
        activeJobIDsByItem.removeAll()
        scheduledItemIDs.removeAll()
        focusedItemID = nil
        clearAutoResumeState()
        isRunning = false
        isPaused = false
        runTask = nil
    }

    private func process(_ itemID: UUID, phase: JobPhase) async {
        guard let initialIndex = items.firstIndex(where: { $0.id == itemID }) else { return }
        defer {
            activeJobIDsByItem.removeValue(forKey: itemID)
            if let index = items.firstIndex(where: { $0.id == itemID }) {
                items[index].isProcessing = false
                // STT만 끝난 항목은 번역 레인이 이어받아야 하므로 예약을 유지합니다.
                let waitsForTranslationLane = phase == .stt && items[index].sttCompleted && !items[index].isFinished
                if !waitsForTranslationLane { scheduledItemIDs.remove(itemID) }
            } else {
                scheduledItemIDs.remove(itemID)
            }
        }
        let url = items[initialIndex].url
        do {
            var sttDecision: STTRoutingDecision?
            var localSTTStartedAt: Date?
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
            let needsAlternateDirectory = needsAlternateResultDirectory(url)
            // 화자 다시 분석 요청은 이번 실행에서만 적용하고 바로 소비합니다.
            var itemOptions = options
            if speakerReanalysisItemIDs.remove(itemID) != nil {
                itemOptions.forceSpeakerReanalysis = true
            }
            if phase == .stt {
                // 번역 대상 언어를 비우면 파이프라인이 번역 단계를 건너뛰고 STT만 수행합니다.
                // 품질 개선도 번역까지 끝난 뒤에 하는 편이 낭비가 없습니다.
                itemOptions.targetLanguages = []
                itemOptions.continuousImprovement = false
            }

            // STT는 오디오 청크만, 번역은 텍스트만 보내므로 두 레인 모두 원격을 쓸 수 있습니다.
            // 자리가 없거나 실패하면 기존 내장 서버 흐름으로 자동 전환합니다.
            let stage = phase == .stt ? String(localized: "STT") : String(localized: "번역")
            var lastRemoteFailure: String?
            switch phase {
            case .stt:
                let decision = await sttRoutingDecision(for: url)
                sttDecision = decision
                if let index = items.firstIndex(where: { $0.id == itemID }) {
                    items[index].message = decision.summary
                }
                let queueMultiplier = (prefersRemoteWorkers || focusedTranslationMode) ? remoteRequestMultiplier : 1
                if decision.useRemote,
                   RemoteWorkerPool.shared.reserveRemoteSTT(queueMultiplier: queueMultiplier) {
                    defer { RemoteWorkerPool.shared.releaseRemoteSTTReservation() }
                    do {
                        try await transcribeRemotely(itemID: itemID, jobID: jobID, mediaURL: url)
                        return
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastRemoteFailure = error.localizedDescription
                    }
                }
            case .translation:
                var triedWorkers: Set<UUID> = []
                while let worker = await acquireRemoteWorker(for: .translation, excluding: triedWorkers) {
                    triedWorkers.insert(worker.id)
                    defer { RemoteWorkerPool.shared.release(worker.id, purpose: .translation) }
                    do {
                        try await translateRemotely(itemID: itemID, jobID: jobID, mediaURL: url, worker: worker)
                        return
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if isRemoteTimeout(error) {
                            RemoteWorkerPool.shared.quarantine(worker.id)
                        }
                        lastRemoteFailure = "\(worker.name): \(error.localizedDescription)"
                        if let index = items.firstIndex(where: { $0.id == itemID }) {
                            items[index].message = String(localized: "\(worker.name) 원격 \(stage) 실패 · 다른 서버 확인 중")
                        }
                    }
                }
            }
            if let lastRemoteFailure, let index = items.firstIndex(where: { $0.id == itemID }) {
                items[index].message = String(localized: "원격 \(stage) 실패 · 내장 서버로 전환: \(lastRemoteFailure)")
            }

            try await acquireLocalExecutionSlot(for: phase, itemID: itemID)
            defer { releaseLocalExecutionSlot(for: phase) }
            if phase == .stt { localSTTStartedAt = .now }
            guard service() != nil else {
                throw NSError(domain: "VideoLingo.BatchProcessor", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "내장 AI 서버와 원격 Worker 모두 사용할 수 없습니다.")])
            }
            let request = StartJobRequest(
                jobID: jobID,
                mediaURL: url,
                securityScopedBookmark: bookmark,
                options: itemOptions,
                databaseURL: paths.database,
                workspaceURL: workspace,
                alternateResultDirectoryURL: needsAlternateDirectory ? alternateResultDirectoryURL : nil,
                alternateResultDirectoryBookmark: needsAlternateDirectory ? alternateResultDirectoryBookmark : nil
            )
            try JobStore(url: paths.database).createJob(id: jobID, mediaURL: url, options: itemOptions)
            items[requestIndex].status = .queued
            items[requestIndex].message = String(localized: "AI 서비스에 작업 전달 중")

            let payload = try WireCodec.encode(request)
            var service = try await sendWithRecovery(payload: payload, itemID: itemID)
            var consecutiveMissingSnapshots = 0
            var recoveryAttempts = 0
            var lastProgressUptime = ProcessInfo.processInfo.systemUptime
            var lastObservedProgress = -1.0
            var lastObservedChunk = -1
            var lastObservedStatus: JobStatus?
            var lastObservedTextLength = 0

            while !Task.isCancelled {
                // 고빈도 실시간 갱신은 재설계 전까지 중단하고 저빈도 상태 확인만 유지합니다.
                try await Task.sleep(for: Self.snapshotPollingInterval)
                guard let snapshot = await snapshot(service, jobID: jobID) else {
                    consecutiveMissingSnapshots += 1
                    guard consecutiveMissingSnapshots >= Self.missingSnapshotRecoveryThreshold else { continue }

                    recoveryAttempts += 1
                    guard recoveryAttempts <= Self.maximumServiceRecoveryAttempts else {
                        throw NSError(
                            domain: "VideoLingo.BatchProcessor",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: String(localized: "AI 서비스 응답이 없어 자동 복구에 실패했습니다. 저장된 결과에서 다시 시작할 수 있습니다.")]
                        )
                    }
                    if let index = items.firstIndex(where: { $0.id == itemID }) {
                        items[index].message = String(localized: "AI 서비스 연결 복구 중… ((recoveryAttempts)/(Self.maximumServiceRecoveryAttempts))")
                    }
                    try await Task.sleep(for: recoveryDelay(for: recoveryAttempts))
                    service = try await sendWithRecovery(payload: payload, itemID: itemID)
                    consecutiveMissingSnapshots = 0
                    continue
                }
                consecutiveMissingSnapshots = 0
                guard let index = items.firstIndex(where: { $0.id == itemID }) else {
                    service.cancelJob(jobID.uuidString) { _ in }
                    break
                }
                let observedProgress = phase == .stt ? snapshot.sttProgress : snapshot.translationProgress
                let observedTextLength = (snapshot.liveTranscriptText?.count ?? 0)
                    + (snapshot.liveTranslationText?.count ?? 0)
                    + (snapshot.lastTranscriptText?.count ?? 0)
                    + (snapshot.lastTranslationText?.count ?? 0)
                let madeProgress = observedProgress > lastObservedProgress + 0.0001
                    || snapshot.currentChunk != lastObservedChunk
                    || snapshot.status != lastObservedStatus
                    || observedTextLength != lastObservedTextLength
                if madeProgress {
                    lastProgressUptime = ProcessInfo.processInfo.systemUptime
                    lastObservedProgress = observedProgress
                    lastObservedChunk = snapshot.currentChunk
                    lastObservedStatus = snapshot.status
                    lastObservedTextLength = observedTextLength
                } else {
                    let stalledFor = ProcessInfo.processInfo.systemUptime - lastProgressUptime
                    if stalledFor >= Self.stalledProgressRecoveryInterval {
                        recoveryAttempts += 1
                        guard recoveryAttempts <= Self.maximumServiceRecoveryAttempts else {
                            throw NSError(
                                domain: "VideoLingo.BatchProcessor.Watchdog",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: String(localized: "진행이 장시간 멈춰 자동 복구를 완료하지 못했습니다. 저장된 결과에서 다시 시도할 수 있습니다.")]
                            )
                        }
                        items[index].message = String(localized: "\(stage) 정체 감지 · 서버 자동 재연결 중 (\(recoveryAttempts)/\(Self.maximumServiceRecoveryAttempts))")
                        await cancelJob(service, jobID: jobID)
                        connection?.invalidate()
                        connection = nil
                        try await Task.sleep(for: recoveryDelay(for: recoveryAttempts))
                        service = try await sendWithRecovery(payload: payload, itemID: itemID)
                        lastProgressUptime = ProcessInfo.processInfo.systemUptime
                        consecutiveMissingSnapshots = 0
                        continue
                    } else if stalledFor >= Self.slowProgressWarningInterval {
                        items[index].message = String(localized: "\(stage) 진행이 느림 · 자동 복구 감시 중 (\(Int(stalledFor))초)")
                    }
                }
                items[index].sttProgress = snapshot.sttProgress
                items[index].currentChunk = snapshot.currentChunk
                items[index].totalChunks = snapshot.totalChunks
                items[index].liveTranscriptText = snapshot.liveTranscriptText
                items[index].lastTranscriptText = snapshot.lastTranscriptText
                if phase == .translation {
                    // STT 단계는 번역 대상을 비워 보내므로 번역 진행률이 1로 보고됩니다. 그대로 쓰면 안 됩니다.
                    items[index].translationProgress = snapshot.translationProgress
                    items[index].liveTranslationText = snapshot.liveTranslationText
                    items[index].lastTranslationText = snapshot.lastTranslationText
                }
                items[index].progress = (items[index].sttProgress + items[index].translationProgress) / 2
                items[index].status = snapshot.status
                items[index].message = snapshot.message
                if pausedItemIDs.contains(itemID), snapshot.status == .cancelled {
                    items[index].status = .paused
                    items[index].message = String(localized: "일시 정지됨 · 저장된 결과부터 재시작할 수 있습니다.")
                    break
                }
                if phase == .stt {
                    if [.failed, .cancelled].contains(snapshot.status) { break }
                    // 같은 jobID를 번역 단계에서 다시 쓰므로, 작업이 완전히 끝난 뒤에 넘겨야 합니다.
                    // 끝나기 전에 보내면 XPC가 '이미 실행 중'으로 판단해 번역 요청을 버립니다.
                    guard snapshot.status == .completed else { continue }
                    items[index].sttCompleted = true
                    if let started = localSTTStartedAt, let decision = sttDecision {
                        recordLocalSTTPerformance(
                            audioDuration: decision.audioDuration,
                            elapsed: Date.now.timeIntervalSince(started)
                        )
                    }
                    if options.targetLanguages.isEmpty {
                        items[index].status = .completed
                        items[index].progress = 1
                        items[index].message = String(localized: "STT 완료")
                        items[index].existingResult = .complete(languages: [])
                    } else {
                        // 번역 레인이 이어받도록 대기 상태로 돌려놓습니다.
                        items[index].status = .queued
                        items[index].message = String(localized: "STT 완료 · 번역 대기 중")
                        // 서비스가 끝난 작업을 정리할 틈을 줍니다.
                        try? await Task.sleep(for: .milliseconds(600))
                    }
                    break
                }
                if snapshot.status == .refining {
                    // 품질 개선 단계는 결과가 이미 나온 상태이므로 배치에서는 완료로 간주하고 다음 파일로 넘어갑니다.
                    items[index].status = .completed
                    items[index].progress = 1
                    items[index].message = [
                        String(localized: "STT·번역 완료 · 품질 개선은 백그라운드에서 계속됩니다."),
                        resultLocationNote(for: url)
                    ].compactMap { $0 }.joined(separator: " · ")
                    items[index].existingResult = .complete(languages: options.targetLanguages)
                    break
                }
                if snapshot.status == .completed {
                    items[index].existingResult = .complete(languages: options.targetLanguages)
                    if let note = resultLocationNote(for: url) {
                        items[index].message = "\(snapshot.message) · \(note)"
                    }
                }
                if [.completed, .failed, .cancelled].contains(snapshot.status) { break }
            }
            if Task.isCancelled,
               let index = items.firstIndex(where: { $0.id == itemID }),
               !items[index].isFinished {
                if pausedItemIDs.contains(itemID) {
                    items[index].status = .paused
                    items[index].message = String(localized: "일시 정지됨 · 저장된 결과부터 재시작할 수 있습니다.")
                } else {
                    items[index].status = .cancelled
                    items[index].message = String(localized: "대량 번역을 중단했습니다. 저장된 결과에서 재개할 수 있습니다.")
                }
            }
        } catch {
            if let index = items.firstIndex(where: { $0.id == itemID }) {
                if pausedItemIDs.contains(itemID) {
                    items[index].status = .paused
                    items[index].message = String(localized: "일시 정지됨 · 저장된 결과부터 재시작할 수 있습니다.")
                } else {
                    items[index].status = .failed
                    items[index].message = error.localizedDescription
                }
            }
        }
    }

    private func acquireRemoteWorker(
        for purpose: RemoteWorkerPool.Purpose,
        excluding excluded: Set<UUID>
    ) async -> RemoteWorkerConfiguration? {
        if prefersRemoteWorkers || focusedTranslationMode {
            return await RemoteWorkerPool.shared.acquireWaiting(
                for: purpose,
                excluding: excluded,
                timeout: .seconds(20)
            )
        }
        return RemoteWorkerPool.shared.acquire(for: purpose, excluding: excluded)
    }

    private func isRemoteTimeout(_ error: Error) -> Bool {
        if let remoteError = error as? RemoteWorkerClientError, remoteError.isTimeout { return true }
        if let urlError = error as? URLError, urlError.code == .timedOut { return true }
        return (error as NSError).code == NSURLErrorTimedOut
    }

    /// 영상에서 오디오 청크를 뽑아 하나씩 원격 서버에서 인식합니다.
    /// 원본을 통째로 올리지 않으므로 서버 업로드 한도와 무관하고, 이미 저장된 청크는 건너뜁니다.
    private func transcribeRemotely(itemID: UUID, jobID: UUID, mediaURL: URL) async throws {
        let paths = try AppPaths()
        let store = try JobStore(url: paths.database)
        try store.createJob(id: jobID, mediaURL: mediaURL, options: options)
        guard var snapshot = try store.snapshot(jobID: jobID) else { return }

        let asset = AVURLAsset(url: mediaURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw VideoLingoError.mediaHasNoAudio }
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw VideoLingoError.mediaHasNoAudio
        }
        let chunkDuration = max(10, options.chunkDuration)
        let total = max(1, Int(ceil(duration / chunkDuration)))

        // 이미 저장된 청크는 다시 인식하지 않습니다.
        var produced = Dictionary(
            uniqueKeysWithValues: try store.transcript(jobID: jobID).map { ($0.chunkIndex, $0) }
        )
        let sidecar = try MediaSidecarStore(
            mediaURL: mediaURL,
            jobID: jobID,
            sttModel: options.sttModel,
            sourceLanguage: options.sourceLanguage,
            alternateRootURL: needsAlternateResultDirectory(mediaURL) ? alternateResultDirectoryURL : nil
        )
        // 이미 전부 저장돼 있으면 다시 보내지 않습니다.
        guard produced.count < total else {
            if let index = items.firstIndex(where: { $0.id == itemID }) {
                items[index].sttCompleted = true
                items[index].sttProgress = 1
                items[index].status = .queued
                items[index].message = String(localized: "저장된 STT 사용 · 번역 대기 중")
            }
            return
        }

        let workspace = paths.workspace(for: jobID).appending(path: "RemoteAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // 서버는 파일 하나를 통으로 처리할 때 가장 빠릅니다(실측 65배속).
        // 다만 3시간을 넘는 오디오는 요청 정체와 시간 초과를 줄이기 위해 정확히 반으로 나눕니다.
        //
        // 추출은 로컬 CPU 작업이고 수 분이 걸립니다. 원격 슬롯을 잡은 채로 추출하면
        // 그동안 서버가 유휴로 남고 Mac만 과부하가 되므로, 슬롯 밖에서 별도 제한으로 처리합니다.
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index].status = .extracting
            items[index].totalChunks = total
            items[index].message = String(localized: "오디오 추출 대기 중")
        }
        let maximumSingleAudioDuration: TimeInterval = 3 * 60 * 60
        let shouldSplitAudio = duration > maximumSingleAudioDuration
        let splitPoint = duration / 2
        let audioParts: [(url: URL, start: TimeInterval, duration: TimeInterval)] = shouldSplitAudio
            ? [
                (workspace.appending(path: "audio-1-of-2.m4a"), 0, splitPoint),
                (workspace.appending(path: "audio-2-of-2.m4a"), splitPoint, duration - splitPoint)
            ]
            : [(workspace.appending(path: "audio.m4a"), 0, duration)]
        // 외장 디스크에서는 동시에 하나만 직접 읽고, 나머지는 SSD로 순차 복사한 뒤 처리합니다.
        // 디코딩 읽기는 랜덤 액세스가 섞여 느리지만 복사는 순차라 훨씬 빠릅니다(실측).
        let staging = paths.workspace(for: jobID).appending(path: "Staging", directoryHint: .isDirectory)
        let prepared = try await ExternalMediaStager.shared.prepare(
            mediaURL: mediaURL,
            stagingDirectory: staging
        ) { [weak self] in
            Task { @MainActor in
                guard let self, let index = self.items.firstIndex(where: { $0.id == itemID }) else { return }
                self.items[index].message = String(localized: "내장 SSD로 복사 중")
            }
        }
        defer {
            let finished = prepared
            Task { await ExternalMediaStager.shared.finish(finished) }
        }
        let sourceAsset = prepared.didCopy ? AVURLAsset(url: prepared.url) : asset

        try await AudioExtractionLimiter.shared.withSlot {
            await MainActor.run {
                if let index = self.items.firstIndex(where: { $0.id == itemID }) {
                    self.items[index].message = prepared.didCopy
                        ? String(localized: "오디오 추출 중 (SSD)")
                        : String(localized: "오디오 추출 중")
                }
            }
            // 원본 오디오를 그대로 옮기지 않고 16kHz 모노로 다시 인코딩합니다.
            // 손상된 AAC 프레임이 서버 디코딩을 깨뜨리는 것을 막고 전송량도 크게 줄입니다.
            for (partIndex, part) in audioParts.enumerated() {
                if shouldSplitAudio {
                    await MainActor.run {
                        if let index = self.items.firstIndex(where: { $0.id == itemID }) {
                            self.items[index].message = String(localized: "3시간 초과 · 오디오 분할 추출 \(partIndex + 1)/2")
                        }
                    }
                }
                try await NormalizedAudioExporter.export(
                    asset: sourceAsset,
                    start: part.start,
                    duration: part.duration,
                    to: part.url
                )
            }
        }

        // 추출이 끝난 뒤에야 원격 자리를 잡습니다. 자리가 없거나 모두 실패하면 내장 서버로 넘어갑니다.
        var triedWorkers: Set<UUID> = []
        var response: RemoteWorkerClient.STTResponse?
        var lastFailure: Error?
        while let worker = await acquireRemoteWorker(for: .stt, excluding: triedWorkers) {
            triedWorkers.insert(worker.id)
            defer { RemoteWorkerPool.shared.release(worker.id, purpose: .stt) }
            if let index = items.firstIndex(where: { $0.id == itemID }) {
                items[index].status = .transcribing
                items[index].message = String(localized: "\(worker.name)에 오디오 전송 중")
            }
            do {
                var combinedSegments: [RemoteWorkerClient.STTSegment] = []
                var detectedLanguage: String?
                var processingSeconds: Double = 0
                var realtimeFactorWeightedSum: Double = 0
                var realtimeFactorDuration: Double = 0
                for (partIndex, part) in audioParts.enumerated() {
                    try Task.checkCancellation()
                    let partResponse = try await RemoteWorkerClient(worker: worker).transcribeAudio(
                        audioURL: part.url,
                        language: options.sourceLanguage,
                        usesChunkedUpload: usesChunkedAudioUpload,
                        splitThresholdBytes: chunkedAudioThresholdMB * 1_024 * 1_024
                    ) { [weak self] note in
                        Task { @MainActor in
                            guard let self, let index = self.items.firstIndex(where: { $0.id == itemID }) else { return }
                            let partNote = shouldSplitAudio ? "오디오 \(partIndex + 1)/2 · " : ""
                            self.items[index].message = "\(worker.name) · \(partNote)\(note)"
                        }
                    }
                    detectedLanguage = detectedLanguage ?? partResponse.language
                    processingSeconds += partResponse.processingSeconds ?? 0
                    if let factor = partResponse.realtimeFactor {
                        realtimeFactorWeightedSum += factor * part.duration
                        realtimeFactorDuration += part.duration
                    }
                    combinedSegments += (partResponse.segments ?? []).map { segment in
                        RemoteWorkerClient.STTSegment(
                            start: segment.start + part.start,
                            end: segment.end + part.start,
                            text: segment.text,
                            avgLogprob: segment.avgLogprob
                        )
                    }
                }
                response = RemoteWorkerClient.STTResponse(
                    language: detectedLanguage,
                    segments: combinedSegments,
                    duration: duration,
                    processingSeconds: processingSeconds > 0 ? processingSeconds : nil,
                    realtimeFactor: realtimeFactorDuration > 0
                        ? realtimeFactorWeightedSum / realtimeFactorDuration
                        : nil
                )
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if isRemoteTimeout(error) {
                    RemoteWorkerPool.shared.quarantine(worker.id)
                }
                lastFailure = error
                if let index = items.firstIndex(where: { $0.id == itemID }) {
                    items[index].message = isRemoteTimeout(error)
                        ? String(localized: "\(worker.name) 시간 초과 · 10분 격리 후 다른 서버 확인 중")
                        : String(localized: "\(worker.name) 전사 실패 · 다른 서버 확인 중")
                }
            }
        }
        guard let response else {
            throw lastFailure ?? RemoteWorkerClientError.failed(
                String(localized: "사용 가능한 원격 서버가 없습니다.")
            )
        }
        for part in audioParts {
            try? FileManager.default.removeItem(at: part.url)
        }

        // 서버는 영상 전체 기준 타임스탬프를 주므로, 앱의 청크 모델에 맞게 시간대로 나눠 담습니다.
        let serverSegments = (response.segments ?? []).sorted { $0.start < $1.start }
        guard !serverSegments.isEmpty else {
            throw RemoteWorkerClientError.failed(String(localized: "원격 서버가 자막 세그먼트를 반환하지 않았습니다."))
        }
        var cuesByChunk: [Int: [TranscriptCue]] = [:]
        var confidencesByChunk: [Int: [Double]] = [:]
        for segment in serverSegments {
            let index = min(total - 1, max(0, Int(segment.start / chunkDuration)))
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cuesByChunk[index, default: []].append(
                TranscriptCue(startTime: segment.start, endTime: segment.end, text: text)
            )
            if let logprob = segment.avgLogprob {
                confidencesByChunk[index, default: []].append(min(1, max(0, exp(logprob))))
            }
        }

        for index in 0..<total where produced[index] == nil {
            let cues = cuesByChunk[index] ?? []
            guard !cues.isEmpty else { continue }
            let start = Double(index) * chunkDuration
            let confidences = confidencesByChunk[index] ?? []
            let transcript = TranscriptSegment(
                jobID: jobID,
                chunkIndex: index,
                startTime: start,
                endTime: min(duration, start + chunkDuration),
                text: cues.map(\.text).joined(separator: "\n"),
                language: response.language ?? options.sourceLanguage,
                confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
                cues: cues,
                qualityStatus: .good,
                retryCount: 0,
                qualityNotes: []
            )
            try store.saveTranscript(transcript, snapshot: snapshot)
            produced[index] = transcript
        }
        try sidecar.saveTranscripts(produced.values.sorted { $0.chunkIndex < $1.chunkIndex })

        if let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index].currentChunk = total
            items[index].lastTranscriptText = produced[produced.keys.max() ?? 0]?.text
        }

        snapshot.status = .transcribing
        snapshot.sttProgress = 1
        snapshot.totalChunks = total
        snapshot.currentChunk = total
        snapshot.error = nil
        snapshot.updatedAt = .now
        try store.save(snapshot: snapshot)

        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].sttCompleted = true
        items[index].sttProgress = 1
        items[index].status = .queued
        items[index].message = String(localized: "원격 STT 완료 · 번역 대기 중")
    }

    /// STT는 로컬에서 끝내고 번역만 원격 서버에 맡깁니다.
    /// 텍스트만 주고받으므로 서버의 업로드 용량 한도(기본 200MB)와 무관합니다.
    private func translateRemotely(itemID: UUID, jobID: UUID, mediaURL: URL, worker: RemoteWorkerConfiguration) async throws {
        let paths = try AppPaths()
        let store = try JobStore(url: paths.database)
        let transcripts = try store.transcript(jobID: jobID).sorted { $0.chunkIndex < $1.chunkIndex }
        guard !transcripts.isEmpty else {
            throw NSError(
                domain: "VideoLingo.BatchProcessor",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "원격 번역에 사용할 STT 결과가 없습니다.")]
            )
        }
        guard var snapshot = try store.snapshot(jobID: jobID) else { return }
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index].status = .translating
            items[index].sttProgress = 1
            items[index].message = String(localized: "\(worker.name)에서 번역 중")
        }

        let client = RemoteWorkerClient(worker: worker)
        let sidecar = try MediaSidecarStore(
            mediaURL: mediaURL,
            jobID: jobID,
            sttModel: options.sttModel,
            sourceLanguage: options.sourceLanguage,
            alternateRootURL: needsAlternateResultDirectory(mediaURL) ? alternateResultDirectoryURL : nil
        )
        let languages = options.targetLanguages
        for (languageIndex, language) in languages.enumerated() {
            let translatedTexts = try await client.translateOnly(
                texts: transcripts.map(\.text),
                sourceLanguage: options.sourceLanguage,
                targetLanguage: language,
                options: options
            )
            guard translatedTexts.count == transcripts.count else {
                throw RemoteWorkerClientError.failed(
                    String(localized: "원격 서버가 \(transcripts.count)개 중 \(translatedTexts.count)개만 번역했습니다.")
                )
            }
            let segments = zip(transcripts, translatedTexts).map { transcript, text in
                TranslationSegment(
                    transcriptID: transcript.id,
                    jobID: jobID,
                    targetLanguage: language,
                    modelID: options.translationModel,
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    qualityStatus: .good,
                    qualityNotes: []
                )
            }
            // 앱이 DB를 먼저 읽으므로 사이드카와 DB 양쪽에 저장해야 화면에 나타납니다.
            for segment in segments {
                try store.saveTranslation(segment, snapshot: snapshot)
            }
            try sidecar.saveTranslations(
                segments,
                language: language,
                modelID: options.translationModel,
                transcripts: transcripts
            )
            if let index = items.firstIndex(where: { $0.id == itemID }) {
                items[index].translationProgress = Double(languageIndex + 1) / Double(max(1, languages.count))
                items[index].progress = (1 + items[index].translationProgress) / 2
            }
        }

        snapshot.status = .completed
        snapshot.progress = 1
        snapshot.sttProgress = 1
        snapshot.translationProgress = 1
        snapshot.error = nil
        snapshot.message = String(localized: "STT와 번역 완료")
        snapshot.updatedAt = .now
        try store.save(snapshot: snapshot)

        guard let completed = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[completed].sttProgress = 1
        items[completed].translationProgress = 1
        items[completed].progress = 1
        items[completed].status = .completed
        items[completed].existingResult = .complete(languages: languages)
        items[completed].message = [
            String(localized: "\(worker.name)에서 번역 완료"),
            resultLocationNote(for: mediaURL)
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func processRemotely(itemID: UUID, jobID: UUID, mediaURL: URL, worker: RemoteWorkerConfiguration) async throws {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: mediaURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let manifest = RemoteJobManifest(
            jobID: jobID,
            originalFilename: mediaURL.lastPathComponent,
            mediaByteCount: byteCount,
            options: options
        )
        items[index].status = .queued
        items[index].message = String(localized: "\(worker.name)에 영상 전송 중")
        let result = try await RemoteWorkerClient(worker: worker).run(mediaURL: mediaURL, manifest: manifest) { [weak self] progress in
            await MainActor.run {
                guard let self, let current = self.items.firstIndex(where: { $0.id == itemID }) else { return }
                self.items[current].status = progress.status
                self.items[current].sttProgress = progress.sttProgress
                self.items[current].translationProgress = progress.translationProgress
                self.items[current].progress = (progress.sttProgress + progress.translationProgress) / 2
                self.items[current].message = "\(worker.name) · \(progress.message)"
            }
        }
        let sidecar = try MediaSidecarStore(
            mediaURL: mediaURL,
            jobID: jobID,
            sttModel: options.sttModel,
            sourceLanguage: options.sourceLanguage,
            alternateRootURL: needsAlternateResultDirectory(mediaURL) ? alternateResultDirectoryURL : nil
        )
        try sidecar.saveTranscripts(result.transcripts)
        for language in options.targetLanguages {
            try sidecar.saveTranslations(
                result.translations.filter { $0.targetLanguage == language },
                language: language,
                modelID: options.translationModel,
                transcripts: result.transcripts
            )
        }
        guard let completed = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[completed].sttCompleted = true
        items[completed].sttProgress = 1
        items[completed].translationProgress = 1
        items[completed].progress = 1
        items[completed].status = .completed
        items[completed].message = [
            String(localized: "\(worker.name)에서 STT·번역 완료"),
            resultLocationNote(for: mediaURL)
        ].compactMap { $0 }.joined(separator: " · ")
        items[completed].existingResult = .complete(languages: options.targetLanguages)
    }

    // MARK: XPC

    private func service() -> VideoLingoAIServiceProtocol? {
        if connection == nil {
            let connection = NSXPCConnection(serviceName: "com.vvv.VideoLingo.AIService")
            connection.remoteObjectInterface = NSXPCInterface(with: VideoLingoAIServiceProtocol.self)
            connection.invalidationHandler = { [weak self, weak connection] in
                Task { @MainActor in
                    guard let self, self.connection === connection else { return }
                    self.connection = nil
                }
            }
            connection.interruptionHandler = { [weak self, weak connection] in
                Task { @MainActor in
                    guard let self, self.connection === connection else { return }
                    self.connection = nil
                }
            }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in } as? VideoLingoAIServiceProtocol
    }

    private func recoveryDelay(for attempt: Int) -> Duration {
        .seconds(min(4, 1 << max(0, attempt - 1)))
    }

    private func sendWithRecovery(payload: Data, itemID: UUID) async throws -> VideoLingoAIServiceProtocol {
        var lastError: Error?
        for attempt in 0...Self.maximumServiceRecoveryAttempts {
            try Task.checkCancellation()
            guard let service = service() else {
                lastError = NSError(
                    domain: "VideoLingo.BatchProcessor",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "내장 AI 서버에 연결할 수 없습니다.")]
                )
                continue
            }
            do {
                _ = try await send(service, payload: payload)
                return service
            } catch {
                lastError = error
                guard attempt < Self.maximumServiceRecoveryAttempts else { break }
                if let index = items.firstIndex(where: { $0.id == itemID }) {
                    items[index].message = String(localized: "AI 서비스 재연결 중… ((attempt + 1)/(Self.maximumServiceRecoveryAttempts))")
                }
                try await Task.sleep(for: recoveryDelay(for: attempt + 1))
            }
        }
        throw lastError ?? NSError(
            domain: "VideoLingo.BatchProcessor",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: String(localized: "AI 서비스에 작업을 전달하지 못했습니다.")]
        )
    }

    private func send(_ service: VideoLingoAIServiceProtocol, payload: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            service.startJob(payload) { _, error in
                if let error { continuation.resume(throwing: NSError(domain: "VideoLingo", code: 1, userInfo: [NSLocalizedDescriptionKey: error])) }
                else { continuation.resume() }
            }
        }
    }

    private func cancelJob(_ service: VideoLingoAIServiceProtocol, jobID: UUID) async {
        await withCheckedContinuation { continuation in
            service.cancelJob(jobID.uuidString) { _ in continuation.resume() }
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

private enum BatchWorkspaceTab: String, CaseIterable, Identifiable {
    case files
    case library
    case monitoring

    var id: Self { self }
    var title: String {
        switch self {
        case .files: String(localized: "파일 목록")
        case .library: String(localized: "영상 라이브러리")
        case .monitoring: String(localized: "모니터링")
        }
    }
    var systemImage: String {
        switch self {
        case .files: "list.bullet.rectangle"
        case .library: "rectangle.stack"
        case .monitoring: "chart.xyaxis.line"
        }
    }
}

struct BatchTranslationView: View {
    @Environment(BatchProcessor.self) private var processor
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false
    @State private var selection: Set<UUID> = []
    @State private var showingActiveDeleteConfirmation = false
    @State private var pendingRemovalIDs: Set<UUID> = []
    @State private var showingDuplicateReview = false
    @State private var showingDuplicateCleanupConfirmation = false
    @State private var showingContentDuplicateReview = false
    @State private var showingSameNameTrashConfirmation = false
    @State private var isTrashingSameNameDuplicates = false
    @State private var sameNameTrashResult = ""
    @State private var showingStartConfirmation = false
    @State private var pendingStartIDs: Set<UUID> = []
    @State private var workspaceTab: BatchWorkspaceTab = .files
    @State private var monitoringIsReady = false
    @AppStorage("batchListFilter") private var listFilter: BatchListFilter = .active

    var body: some View {
        @Bindable var processor = processor
        VStack(spacing: 0) {
            Picker("대량 번역 화면", selection: $workspaceTab) {
                ForEach(BatchWorkspaceTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if workspaceTab == .monitoring {
                if monitoringIsReady {
                    BatchMonitoringWorkspace()
                } else {
                    ContentUnavailableView {
                        Label("모니터링 화면 준비 중", systemImage: "chart.xyaxis.line")
                    } description: {
                        Text("영상 미리보기와 처리 현황을 불러오고 있습니다.")
                    }
                }
            } else if workspaceTab == .library {
                BatchMediaLibraryView()
            } else if processor.items.isEmpty {
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
                                    onRestart: { requestStart(ids: [item.id]) },
                                    onReanalyzeSpeakers: {
                                        processor.reanalyzeSpeakers(ids: [item.id])
                                        requestStart(ids: [item.id])
                                    },
                                    onRedoFromScratch: {
                                        processor.redoFromScratch(ids: [item.id])
                                        requestStart(ids: [item.id])
                                    },
                                    onPause: { processor.pause(ids: [item.id]) },
                                    onCancel: { processor.stop(ids: [item.id]) },
                                    onRemove: { requestRemoval(ids: [item.id]) },
                                    canRestart: !item.isProcessing && [.failed, .cancelled, .paused].contains(item.status),
                                    canPause: processor.isRunning && !item.isFinished && item.status != .paused,
                                    canCancel: item.isProcessing || !item.isFinished,
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
                if workspaceTab == .files {
                    BatchLanguageSettingsView()

                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.badge.plus")
                            .foregroundStyle(processor.readOnlyItemCount() > 0 && processor.alternateResultDirectoryURL == nil ? .red : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("읽기 전용 영상 결과")
                                .font(.headline)
                            Text(processor.alternateResultDirectoryDisplayPath
                                ?? "읽기 전용 디스크의 STT·번역 파일을 저장할 폴더를 지정하세요.")
                                .font(.caption)
                                .foregroundStyle(processor.readOnlyItemCount() > 0 && processor.alternateResultDirectoryURL == nil ? .red : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if processor.alternateResultDirectoryURL != nil {
                            Button("해제") { processor.clearAlternateResultDirectory() }
                                .disabled(processor.isRunning)
                        }
                        Button(processor.alternateResultDirectoryURL == nil ? "폴더 지정…" : "변경…") {
                            processor.chooseAlternateResultDirectory()
                        }
                            .disabled(processor.isRunning)
                    }

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
                            Toggle("앱 재시작 후 자동 재개", isOn: $processor.automaticallyResumeOnLaunch)
                                .help("현재 실행 중인 대량 번역을 저장하고 다음 실행에서 체크포인트부터 계속합니다")
                            BatchFocusedModeToggle()
                            Toggle("Mac 성능에 맞게 자동 조정", isOn: $processor.automaticallyAdjustConcurrentJobs)
                                .disabled(processor.isRunning || processor.focusedTranslationMode)
                            Stepper(value: $processor.maximumConcurrentJobs, in: 1...10) {
                                Text(processor.automaticallyAdjustConcurrentJobs
                                    ? "자동 번역 \(processor.effectiveConcurrentJobs)개"
                                    : "수동 번역 \(processor.maximumConcurrentJobs)개")
                                    .monospacedDigit()
                            }
                            .disabled(processor.isRunning || processor.automaticallyAdjustConcurrentJobs || processor.focusedTranslationMode)
                            Stepper(value: $processor.maximumConcurrentSTTJobs, in: 1...10) {
                                Text(processor.automaticallyAdjustConcurrentJobs
                                    ? "자동 STT \(processor.effectiveSTTConcurrentJobs)개"
                                    : "수동 STT \(processor.maximumConcurrentSTTJobs)개")
                                    .monospacedDigit()
                            }
                            .disabled(processor.isRunning || processor.automaticallyAdjustConcurrentJobs || processor.focusedTranslationMode)
                            Text(processor.automaticConcurrencySummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Toggle("원격 서버 우선 사용", isOn: $processor.prefersRemoteWorkers)
                                .disabled(processor.focusedTranslationMode)
                            Stepper(value: $processor.remoteRequestMultiplier, in: 1...4) {
                                Text("원격 요청 \(processor.remoteRequestMultiplier)배")
                                    .monospacedDigit()
                            }
                            .disabled(!processor.prefersRemoteWorkers)
                            Stepper(value: $processor.localCPUUsageLimit, in: 20...90, step: 5) {
                                Text("내장 CPU 상한 \(processor.localCPUUsageLimit)%")
                                    .monospacedDigit()
                            }
                            Toggle("큰 오디오 분할 전송", isOn: $processor.usesChunkedAudioUpload)
                            Stepper(value: $processor.chunkedAudioThresholdMB, in: 25...500, step: 25) {
                                Text("분할 기준 \(processor.chunkedAudioThresholdMB)MB")
                                    .monospacedDigit()
                            }
                            .disabled(!processor.usesChunkedAudioUpload)
                            Text(processor.workloadRoutingSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .help("원격 서버에 대기 요청을 더 보내고, 내장 서버는 CPU 상한을 넘으면 새 작업 시작을 늦춥니다")
                    }
                }

                if processor.isRunning || processor.completedCount > 0 {
                    HStack(spacing: 12) {
                        ProgressView(value: processor.overallProgress)
                        Text(processor.isPaused
                            ? "일시 정지 · 마무리 중 \(processor.runningCount) · 대기 \(processor.pendingCount) · 완료 \(processor.completedCount)"
                            : "실행 \(processor.runningCount) · 대기 \(processor.pendingCount) · 완료 \(processor.completedCount)")
                            .font(.caption)
                            .foregroundStyle(processor.isPaused ? .orange : .secondary)
                            .monospacedDigit()
                    }
                }

                if workspaceTab == .files && (processor.isCheckingExistingResults || !processor.resultCheckMessage.isEmpty) {
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

                if workspaceTab == .files && (processor.isScanningFolders || !processor.folderScanMessage.isEmpty) {
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

                if workspaceTab == .files && !selection.isEmpty {
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
                        Button(
                            processor.isPaused ? "계속" : "일시 정지",
                            systemImage: processor.isPaused ? "play.fill" : "pause.fill"
                        ) {
                            if processor.isPaused {
                                processor.resume()
                            } else {
                                processor.pause()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(processor.isPaused ? Color.accentColor : nil)
                        .help(processor.isPaused
                            ? "남은 대량 번역 대기열을 계속 처리"
                            : "새 영상 시작을 멈추고 현재 실행 중인 영상만 마무리")
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
        .onChange(of: workspaceTab) { _, tab in
            monitoringIsReady = false
            guard tab == .monitoring else { return }
            Task { @MainActor in
                // 탭 선택 표시를 먼저 그린 다음 무거운 미리보기 화면을 구성합니다.
                await Task.yield()
                guard workspaceTab == .monitoring else { return }
                monitoringIsReady = true
            }
        }
        .onChange(of: Set(processor.items.map(\.id))) { _, availableIDs in
            selection.formIntersection(availableIDs)
        }
        .confirmationDialog(
            "실행 중인 선택 작업을 중단하고 삭제할까요?",
            isPresented: $showingActiveDeleteConfirmation
        ) {
            Button("중단하고 목록에서 삭제", role: .destructive) {
                removePendingItems()
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
                workspaceTab = .monitoring
            }
            .environment(processor)
        }
        .sheet(isPresented: $showingContentDuplicateReview) {
            ContentDuplicateReviewView()
        }
        .confirmationDialog(
            "이름이 같은 영상 \(processor.duplicateFilenameRemovalCount)개를 삭제할까요?",
            isPresented: $showingSameNameTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("휴지통으로 이동", role: .destructive) { trashSameNameDuplicates() }
            Button("목록에서만 제거") {
                processor.remove(ids: processor.recommendedDuplicateRemovalIDs)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("같은 이름마다 첫 번째 영상 하나만 남깁니다. 휴지통으로 옮기면 Finder에서 되돌릴 수 있습니다.")
        }
        .alert("중복 정리", isPresented: Binding(
            get: { !sameNameTrashResult.isEmpty },
            set: { if !$0 { sameNameTrashResult = "" } }
        )) {
            Button("확인") { sameNameTrashResult = "" }
        } message: {
            Text(sameNameTrashResult)
        }
        .sheet(isPresented: $showingDuplicateReview) {
            DuplicateFilenameReviewView()
                .environment(processor)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let didAddFiles = processor.addDroppedURLs(urls)
            workspaceTab = .files
            return didAddFiles
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
                if workspaceTab == .files {
                    Button("기존 번역 확인", systemImage: "checkmark.magnifyingglass") {
                        processor.refreshExistingResults()
                    }
                    .disabled(processor.isRunning || processor.isCheckingExistingResults || processor.items.isEmpty)
                    .help("현재 모델과 언어 기준으로 저장된 STT·번역 다시 확인")
                // 같은 이름이 여러 개면 한 번 눌러 바로 정리할 수 있게 메뉴 밖으로 꺼냈습니다.
                if processor.duplicateFilenameRemovalCount > 0 {
                    Button("중복 \(processor.duplicateFilenameRemovalCount)개 삭제", systemImage: "trash") {
                        showingSameNameTrashConfirmation = true
                    }
                    .disabled(processor.isRunning || isTrashingSameNameDuplicates)
                    .help("이름이 같은 영상마다 첫 번째 하나만 남기고 나머지 파일을 휴지통으로 옮깁니다")
                    if isTrashingSameNameDuplicates { ProgressView().controlSize(.small) }
                }
                Menu("중복 파일 정리", systemImage: "doc.on.doc") {
                    Button("중복 전체 일괄 제거", systemImage: "rectangle.stack.badge.minus") {
                        showingDuplicateCleanupConfirmation = true
                    }
                    Button("경로별로 검토…", systemImage: "list.bullet.rectangle") {
                        showingDuplicateReview = true
                    }
                    Divider()
                    Button("같은 내용 찾기 (파일명 무관)…", systemImage: "doc.viewfinder") {
                        showingContentDuplicateReview = true
                    }
                    .help("크기와 앞뒤 내용을 비교해 이름이 다른 중복 영상을 찾습니다")
                }
                .disabled(processor.isRunning)
                .help(processor.duplicateFilenameGroups.isEmpty
                    ? "동일한 파일명의 영상이 없습니다"
                    : "\(processor.duplicateFilenameGroups.count)개 중복 그룹에서 \(processor.duplicateFilenameRemovalCount)개를 정리")
                    Button("폴더 추가…", systemImage: "folder.badge.plus") { processor.addFolders() }
                        .disabled(processor.isScanningFolders)
                        .help("폴더와 하위 폴더에서 영상 검색")
                    Button("영상 추가…", systemImage: "plus") { processor.addFiles() }
                        .help("여러 영상 추가")
                } else if workspaceTab == .monitoring {
                    Button("모니터링 별도 창", systemImage: "macwindow.on.rectangle") {
                        openWindow(id: "batch-monitor")
                    }
                    .disabled(processor.items.isEmpty)
                    .help("현재 모니터링 화면을 별도 창으로 열기")
                } else {
                    Button("라이브러리 새로 고침", systemImage: "arrow.clockwise") {
                        MediaLibrary.shared.refresh()
                    }
                    .disabled(MediaLibrary.shared.isScanning || MediaLibrary.shared.folders.isEmpty)
                    Button("라이브러리 폴더 추가…", systemImage: "folder.badge.plus") {
                        MediaLibrary.shared.chooseFolders()
                    }
                }
            }
        }
    }

    /// 이름이 같은 영상마다 첫 번째만 남기고 나머지 파일을 휴지통으로 옮깁니다.
    private func trashSameNameDuplicates() {
        let ids = processor.recommendedDuplicateRemovalIDs
        guard !ids.isEmpty else { return }
        isTrashingSameNameDuplicates = true
        Task {
            defer { isTrashingSameNameDuplicates = false }
            let result = await processor.moveVideosToTrash(ids: ids)
            sameNameTrashResult = result.failureMessage
                ?? String(localized: "\(result.movedCount)개를 휴지통으로 옮겼습니다.")
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
        requestRemoval(ids: selection)
    }

    private func requestRemoval(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingRemovalIDs = ids
        if processor.items.contains(where: { ids.contains($0.id) && $0.isProcessing }) {
            showingActiveDeleteConfirmation = true
        } else {
            removePendingItems()
        }
    }

    private func removePendingItems() {
        let ids = pendingRemovalIDs
        pendingRemovalIDs.removeAll()
        selection.subtract(ids)
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

private struct BatchFocusedModeToggle: View {
    @Environment(BatchProcessor.self) private var processor

    var body: some View {
        @Bindable var processor = processor
        Toggle("집중 번역 모드", isOn: $processor.focusedTranslationMode)
            .disabled(processor.isRunning)
            .help("진행률이 높은 영상 하나를 STT부터 번역까지 먼저 끝내고, 연결된 원격 서버를 우선 사용합니다")
    }
}

private struct BatchStartConfirmationView: View {
    @Environment(BatchProcessor.self) private var processor
    @Environment(\.dismiss) private var dismiss
    let itemIDs: Set<UUID>
    let onStart: () -> Void
    @State private var languagesConfirmed = false

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

            Toggle(isOn: $languagesConfirmed) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("STT 원어와 번역 언어를 확인했습니다")
                        .font(.callout.weight(.semibold))
                    Text("\(confirmedSourceLanguage) → \(confirmedTargetLanguages)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                            BatchFocusedModeToggle()
                            Toggle("Mac 성능에 맞게 자동 조정", isOn: $processor.automaticallyAdjustConcurrentJobs)
                                .disabled(processor.focusedTranslationMode)
                            Stepper(value: $processor.maximumConcurrentSTTJobs, in: 1...10) {
                                Text(processor.automaticallyAdjustConcurrentJobs
                                    ? "자동 STT \(processor.effectiveSTTConcurrentJobs)개"
                                    : "수동 STT \(processor.maximumConcurrentSTTJobs)개")
                                    .monospacedDigit()
                            }
                            .disabled(processor.isRunning || processor.automaticallyAdjustConcurrentJobs || processor.focusedTranslationMode)
                            Stepper(value: $processor.maximumConcurrentJobs, in: 1...10) {
                                Text(processor.automaticallyAdjustConcurrentJobs
                                    ? "자동 번역 \(processor.effectiveConcurrentJobs)개"
                                    : "수동 번역 \(processor.maximumConcurrentJobs)개")
                                    .monospacedDigit()
                            }
                            .disabled(processor.automaticallyAdjustConcurrentJobs || processor.focusedTranslationMode)
                            Text(processor.automaticConcurrencySummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Toggle("원격 서버 우선 사용", isOn: $processor.prefersRemoteWorkers)
                                .disabled(processor.focusedTranslationMode)
                            Stepper(value: $processor.remoteRequestMultiplier, in: 1...4) {
                                Text("원격 요청 \(processor.remoteRequestMultiplier)배")
                                    .monospacedDigit()
                            }
                            .disabled(!processor.prefersRemoteWorkers)
                            Stepper(value: $processor.localCPUUsageLimit, in: 20...90, step: 5) {
                                Text("내장 CPU 상한 \(processor.localCPUUsageLimit)%")
                                    .monospacedDigit()
                            }
                            Toggle("큰 오디오 분할 전송", isOn: $processor.usesChunkedAudioUpload)
                            Stepper(value: $processor.chunkedAudioThresholdMB, in: 25...500, step: 25) {
                                Text("분할 기준 \(processor.chunkedAudioThresholdMB)MB")
                                    .monospacedDigit()
                            }
                            .disabled(!processor.usesChunkedAudioUpload)
                            Text(processor.workloadRoutingSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(4)
            } label: {
                Label("처리 설정", systemImage: "gearshape.2")
            }

            BatchRemoteServerSection()

            if readOnlyCount > 0 {
                GroupBox {
                    HStack(spacing: 12) {
                        // 쓸 수 없어도 결과는 자동으로 다른 곳에 저장되므로 경고가 아니라 안내입니다.
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("읽기 전용 위치의 영상 \(readOnlyCount)개")
                                .font(.callout.weight(.semibold))
                            Text(processor.alternateResultDirectoryURL == nil
                                ? String(localized: "원본 옆에 쓸 수 없어 앱 폴더에 저장합니다: \(processor.managedResultsDisplayPath)")
                                : String(localized: "지정한 폴더에 저장합니다: \(processor.alternateResultDirectoryDisplayPath ?? "")"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        if processor.alternateResultDirectoryURL == nil {
                            Button("앱 폴더 열기") { processor.revealManagedResultsFolder() }
                        }
                        Button(processor.alternateResultDirectoryURL == nil ? "다른 폴더 지정…" : "변경…") {
                            processor.chooseAlternateResultDirectory()
                        }
                    }
                    .padding(4)
                } label: {
                    Label("결과 저장 위치", systemImage: "externaldrive")
                }
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
                .disabled(processor.isCheckingExistingResults
                    || !languagesConfirmed
                    || processor.batchTargetLanguages.isEmpty
                    || startableCount == 0)
                .help(processor.isCheckingExistingResults ? "기존 결과 확인이 끝나면 시작할 수 있습니다" : "확인한 설정으로 대량 번역 시작")
            }
        }
        .padding(24)
        .frame(width: 600)
        .interactiveDismissDisabled(processor.isCheckingExistingResults)
        .onChange(of: processor.batchSourceLanguage) { _, _ in languagesConfirmed = false }
        .onChange(of: processor.batchTargetLanguages) { _, _ in languagesConfirmed = false }
    }

    private var startableCount: Int {
        processor.items.filter {
            itemIDs.contains($0.id) && $0.status != .completed && !$0.isProcessing
        }.count
    }

    private var readOnlyCount: Int {
        processor.readOnlyItemCount(in: itemIDs)
    }

    private var confirmedSourceLanguage: String {
        processor.sourceLanguageName(processor.batchSourceLanguage)
    }

    private var confirmedTargetLanguages: String {
        processor.batchTargetLanguages
            .map { processor.sourceLanguageName($0) }
            .joined(separator: ", ")
    }
}

/// 대량 번역 창 안에서 멀티 미리보기와 처리량/서버 상태를 함께 보는 화면입니다.
private struct BatchMonitoringWorkspace: View {
    @Environment(BatchProcessor.self) private var processor

    var body: some View {
        HSplitView {
            BatchMultiMonitorView(isEmbedded: true, maximumDisplayedItems: 12)
                .frame(minWidth: 560)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if processor.isRunning || processor.completedCount > 0 {
                        BatchLiveMonitorView()
                    } else {
                        ContentUnavailableView(
                            "아직 처리 기록이 없습니다",
                            systemImage: "chart.xyaxis.line",
                            description: Text("파일 목록 탭에서 영상을 추가하고 대량 번역을 시작하세요.")
                        )
                    }

                    if !RemoteWorkerPool.shared.workers.isEmpty {
                        RemoteServerMonitorView()
                            .remoteServerHealthAlert()
                    }
                }
                .padding(16)
            }
            .frame(minWidth: 360, idealWidth: 440)
        }
    }
}

private enum BatchMonitorFilter: String, CaseIterable, Identifiable {
    case active
    case attention
    case all
    case completed

    var id: Self { self }
    var title: String {
        switch self {
        case .active: "진행·대기"
        case .attention: "주의 필요"
        case .all: "전체"
        case .completed: "완료"
        }
    }
}

private struct BatchMonitorSnapshot {
    let allItems: [BatchProcessor.Item]
    let visibleItems: [BatchProcessor.Item]
    let displayedItems: [BatchProcessor.Item]
    let activeCount: Int
    let queuedCount: Int
    let runningCount: Int
    let completedCount: Int
    let attentionCount: Int
    let failedCount: Int
    let overallProgress: Double

    func count(for filter: BatchMonitorFilter) -> Int {
        switch filter {
        case .active: activeCount
        case .attention: attentionCount
        case .all: allItems.count
        case .completed: completedCount
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
    @State private var isReconnectingServers = false
    @State private var reconnectStatusMessage = ""
    @State private var monitorItems: [BatchProcessor.Item] = []
    let isEmbedded: Bool
    let maximumDisplayedItems: Int?

    init(isEmbedded: Bool = false, maximumDisplayedItems: Int? = nil) {
        self.isEmbedded = isEmbedded
        self.maximumDisplayedItems = maximumDisplayedItems
    }

    var body: some View {
        let snapshot = makeSnapshot()
        VStack(spacing: 0) {
            monitorHeader(snapshot)
            Divider()

            if snapshot.allItems.isEmpty {
                ContentUnavailableView(
                    "모니터링할 영상이 없습니다",
                    systemImage: "rectangle.grid.2x2",
                    description: Text("대량 번역 창에서 영상을 추가하면 각 영상과 STT·번역 진행 상황을 함께 볼 수 있습니다.")
                )
            } else if snapshot.visibleItems.isEmpty {
                ContentUnavailableView(
                    emptyStateTitle,
                    systemImage: emptyStateSymbol,
                    description: Text(emptyStateDescription)
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(snapshot.displayedItems) { item in
                            BatchMonitorTile(
                                item: item,
                                playsVideo: playbackBinding(for: item.id),
                                onShowDetails: { openWindow(id: "batch-detail", value: item.id) },
                                onExpand: { openWindow(id: "batch-monitor-preview", value: item.id) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(isEmbedded ? "대량 번역" : "STT·번역 멀티 화면")
        .frame(minWidth: isEmbedded ? 0 : 880, minHeight: isEmbedded ? 0 : 600)
        .task {
            while !Task.isCancelled {
                let latestItems = processor.items
                monitorItems = latestItems
                playbackSelection.formIntersection(Set(latestItems.map(\.id)))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func monitorHeader(_ snapshot: BatchMonitorSnapshot) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                BatchMonitorMetric(
                    title: "전체 진행",
                    value: snapshot.overallProgress.formatted(.percent.precision(.fractionLength(0))),
                    systemImage: "chart.bar.fill",
                    color: .accentColor
                )
                BatchMonitorMetric(
                    title: "처리 중",
                    value: "\(snapshot.runningCount)",
                    systemImage: "dot.radiowaves.left.and.right",
                    color: .blue
                )
                BatchMonitorMetric(
                    title: "대기",
                    value: "\(snapshot.queuedCount)",
                    systemImage: "clock.fill",
                    color: .secondary
                )
                BatchMonitorMetric(
                    title: "완료",
                    value: "\(snapshot.completedCount)",
                    systemImage: "checkmark.circle.fill",
                    color: .green
                )
                BatchMonitorMetric(
                    title: "주의 필요",
                    value: "\(snapshot.attentionCount)",
                    systemImage: snapshot.attentionCount == 0 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                    color: snapshot.attentionCount == 0 ? .green : .orange
                )
            }

            HStack(spacing: 8) {
                ForEach(BatchMonitorFilter.allCases) { option in
                    monitorFilterButton(option, count: snapshot.count(for: option))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("모니터링 표시 항목")

            HStack(spacing: 16) {
                Button {
                    reconnectServersAndRetryFailures()
                } label: {
                    if isReconnectingServers {
                        Label("서버 연결 확인 중…", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    } else if snapshot.failedCount > 0 {
                        Label("서버 재연결 · 실패 \(snapshot.failedCount)개 재시도", systemImage: "bolt.horizontal.circle")
                    } else {
                        Label("서버 다시 연결", systemImage: "bolt.horizontal.circle")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isReconnectingServers)
                .help(snapshot.failedCount > 0
                      ? "서버 연결을 다시 확인하고 실패한 작업을 저장된 결과부터 재시도"
                      : "원격 서버와 내장 서버 연결을 다시 확인")

                if !reconnectStatusMessage.isEmpty {
                    Text(reconnectStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text("재생 선택 \(visiblePlaybackSelectionCount(in: snapshot.displayedItems))개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button(allVisibleItemsSelected(in: snapshot.displayedItems) ? "표시 영상 선택 해제" : "표시 영상 전체 선택",
                       systemImage: allVisibleItemsSelected(in: snapshot.displayedItems) ? "checkmark.square.fill" : "square.stack") {
                    if allVisibleItemsSelected(in: snapshot.displayedItems) {
                        playbackSelection.subtract(snapshot.displayedItems.map(\.id))
                    } else {
                        playbackSelection.formUnion(snapshot.displayedItems.map(\.id))
                    }
                }
                .disabled(snapshot.displayedItems.isEmpty)
                .help("현재 필터에 표시된 영상의 음소거 재생을 한 번에 선택하거나 해제")

                if snapshot.displayedItems.count < snapshot.visibleItems.count {
                    Text("미리보기 \(snapshot.displayedItems.count)/\(snapshot.visibleItems.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("화면 성능을 위해 처리 중인 영상부터 일부만 표시합니다. 별도 창에서는 전체 항목을 볼 수 있습니다.")
                }

                Stepper(value: $columnCount, in: 1...4) {
                    Text("한 줄 \(columnCount)개")
                        .monospacedDigit()
                }
                .frame(width: 125)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func monitorFilterButton(_ option: BatchMonitorFilter, count itemCount: Int) -> some View {
        let isSelected = filter == option
        let needsAttention = option == .attention && itemCount > 0
        let tint: Color = needsAttention ? .orange : .accentColor

        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                filter = option
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: filterSymbol(for: option, count: itemCount))
                    .foregroundStyle(isSelected ? Color.white : (needsAttention ? Color.orange : Color.secondary))
                Text(option.title)
                    .lineLimit(1)
                Text("\(itemCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(isSelected ? Color.white.opacity(0.2) : tint.opacity(needsAttention ? 0.18 : 0.1), in: Capsule())
            }
            .font(.callout.weight(isSelected || needsAttention ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 32)
            .padding(.horizontal, 8)
            .background(isSelected ? tint : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(needsAttention && !isSelected ? Color.orange.opacity(0.65) : Color.secondary.opacity(0.2), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(option.title) 항목 \(itemCount)개 보기")
        .accessibilityLabel("\(option.title), \(itemCount)개")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func filterSymbol(for option: BatchMonitorFilter, count: Int) -> String {
        switch option {
        case .active: "play.circle.fill"
        case .attention: count > 0 ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"
        case .all: "rectangle.stack.fill"
        case .completed: "checkmark.circle.fill"
        }
    }

    private func makeSnapshot() -> BatchMonitorSnapshot {
        let allItems = monitorItems
        let activeItems = allItems.filter { $0.isProcessing || $0.status == .queued }
        let attentionItems = allItems.filter { [.failed, .cancelled, .paused].contains($0.status) }
        let completedItems = allItems.filter { $0.status == .completed }
        let visibleItems: [BatchProcessor.Item]
        switch filter {
        case .active:
            visibleItems = activeItems.sorted { lhs, rhs in
                    if lhs.isProcessing != rhs.isProcessing { return lhs.isProcessing }
                    return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
                }
        case .attention: visibleItems = attentionItems
        case .all: visibleItems = allItems
        case .completed: visibleItems = completedItems
        }
        let displayedItems = maximumDisplayedItems.map { Array(visibleItems.prefix($0)) } ?? visibleItems
        let overallProgress = allItems.isEmpty ? 0 : allItems.reduce(0) {
            $0 + ($1.isFinished ? 1 : $1.progress)
        } / Double(allItems.count)
        return BatchMonitorSnapshot(
            allItems: allItems,
            visibleItems: visibleItems,
            displayedItems: displayedItems,
            activeCount: activeItems.count,
            queuedCount: activeItems.filter { $0.status == .queued && !$0.isProcessing }.count,
            runningCount: allItems.filter(\.isProcessing).count,
            completedCount: completedItems.count,
            attentionCount: attentionItems.count,
            failedCount: attentionItems.filter { $0.status == .failed }.count,
            overallProgress: overallProgress
        )
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: columnCount)
    }

    private var emptyStateTitle: String {
        switch filter {
        case .active: "진행 또는 대기 중인 영상이 없습니다"
        case .attention: "주의가 필요한 영상이 없습니다"
        case .all: "모니터링할 영상이 없습니다"
        case .completed: "완료된 영상이 없습니다"
        }
    }

    private var emptyStateSymbol: String {
        switch filter {
        case .active: "pause.circle"
        case .attention: "checkmark.shield"
        case .all: "tray"
        case .completed: "checkmark.circle"
        }
    }

    private var emptyStateDescription: String {
        switch filter {
        case .active: "대량 번역을 시작하거나 ‘전체’ 화면을 선택하세요."
        case .attention: "현재 실패·취소·일시 정지된 작업이 없습니다."
        case .all: "대량 번역 창에서 영상을 추가하세요."
        case .completed: "번역이 끝난 영상은 이곳에 자동으로 나타납니다."
        }
    }

    private func visiblePlaybackSelectionCount(in displayedItems: [BatchProcessor.Item]) -> Int {
        displayedItems.lazy.filter { playbackSelection.contains($0.id) }.count
    }

    private func allVisibleItemsSelected(in displayedItems: [BatchProcessor.Item]) -> Bool {
        !displayedItems.isEmpty && displayedItems.allSatisfy { playbackSelection.contains($0.id) }
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

    private func reconnectServersAndRetryFailures() {
        guard !isReconnectingServers else { return }
        isReconnectingServers = true
        reconnectStatusMessage = String(localized: "서버 연결을 확인하는 중…")

        Task {
            let remoteServerCount = await processor.reconnectServers()
            let failedIDs = Set(processor.items.filter { $0.status == .failed }.map(\.id))
            if failedIDs.isEmpty {
                reconnectStatusMessage = remoteServerCount > 0
                    ? String(localized: "원격 서버 \(remoteServerCount)대 연결됨")
                    : String(localized: "내장 서버로 다시 연결합니다")
            } else {
                processor.start(ids: failedIDs)
                filter = .active
                reconnectStatusMessage = remoteServerCount > 0
                    ? String(localized: "원격 서버 \(remoteServerCount)대 연결 · 실패 \(failedIDs.count)개 재시도")
                    : String(localized: "내장 서버로 실패 \(failedIDs.count)개 재시도")
            }
            isReconnectingServers = false
        }
    }
}

private struct BatchMonitorMetric: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct BatchMonitorTile: View {
    let item: BatchProcessor.Item
    @Binding var playsVideo: Bool
    let onShowDetails: () -> Void
    let onExpand: (() -> Void)?
    @State private var player: AVPlayer?
    @State private var isMuted = true
    /// 미리보기 음량입니다. 음소거를 풀었을 때 곧바로 들리도록 기본값을 적당히 둡니다.
    @State private var previewVolume: Double = 0.6

    private var volumeSymbol: String {
        switch previewVolume {
        case ..<0.01: "speaker.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isSeeking = false

    init(
        item: BatchProcessor.Item,
        playsVideo: Binding<Bool>,
        onShowDetails: @escaping () -> Void,
        onExpand: (() -> Void)? = nil
    ) {
        self.item = item
        _playsVideo = playsVideo
        self.onShowDetails = onShowDetails
        self.onExpand = onExpand
        _player = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let player {
                        BatchMonitorPlayer(player: player)
                    } else {
                        ZStack {
                            Color.black
                            VStack(spacing: 8) {
                                Image(systemName: "play.rectangle")
                                    .font(.largeTitle)
                                Text("미리보기 재생을 선택하면 영상을 불러옵니다")
                                    .font(.caption)
                            }
                            .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
                .onTapGesture(count: 2) { onExpand?() }
                .help(onExpand == nil ? "영상 미리보기" : "더블클릭하여 큰 미리보기 창 열기")

                HStack(spacing: 6) {
                    Image(systemName: statusSymbol)
                    Text(statusText)
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
                    if let onExpand {
                        Button("크게 보기", systemImage: "arrow.up.left.and.arrow.down.right") {
                            onExpand()
                        }
                        .labelStyle(.iconOnly)
                        .help("이 영상만 독립된 큰 미리보기 창에서 보기")
                    }
                }

                if !item.message.isEmpty {
                    Label(item.message, systemImage: item.status == .failed ? "exclamationmark.circle.fill" : statusSymbol)
                        .font(.caption)
                        .foregroundStyle(item.status == .failed ? .red : .secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Text(timeText(currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 42, alignment: .trailing)

                    Slider(
                        value: Binding(
                            get: { currentTime },
                            set: { currentTime = $0 }
                        ),
                        in: 0...max(1, duration)
                    ) { editing in
                        isSeeking = editing
                        if !editing { seek(to: currentTime) }
                    }
                    .help("드래그해서 영상 위치 이동")

                    Text(timeText(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 42, alignment: .leading)
                }

                HStack(spacing: 20) {
                    Button("10초 뒤로", systemImage: "gobackward.10") {
                        seek(by: -10)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("10초 뒤로 이동")

                    Button(isMuted ? "소리 켜기" : "소리 끄기",
                           systemImage: isMuted ? "speaker.slash.fill" : volumeSymbol) {
                        isMuted.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(isMuted ? "이 영상의 소리 켜기" : "이 영상 음소거")

                    // 켜고 끄는 것만이 아니라 크기도 조절할 수 있게 합니다.
                    Slider(value: $previewVolume, in: 0...1)
                        .frame(width: 90)
                        .controlSize(.small)
                        .disabled(isMuted)
                        .help("미리보기 음량")
                    Text(previewVolume, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)

                    Button("10초 앞으로", systemImage: "goforward.10") {
                        seek(by: 10)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("10초 앞으로 이동")
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .controlSize(.small)

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
                .strokeBorder(playsVideo ? Color.accentColor : statusBorderColor)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { updatePlayback() }
        .onDisappear { releasePlayer() }
        .onChange(of: playsVideo) { _, _ in updatePlayback() }
        .onChange(of: isMuted) { _, muted in player?.isMuted = muted }
        .onChange(of: previewVolume) { _, value in player?.volume = Float(value) }
        .task(id: playsVideo) {
            guard playsVideo else { return }
            while !Task.isCancelled {
                if let player, !isSeeking {
                    let position = player.currentTime().seconds
                    if position.isFinite { currentTime = max(0, position) }
                    let itemDuration = player.currentItem?.duration.seconds ?? 0
                    if itemDuration.isFinite, itemDuration > 0 { duration = itemDuration }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
        if !playsVideo {
            player?.pause()
            return
        }
        if player == nil {
            player = AVPlayer(url: item.url)
        }
        guard let player else { return }
        player.isMuted = isMuted
        player.volume = Float(previewVolume)
        player.play()
    }

    private func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func seek(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    private func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let target = min(max(0, seconds), duration > 0 ? duration : .greatestFiniteMagnitude)
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)
        )
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%d:%02d", minutes, remainingSeconds)
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

    private var statusBorderColor: Color {
        switch item.status {
        case .failed: .red.opacity(0.75)
        case .paused, .cancelled: .orange.opacity(0.65)
        case .completed: .green.opacity(0.45)
        default: item.isProcessing ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.2)
        }
    }
}

/// 멀티 화면에서 선택한 한 영상을 독립된 큰 창으로 재생합니다.
struct BatchMonitorExpandedPreviewView: View {
    @Environment(BatchProcessor.self) private var processor
    @Environment(\.openWindow) private var openWindow
    let itemID: UUID?
    @State private var playsVideo = true

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    BatchMonitorTile(
                        item: item,
                        playsVideo: $playsVideo,
                        onShowDetails: { openWindow(id: "batch-detail", value: item.id) }
                    )
                    .frame(maxWidth: 1_200)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
                .navigationTitle(item.url.lastPathComponent)
            } else {
                ContentUnavailableView(
                    "영상을 찾을 수 없습니다",
                    systemImage: "film.stack",
                    description: Text("대량 번역 목록에서 제거되었거나 더 이상 사용할 수 없는 영상입니다.")
                )
            }
        }
        .frame(minWidth: 800, minHeight: 560)
    }

    private var item: BatchProcessor.Item? {
        guard let itemID else { return nil }
        return processor.items.first { $0.id == itemID }
    }
}

/// 대량 번역 설정에서 원격 STT·번역 서버(STTLMMServer)를 주소만으로 등록합니다.
/// 등록된 서버는 앱 전체가 공유하므로 설정 화면에서 추가한 서버도 여기에 함께 보입니다.
private struct BatchRemoteServerSection: View {
    @State private var pool = RemoteWorkerPool.shared
    @State private var address = ""
    @State private var name = ""
    @State private var token = ""
    @State private var usesAuthentication = false
    @State private var message = ""
    @State private var isAdding = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if pool.workers.isEmpty {
                    Text("등록된 원격 서버가 없습니다. 주소를 입력하면 STT와 번역을 그 서버에서 처리합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pool.workers) { (worker: RemoteWorkerConfiguration) in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(worker.isEnabled ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(worker.name).font(.callout)
                                Text(worker.baseURL.absoluteString)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if case let .available(status) = pool.states[worker.id] {
                                // 서버마다 자리 수가 달라, 여유가 많은 쪽으로 더 많이 배분됩니다.
                                Text("STT \(status.capabilities.sttSlots) · 번역 \(status.capabilities.translationSlots) · 사용 \(pool.activeLeaseCount(for: worker.id))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Button(worker.isEnabled ? "사용 중지" : "사용") {
                                pool.setEnabled(!worker.isEnabled, for: worker.id)
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            Button("제거", systemImage: "trash") { pool.remove(worker.id) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("서버 주소", text: $address, prompt: Text("예: 192.168.0.20 또는 http://mac-server:8848"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { connect() }
                    TextField("이름 (선택)", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                }
                HStack(spacing: 8) {
                    Toggle("API 키 사용", isOn: $usesAuthentication)
                        .controlSize(.small)
                    if usesAuthentication {
                        SecureField("개별 키 (선택)", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }
                    Spacer()
                    Button("연결 후 추가", systemImage: "link.badge.plus") { connect() }
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
                    if isAdding { ProgressView().controlSize(.small) }
                    Button("상태 확인", systemImage: "arrow.clockwise") {
                        Task { await pool.refreshAll() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(pool.workers.isEmpty || isAdding)
                }
                if !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !pool.workers.isEmpty {
                    Text("서버 \(pool.workers.count)대 합계 · STT \(pool.totalSTTSlots)자리 · 번역 \(pool.totalTranslationSlots)자리 — 가장 한가한 서버로 자동 분산됩니다.")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text("IP만 입력하면 http와 기본 포트 8848을 적용합니다. 서버를 여러 대 추가하면 요청이 나뉘어 나가고, 연결이 안 되면 자동으로 내장 서버로 넘어갑니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        } label: {
            Label("원격 STT·번역 서버", systemImage: "network")
        }
        .task { await pool.refreshAll() }
    }

    private func connect() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isAdding, !trimmed.isEmpty else { return }
        isAdding = true
        message = String(localized: "서버 연결을 확인하는 중…")
        Task {
            defer { isAdding = false }
            do {
                let status = try await pool.connectAndAdd(
                    name: name,
                    address: trimmed,
                    token: token,
                    usesAuthentication: usesAuthentication
                )
                address = ""
                name = ""
                token = ""
                message = String(localized: "추가 완료 · \(status.name) · STT \(status.capabilities.sttSlots)개 · 번역 \(status.capabilities.translationSlots)개")
            } catch {
                message = String(localized: "추가하지 못했습니다: \(error.localizedDescription)")
            }
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
    let onRestart: () -> Void
    let onReanalyzeSpeakers: () -> Void
    let onRedoFromScratch: () -> Void
    let onPause: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    let canRestart: Bool
    /// 이미 결과가 있는 항목을 다시 처리할 수 있는지. 완료 항목도 포함합니다.
    private var canRerun: Bool { item.isFinished && !item.isProcessing }
    let canPause: Bool
    let canCancel: Bool
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
        .contextMenu {
            Button("재시작", systemImage: "arrow.clockwise", action: onRestart)
                .disabled(!canRestart)
            Button("화자 다시 분석", systemImage: "person.text.rectangle", action: onReanalyzeSpeakers)
                .disabled(!canRerun)
            Button("STT·번역 다시 하기", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", role: .destructive, action: onRedoFromScratch)
                .disabled(!canRerun)
            Button("일시 정지", systemImage: "pause.fill", action: onPause)
                .disabled(!canPause)
            Button("취소", systemImage: "stop.fill", role: .destructive, action: onCancel)
                .disabled(!canCancel)
            Divider()
            Button("목록에서 삭제", systemImage: "trash", role: .destructive, action: onRemove)
        }
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
        case .paused: "일시 정지됨"
        case .cancelled: "취소됨"
        default: "처리 중"
        }
    }

    private var statusSymbol: String {
        switch item.status {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .cancelled: "stop.circle.fill"
        case .queued where !item.isProcessing: "clock"
        default: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: .green
        case .failed: .red
        case .paused: .orange
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

/// 원격 서버 이상을 경고창으로 알립니다. 같은 상황에서는 한 번만 띄우고,
/// 응답이 없는 경우는 완료 시점이 없으므로 주기적으로 다시 판정합니다.
private struct RemoteServerHealthAlert: ViewModifier {
    @State private var metrics = RemoteServerMetrics.shared
    @State private var pool = RemoteWorkerPool.shared
    @State private var showing = false
    @State private var current: RemoteServerMetrics.HealthWarning?

    func body(content: Content) -> some View {
        content
            .task {
                while !Task.isCancelled {
                    metrics.evaluateHealth()
                    if !showing, let warning = metrics.pendingWarning {
                        current = warning
                        showing = true
                    }
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .alert(alertTitle, isPresented: $showing, presenting: current) { warning in
                Button("이 서버 사용 중지", role: .destructive) {
                    pool.setEnabled(false, for: warning.id)
                    metrics.acknowledge(warning)
                }
                Button("상태 확인") {
                    metrics.acknowledge(warning)
                    Task { await pool.refresh(warning.id) }
                }
                Button("계속 사용", role: .cancel) { metrics.acknowledge(warning) }
            } message: { warning in
                Text(warning.reasons.joined(separator: "\n"))
            }
    }

    private var alertTitle: LocalizedStringKey {
        switch current?.severity {
        case .failing: "\(current?.serverName ?? "") 서버 요청이 계속 실패합니다"
        case .stalled: "\(current?.serverName ?? "") 서버가 응답하지 않습니다"
        case .slow: "\(current?.serverName ?? "") 서버가 느립니다"
        case nil: "원격 서버 확인"
        }
    }
}

extension View {
    func remoteServerHealthAlert() -> some View {
        modifier(RemoteServerHealthAlert())
    }
}

/// 외부 STTLMMServer와 오가는 요청의 성능을 서버별로 보여 줍니다.
/// 어느 서버가 느린지, 전송·대기에 얼마를 쓰는지, 실제로 분산되고 있는지 확인하는 용도입니다.
struct RemoteServerMonitorView: View {
    @State private var metrics = RemoteServerMetrics.shared
    @State private var pool = RemoteWorkerPool.shared

    private func seconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value < 1
            ? String(format: "%.0fms", value * 1000)
            : String(format: "%.1fs", value)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if !metrics.hasRecords {
                    Text("아직 원격 요청이 없습니다. 대량 번역을 시작하면 서버별 성능이 여기에 쌓입니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // 합계 — 전체 흐름을 한 줄로 파악합니다.
                    HStack(spacing: 14) {
                        summary("요청", "\(metrics.totalRequests)")
                        summary("진행 중", "\(metrics.totalInFlight)")
                        summary("실패", "\(metrics.totalFailures)", tint: metrics.totalFailures > 0 ? .orange : nil)
                        summary("전송량", ByteCountFormatter.string(fromByteCount: metrics.totalUploadedBytes, countStyle: .file))
                        summary("전사 오디오", String(format: "%.0f분", metrics.totalAudioSeconds / 60))
                        summary("번역 구간", "\(metrics.totalTranslatedTexts)")
                    }
                    .font(.caption.monospacedDigit())

                    Divider()

                    ForEach(metrics.orderedStats) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(entry.totalInFlight > 0 ? Color.green : Color.secondary.opacity(0.5))
                                    .frame(width: 7, height: 7)
                                Text(entry.name).font(.callout.weight(.medium))
                                if entry.totalInFlight > 0 {
                                    Text("진행 \(entry.totalInFlight)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.green)
                                }
                                Spacer()
                                if let factor = entry.effectiveRealtimeFactor {
                                    // 서버가 보고하는 배속과 달리 전송 시간까지 포함한 체감 속도입니다.
                                    Text(String(format: "체감 %.0f배속", factor))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                if let reported = entry.lastRealtimeFactor {
                                    Text(String(format: "서버 %.0f배속", reported))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            ForEach(RemoteServerMetrics.Kind.allCases, id: \.self) { kind in
                                let count = entry.requests[kind] ?? 0
                                if count > 0 || (entry.inFlight[kind] ?? 0) > 0 {
                                    HStack(spacing: 10) {
                                        Text(kind.title).frame(width: 34, alignment: .leading)
                                        Text("\(count)회")
                                        Text("평균 \(seconds(entry.averageRoundTrip(kind)))")
                                        if let overhead = entry.overheadRatio(kind) {
                                            Text("전송·대기 \(Int(overhead * 100))%")
                                                .foregroundStyle(overhead > 0.5 ? Color.orange : Color.secondary)
                                        }
                                        if let failures = entry.failures[kind], failures > 0 {
                                            Text("실패 \(failures)").foregroundStyle(.orange)
                                        }
                                        Spacer()
                                    }
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                            }
                            if let error = entry.lastError {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                HStack {
                    if !pool.workers.isEmpty {
                        Text("등록 서버 \(pool.workers.count)대 · STT \(pool.totalSTTSlots)자리 · 번역 \(pool.totalTranslationSlots)자리")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("기록 지우기", systemImage: "arrow.counterclockwise") { metrics.reset() }
                        .labelStyle(.titleOnly)
                        .controlSize(.small)
                        .disabled(!metrics.hasRecords)
                }
            }
            .padding(4)
        } label: {
            Label("원격 서버 성능", systemImage: "gauge.with.dots.needle.33percent")
        }
    }

    private func summary(_ title: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).foregroundStyle(tint ?? .primary)
        }
    }
}

/// 주의가 필요한 영상(실패·취소·일시정지)의 원인을 실제로 진단하고, 손상된 파일을 정리합니다.
private struct AttentionReviewView: View {
    @Environment(BatchProcessor.self) private var processor
    @Environment(\.dismiss) private var dismiss
    @State private var diagnoses: [MediaDiagnosis] = []
    @State private var isDiagnosing = false
    @State private var progress = ""
    @State private var statusMessage = ""
    @State private var moveToTrash = true

    private var brokenDiagnoses: [MediaDiagnosis] {
        diagnoses.filter { $0.verdict.isFileProblem }
    }

    private var reclaimable: String {
        ByteCountFormatter.string(
            fromByteCount: brokenDiagnoses.reduce(0) { $0 + $1.byteCount },
            countStyle: .file
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("주의 필요 항목 점검", systemImage: "stethoscope")
                    .font(.title2.weight(.semibold))
                Text("실패·취소·일시정지된 영상을 실제로 열어 원인을 판정합니다. 파일 손상이 확인된 것만 정리 대상으로 표시합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if isDiagnosing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout)
                }
            } else if diagnoses.isEmpty {
                ContentUnavailableView(
                    "점검할 항목이 없습니다",
                    systemImage: "checkmark.shield",
                    description: Text("주의가 필요한 영상이 없거나, 아직 점검하지 않았습니다.")
                )
                .frame(maxHeight: 160)
            } else {
                HStack(spacing: 12) {
                    Text("점검 \(diagnoses.count)건")
                    if brokenDiagnoses.isEmpty {
                        Label("파일 문제 없음", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("손상 \(brokenDiagnoses.count)건 · \(reclaimable)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
                .font(.callout.weight(.medium))

                List(diagnoses) { diagnosis in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: diagnosis.verdict.isFileProblem ? "xmark.circle.fill" : "info.circle")
                            .foregroundStyle(diagnosis.verdict.isFileProblem ? Color.orange : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(diagnosis.url.lastPathComponent)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(diagnosis.verdict.title)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        (diagnosis.verdict.isFileProblem ? Color.orange : Color.secondary).opacity(0.18),
                                        in: Capsule()
                                    )
                            }
                            Text(diagnosis.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if diagnosis.byteCount > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: diagnosis.byteCount, countStyle: .file))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 240, maxHeight: 340)

                if !brokenDiagnoses.isEmpty {
                    Toggle(isOn: $moveToTrash) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("원본 파일도 휴지통으로 이동")
                            Text(moveToTrash
                                ? "손상이 확인된 \(brokenDiagnoses.count)개 파일이 휴지통으로 이동합니다. 되돌릴 수 있습니다."
                                : "목록에서만 제거하고 파일은 그대로 둡니다.")
                                .font(.caption)
                                .foregroundStyle(moveToTrash ? Color.orange : Color.secondary)
                        }
                    }
                }
            }

            if !statusMessage.isEmpty {
                Text(statusMessage).font(.caption).textSelection(.enabled)
            }

            HStack {
                Button("다시 점검", systemImage: "arrow.clockwise") { Task { await runDiagnosis() } }
                    .disabled(isDiagnosing)
                Spacer()
                Button("닫기") { dismiss() }
                Button(moveToTrash ? "손상 파일 휴지통으로" : "손상 항목 목록에서 제거", role: .destructive) {
                    cleanUp()
                }
                .buttonStyle(.borderedProminent)
                .disabled(brokenDiagnoses.isEmpty || isDiagnosing)
            }
        }
        .padding(24)
        .frame(width: 660)
        .task { if diagnoses.isEmpty { await runDiagnosis() } }
    }

    private func runDiagnosis() async {
        let targets = processor.attentionItems
        guard !targets.isEmpty else {
            diagnoses = []
            return
        }
        isDiagnosing = true
        defer { isDiagnosing = false }
        var results: [MediaDiagnosis] = []
        for (index, item) in targets.enumerated() {
            progress = String(localized: "\(index + 1)/\(targets.count) 점검 중 · \(item.url.lastPathComponent)")
            results.append(await MediaDiagnostics.diagnose(itemID: item.id, url: item.url))
        }
        // 손상된 것을 위로 올려 바로 보이게 합니다.
        diagnoses = results.sorted { lhs, rhs in
            lhs.verdict.isFileProblem && !rhs.verdict.isFileProblem
        }
    }

    private func cleanUp() {
        let ids = Set(brokenDiagnoses.map(\.id))
        guard !ids.isEmpty else { return }
        Task {
            if moveToTrash {
                let result = await processor.moveVideosToTrash(ids: ids)
                statusMessage = result.failureMessage
                    ?? String(localized: "\(result.movedCount)개를 휴지통으로 옮겼습니다.")
            } else {
                processor.remove(ids: ids)
                statusMessage = String(localized: "\(ids.count)개를 목록에서 제거했습니다.")
            }
            await runDiagnosis()
        }
    }
}

/// 파일명이 달라도 내용이 같은 영상을 찾아 정리합니다.
private struct ContentDuplicateReviewView: View {
    @Environment(BatchProcessor.self) private var processor
    @Environment(\.dismiss) private var dismiss
    @State private var moveToTrash = false
    @State private var isCleaning = false
    @State private var statusMessage = ""

    private var reclaimable: String {
        ByteCountFormatter.string(fromByteCount: processor.contentDuplicateReclaimableBytes, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("같은 내용 중복 정리", systemImage: "doc.viewfinder")
                    .font(.title2.weight(.semibold))
                Text("파일 크기와 앞뒤 4MB를 비교해 이름이 달라도 같은 영상을 찾습니다. 묶음마다 첫 번째 하나만 남깁니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if processor.isScanningContentDuplicates {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(processor.contentDuplicateMessage)
                        .font(.callout)
                }
            } else if processor.contentDuplicateGroups.isEmpty {
                ContentUnavailableView(
                    processor.contentDuplicateMessage.isEmpty ? "아직 검사하지 않았습니다" : "중복 없음",
                    systemImage: "checkmark.circle",
                    description: Text(processor.contentDuplicateMessage.isEmpty
                        ? "‘검사 시작’을 누르면 목록의 영상을 비교합니다."
                        : processor.contentDuplicateMessage)
                )
                .frame(maxHeight: 180)
            } else {
                Text("\(processor.contentDuplicateGroups.count)묶음 · 정리 시 \(reclaimable) 확보")
                    .font(.callout.weight(.medium))
                List {
                    ForEach(processor.contentDuplicateGroups) { group in
                        Section(ByteCountFormatter.string(fromByteCount: group.byteCount, countStyle: .file)) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                HStack(spacing: 8) {
                                    Image(systemName: index == 0 ? "checkmark.circle.fill" : "minus.circle")
                                        .foregroundStyle(index == 0 ? Color.green : Color.orange)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.url.lastPathComponent).font(.callout)
                                        Text(item.url.deletingLastPathComponent().path(percentEncoded: false))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(index == 0 ? "유지" : "정리")
                                        .font(.caption2)
                                        .foregroundStyle(index == 0 ? .green : .orange)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 320)

                Toggle(isOn: $moveToTrash) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("원본 파일도 휴지통으로 이동")
                        Text(moveToTrash
                            ? "디스크의 실제 영상 파일이 휴지통으로 이동합니다. 휴지통에서 되돌릴 수 있습니다."
                            : "목록에서만 제거하고 파일은 그대로 둡니다.")
                            .font(.caption)
                            .foregroundStyle(moveToTrash ? Color.orange : Color.secondary)
                    }
                }
            }

            if !statusMessage.isEmpty {
                Text(statusMessage).font(.caption).textSelection(.enabled)
            }

            HStack {
                Button("검사 시작", systemImage: "magnifyingglass") {
                    Task { await processor.scanContentDuplicates() }
                }
                .disabled(processor.isScanningContentDuplicates || isCleaning)
                Spacer()
                Button("닫기") { dismiss() }
                Button(moveToTrash ? "휴지통으로 이동" : "목록에서 제거", role: .destructive) {
                    cleanUp()
                }
                .buttonStyle(.borderedProminent)
                .disabled(processor.contentDuplicateGroups.isEmpty || isCleaning)
                if isCleaning { ProgressView().controlSize(.small) }
            }
        }
        .padding(24)
        .frame(width: 620)
        .task { if processor.contentDuplicateGroups.isEmpty { await processor.scanContentDuplicates() } }
    }

    private func cleanUp() {
        let ids = processor.contentDuplicateRemovalIDs
        guard !ids.isEmpty else { return }
        isCleaning = true
        Task {
            defer { isCleaning = false }
            if moveToTrash {
                let result = await processor.moveVideosToTrash(ids: ids)
                statusMessage = result.failureMessage
                    ?? String(localized: "\(result.movedCount)개를 휴지통으로 옮겼습니다.")
            } else {
                processor.remove(ids: ids)
                statusMessage = String(localized: "\(ids.count)개를 목록에서 제거했습니다.")
            }
            await processor.scanContentDuplicates()
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
            PlayerVideoSurface(player: model.player)
                .background(.black)
                .overlay(alignment: .bottom) {
                    PlayerControlBar(
                        volume: Binding(
                            get: { Double(model.player.volume) },
                            set: { model.player.volume = Float($0) }
                        ),
                        currentTime: model.currentTime,
                        duration: model.duration,
                        isPlaying: model.isPlaying,
                        onTogglePlayback: { model.togglePlayback() },
                        onSeek: { model.seekVideo(to: $0) }
                    )
                    .padding(.bottom, 12)
                }
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
