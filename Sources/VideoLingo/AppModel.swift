import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Observation
import Vision
import VideoLingoCore

enum PlayerWorkspaceMode: String, CaseIterable, Identifiable {
    case translation
    case viewing

    var id: Self { self }
    var title: String { self == .translation ? "번역 모드" : "영상 감상 모드" }
    var symbol: String { self == .translation ? "character.book.closed" : "play.rectangle.fill" }
}

@MainActor
@Observable
final class AppModel {
    /// 첫 창에서만 마지막으로 열었던 영상을 복원하기 위한 프로세스 전역 플래그입니다.
    static var hasAutoloadedInitialVideo = false

    var mediaURL: URL?
    var player = AVPlayer()
    var selectedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "ko" {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: "selectedLanguage") }
    }
    var targetLanguages: [String] = UserDefaults.standard.stringArray(forKey: "targetLanguages") ?? ["ko"] {
        didSet { UserDefaults.standard.set(targetLanguages, forKey: "targetLanguages") }
    }
    var sourceLanguage = UserDefaults.standard.string(forKey: "sourceLanguage") ?? "" {
        didSet { UserDefaults.standard.set(sourceLanguage, forKey: "sourceLanguage") }
    }
    var sttModel = UserDefaults.standard.string(forKey: "sttModel") ?? "large-v3-v20240930_626MB" {
        didSet { UserDefaults.standard.set(sttModel, forKey: "sttModel") }
    }
    var translationModel = AppModel.initialTranslationModel() {
        didSet { UserDefaults.standard.set(translationModel, forKey: "translationModel") }
    }
    var synthesizeSpeech = false
    var qualityMode = ProcessingQualityMode(rawValue: UserDefaults.standard.string(forKey: "qualityMode") ?? "enhanced") ?? .enhanced {
        didSet { UserDefaults.standard.set(qualityMode.rawValue, forKey: "qualityMode") }
    }
    var glossaryText = UserDefaults.standard.string(forKey: "qualityGlossary") ?? "" {
        didSet { UserDefaults.standard.set(glossaryText, forKey: "qualityGlossary") }
    }
    var continuousImprovement = UserDefaults.standard.object(forKey: "continuousQualityImprovement") as? Bool ?? true {
        didSet { UserDefaults.standard.set(continuousImprovement, forKey: "continuousQualityImprovement") }
    }
    var autoRetryUntranslated = UserDefaults.standard.object(forKey: "autoRetryUntranslated") as? Bool
        ?? UserDefaults.standard.object(forKey: "autoRetryReviewedAndUntranslated") as? Bool
        ?? true {
        didSet { UserDefaults.standard.set(autoRetryUntranslated, forKey: "autoRetryUntranslated") }
    }
    var showOriginalWithTranslation = UserDefaults.standard.object(forKey: "showOriginalWithTranslation") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showOriginalWithTranslation, forKey: "showOriginalWithTranslation") }
    }
    var originalSubtitleTranslucent = UserDefaults.standard.object(forKey: "originalSubtitleTranslucent") as? Bool ?? true {
        didSet { UserDefaults.standard.set(originalSubtitleTranslucent, forKey: "originalSubtitleTranslucent") }
    }
    var originalSubtitleItalic = UserDefaults.standard.object(forKey: "originalSubtitleItalic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(originalSubtitleItalic, forKey: "originalSubtitleItalic") }
    }
    var subtitlesEnabled = UserDefaults.standard.object(forKey: "subtitlesEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(subtitlesEnabled, forKey: "subtitlesEnabled") }
    }

    // 화면 글자 OCR 번역 자막 (재생 중 실시간). recognized→translated는 Translation 프레임워크가 채웁니다.
    static let screenTextTranslationTemporarilyDisabled = true
    var screenTextTranslationEnabled = false {
        didSet {
            guard !Self.screenTextTranslationTemporarilyDisabled else {
                screenTextTranslationEnabled = false
                UserDefaults.standard.set(false, forKey: "screenTextTranslation")
                screenTextTask?.cancel()
                recognizedScreenText = nil
                translatedScreenText = nil
                return
            }
            UserDefaults.standard.set(screenTextTranslationEnabled, forKey: "screenTextTranslation")
            startScreenTextLoop()
        }
    }
    var recognizedScreenText: String?
    var translatedScreenText: String?

    // 동작 설정 (적용된 기능들을 설정에서 변경) — 앱 재시작 후 반영
    var startMuted = UserDefaults.standard.object(forKey: "startMuted") as? Bool ?? true {
        didSet { UserDefaults.standard.set(startMuted, forKey: "startMuted") }
    }
    var autoloadLastVideoPreference = UserDefaults.standard.object(forKey: "autoloadLastVideo") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoloadLastVideoPreference, forKey: "autoloadLastVideo") }
    }
    var rememberPlaybackPosition = UserDefaults.standard.object(forKey: "rememberPlaybackPosition") as? Bool ?? true {
        didSet { UserDefaults.standard.set(rememberPlaybackPosition, forKey: "rememberPlaybackPosition") }
    }
    var volumeAdjustmentStep: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "volumeAdjustmentStep")
            return [0.01, 0.02, 0.05, 0.10].contains(stored) ? stored : 0.10
        }
        set {
            let allowed = [0.01, 0.02, 0.05, 0.10]
            UserDefaults.standard.set(
                allowed.contains(newValue) ? newValue : 0.10,
                forKey: "volumeAdjustmentStep"
            )
        }
    }

    // 얼굴 모자이크 제거(디모자이크) 옵션
    var demosaicModel = DemosaicModel(rawValue: UserDefaults.standard.string(forKey: "demosaicModel") ?? "classical") ?? .classical {
        didSet { UserDefaults.standard.set(demosaicModel.rawValue, forKey: "demosaicModel") }
    }
    var demosaicRegionMode = DemosaicRegionMode(rawValue: UserDefaults.standard.string(forKey: "demosaicRegionMode") ?? "") ?? .face {
        didSet { UserDefaults.standard.set(demosaicRegionMode.rawValue, forKey: "demosaicRegionMode") }
    }
    var demosaicFidelity = UserDefaults.standard.object(forKey: "demosaicFidelity") as? Double ?? 0.7 {
        didSet { UserDefaults.standard.set(demosaicFidelity, forKey: "demosaicFidelity") }
    }
    var demosaicWatermark = UserDefaults.standard.object(forKey: "demosaicWatermark") as? Bool ?? true {
        didSet { UserDefaults.standard.set(demosaicWatermark, forKey: "demosaicWatermark") }
    }
    var maximumRefinementPasses = UserDefaults.standard.object(forKey: "maximumRefinementPasses") == nil
        ? 3
        : max(1, UserDefaults.standard.integer(forKey: "maximumRefinementPasses")) {
        didSet { UserDefaults.standard.set(maximumRefinementPasses, forKey: "maximumRefinementPasses") }
    }
    /// 단축키를 누를 때마다 순환하는 창 불투명도 단계입니다. (75% → 50% → 25% → 100%)
    static let translucencyLevels: [Double] = [0.75, 0.5, 0.25, 1.0]

    var windowOpacity: Double = {
        guard let stored = UserDefaults.standard.object(forKey: "windowOpacity") as? Double else { return 1 }
        return min(1, max(0.1, stored))
    }() {
        didSet {
            UserDefaults.standard.set(windowOpacity, forKey: "windowOpacity")
            applyWindowTransparency()
        }
    }

    /// 설정 화면의 반투명 토글 등 Bool 소비자를 위한 파생 속성입니다.
    var translucentMode: Bool {
        get { windowOpacity < 1 }
        set { windowOpacity = newValue ? (windowOpacity < 1 ? windowOpacity : 0.75) : 1 }
    }

    // 창별 보기 모드입니다. 창마다 전체보기·심플 보기·미니 뷰어를 독립적으로 전환합니다.
    var isSimpleMode = false
    var playerMode = PlayerWorkspaceMode(
        rawValue: UserDefaults.standard.string(forKey: "playerWorkspaceMode") ?? "translation"
    ) ?? .translation {
        didSet { UserDefaults.standard.set(playerMode.rawValue, forKey: "playerWorkspaceMode") }
    }
    var isMiniViewer = false
    var hideTranscriptPanel = false
    /// macOS 네이티브 전체화면에서는 영상 이외의 앱 UI를 감추는 영화관 보기로 전환합니다.
    var isTheaterMode = false
    var snapshot: JobSnapshot?
    var transcript: [TranscriptSegment] = []
    var translations: [UUID: TranslationSegment] = [:]
    var currentTime: TimeInterval = 0
    var errorMessage: String?
    var serviceMessage = String(localized: "서비스 확인 중")
    var serviceStatus: AIServiceStatus?
    var serviceIsAvailable = false
    var isRestartingService = false
    var databaseStatistics = DatabaseStatistics(jobCount: 0, transcriptCount: 0, translationCount: 0)
    var databaseSizeInBytes: Int64 = 0
    var managedModels: [ManagedModelRecord] = []
    var settingsMessage = ""
    var settingsIsBusy = false
    var resultDirectoryURL: URL?
    var isExportingMobilePackage = false
    var mobileExportMessage = ""

    let languages = ["ko", "en", "ja", "zh", "es", "fr", "de", "pt", "it"]
    let sourceLanguages = [
        "", "ko", "ja", "en", "zh", "es", "fr", "de", "pt", "it",
        "ru", "ar", "hi", "vi", "th", "id", "tr", "nl", "pl", "sv"
    ]
    let models = ["large-v3-v20240930_626MB", "small", "base", "tiny"]
    let translationModels = [
        "apple-foundation-models",
        "mlx-community/Qwen3-0.6B-4bit",
        "mlx-community/Qwen3-1.7B-4bit",
        "mlx-community/Qwen3-4B-4bit",
        "mlx-community/Qwen3-8B-4bit",
        "mlx-community/gemma-3-1b-it-qat-4bit"
    ]

    private var videoOutput: AVPlayerItemVideoOutput?
    /// 새 작업은 60초를 사용하고, 저장된 작업을 재개할 때는 기존 청크 경계를 보존합니다.
    private var processingChunkDuration = ProcessingOptions.defaultChunkDuration
    private var screenTextTask: Task<Void, Never>?
    private var lastPositionSaveWallTime: TimeInterval = 0
    private var currentJobID: UUID?
    private var autoRetriedJobIDs: Set<UUID> = []
    private var pendingRetryChunkIndices: Set<Int> = []
    private var databaseURL: URL?
    private var workspaceURL: URL?
    private var persistentStore: JobStore?
    private var connection: NSXPCConnection?
    private var connectionGeneration = UUID()
    private var statusTask: Task<Void, Never>?
    private var serviceHealthTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var currentRequest: StartJobRequest?
    private var pendingResumeAfterRestart = false
    private var timeObserver: Any?

    init(autoloadLastVideo: Bool = true) {
        if !targetLanguages.contains(selectedLanguage) {
            targetLanguages.append(selectedLanguage)
        }
        // 시작 시 무음 설정(기본 켜짐). 사용자가 음량을 올리면 그때부터 소리가 납니다.
        if startMuted { player.volume = 0 }
        setupPlayerObserver()
        connectService()
        beginServiceMonitoring()
        if autoloadLastVideo {
            AppModel.hasAutoloadedInitialVideo = true
            restoreLastVideo()
        }
        if screenTextTranslationEnabled { startScreenTextLoop() }
    }

    var activeTranscriptSegment: TranscriptSegment? {
        transcript.first { segment in
            let cues = segment.cues ?? []
            if cues.isEmpty {
                return currentTime >= segment.startTime && currentTime < segment.endTime
            }
            return cues.contains { currentTime >= $0.startTime && currentTime < $0.endTime }
        }
    }

    var activeOriginalSubtitle: String {
        guard let segment = activeTranscriptSegment else { return "" }
        let cues = segment.cues ?? []
        guard !cues.isEmpty,
              let cue = cues.first(where: { currentTime >= $0.startTime && currentTime < $0.endTime }) else {
            return segment.text
        }
        return cue.text
    }

    var activeTranslationSubtitle: String? {
        guard let segment = activeTranscriptSegment,
              let translation = translations[segment.id]?.text,
              !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let cues = segment.cues ?? []
        guard !cues.isEmpty,
              let cueIndex = cues.firstIndex(where: { currentTime >= $0.startTime && currentTime < $0.endTime }) else {
            return translation
        }
        let translatedLines = translation
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return translatedLines.indices.contains(cueIndex) ? translatedLines[cueIndex] : translation
    }

    var activeSubtitle: String {
        activeTranslationSubtitle ?? activeOriginalSubtitle
    }

    var canStart: Bool {
        guard mediaURL != nil else { return false }
        guard let status = snapshot?.status else { return true }
        return ![.queued, .extracting, .transcribing, .translating, .synthesizing, .refining].contains(status)
    }

    var canMutateStorage: Bool {
        snapshot.map { !activeStatuses.contains($0.status) } ?? true
    }

    var canRegenerate: Bool {
        mediaURL != nil && canMutateStorage
    }

    var canRegenerateSTT: Bool {
        canRegenerate && !transcript.isEmpty
    }

    /// 첫 STT 추출이 끝나(전사 결과가 있으면) 초기 STT/번역 진행 중이 아니라면,
    /// 품질 개선 등 후속 작업 중에도 특정 구간 재추출을 허용합니다.
    var canRegenerateSegment: Bool {
        guard mediaURL != nil, !transcript.isEmpty else { return false }
        guard let status = snapshot?.status else { return true }
        // 초기 추출/번역 중에는 실행 파이프라인과 충돌 위험이 커서 막습니다.
        let initialStatuses: Set<JobStatus> = [.queued, .extracting, .transcribing, .translating, .synthesizing]
        return !initialStatuses.contains(status)
    }

    var glossaryEntries: [GlossaryEntry] {
        glossaryText.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return GlossaryEntry(source: parts[0], target: parts[1])
        }
    }

    func sourceLanguageName(_ code: String) -> String {
        guard !code.isEmpty else { return String(localized: "자동 감지") }
        let localized = Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
        return "\(localized) (\(code.uppercased()))"
    }

    func toggleTargetLanguage(_ language: String) {
        if targetLanguages.contains(language) {
            guard targetLanguages.count > 1 else {
                errorMessage = String(localized: "번역 언어는 하나 이상 선택해야 합니다.")
                return
            }
            targetLanguages.removeAll { $0 == language }
            if selectedLanguage == language, let first = targetLanguages.first {
                selectedLanguage = first
            }
        } else {
            targetLanguages.append(language)
            targetLanguages.sort {
                (languages.firstIndex(of: $0) ?? .max) < (languages.firstIndex(of: $1) ?? .max)
            }
            selectedLanguage = language
        }
        refreshResults()
    }

    /// 단축키를 누를 때마다 75% → 50% → 25% → 100% 순으로 창 투명도를 조정합니다.
    func cycleTranslucency() {
        let levels = AppModel.translucencyLevels
        let currentIndex = levels.firstIndex { abs($0 - windowOpacity) < 0.001 } ?? (levels.count - 1)
        windowOpacity = levels[(currentIndex + 1) % levels.count]
    }

    func hideApplication() {
        NSApp.hide(nil)
    }

    /// 현재 활성 창을 macOS 네이티브 전체화면으로 전환합니다. (창마다 독립적으로 동작)
    func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }

    func applyWindowTransparency() {
        // 창별 투명도는 각 창의 WindowModeAccessor가 자기 NSWindow에만 반영하므로
        // 여기서 전역으로 창을 순회하지 않습니다. (다중 창에서 서로의 투명도를 덮어쓰지 않도록)
    }

    func openVideo() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "번역할 MP4 영상을 선택하세요")
        panel.allowedContentTypes = [.mpeg4Movie, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url, remember: true)
    }

    /// 대량 번역과 동일한 작업 키로 저장된 STT·번역을 불러오는 완료 결과 검토용 진입점입니다.
    func loadBatchReviewVideo(_ url: URL, options: ProcessingOptions) {
        sourceLanguage = options.sourceLanguage ?? ""
        targetLanguages = options.targetLanguages
        if !targetLanguages.contains(selectedLanguage) {
            selectedLanguage = targetLanguages.first ?? selectedLanguage
        }
        sttModel = options.sttModel
        applyRestoredTranslationModel(options.translationModel)
        if let batchQualityMode = options.qualityMode {
            qualityMode = batchQualityMode
        }
        processingChunkDuration = options.chunkDuration
        playerMode = .viewing
        let jobID = Self.stableJobID(
            forPath: url.path,
            sttModel: options.sttModel,
            sourceLanguage: options.sourceLanguage ?? "",
            chunkDuration: options.chunkDuration
        )
        loadVideo(url, remember: false, preferredJobID: jobID)
    }

    func seekVideo(by seconds: TimeInterval) {
        guard player.currentItem != nil else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        var target = max(0, current + seconds)
        let duration = player.currentItem?.duration.seconds ?? 0
        if duration.isFinite, duration > 0 {
            target = min(target, duration)
        }
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)
        )
    }

    func togglePlayback() {
        guard player.currentItem != nil else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    func adjustVolume(by amount: Double) {
        player.volume = min(1, max(0, player.volume + Float(amount)))
    }

    func startOrResume() {
        guard let mediaURL else { return }
        errorMessage = nil
        do {
            let paths = try AppPaths()
            let jobID = stableJobID(for: mediaURL)
            if currentJobID != jobID {
                transcript = []
                translations = [:]
                snapshot = nil
            }
            currentJobID = jobID
            let options = currentProcessingOptions()
            let request = try makeRequest(jobID: jobID, mediaURL: mediaURL, paths: paths, options: options)
            currentRequest = request
            let store = try store(at: paths.database)
            try store.createJob(id: jobID, mediaURL: mediaURL, options: options)
            snapshot = JobSnapshot(id: jobID, status: .queued, message: String(localized: "AI 서비스에 작업 전달 중"))
            sendStart(request)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        guard let id = currentJobID, let service = remoteService() else { return }
        service.cancelJob(id.uuidString) { _ in }
    }

    var canStartDemosaic: Bool { mediaURL != nil && canMutateStorage }

    /// 현재 영상의 얼굴 모자이크 제거를 시작합니다. (STT·번역과 별개의 작업)
    func startDemosaic() {
        guard let mediaURL, canStartDemosaic else { return }
        errorMessage = nil
        do {
            let paths = try AppPaths()
            let jobID = UUID()
            let workspace = paths.workspace(for: jobID)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let bookmark = try? mediaURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let options = DemosaicOptions(
                model: demosaicModel,
                regionMode: demosaicRegionMode,
                fidelity: demosaicFidelity,
                temporalStabilization: true,
                watermarkSynthetic: demosaicWatermark
            )
            let request = StartDemosaicRequest(
                jobID: jobID,
                mediaURL: mediaURL,
                securityScopedBookmark: bookmark,
                options: options,
                databaseURL: paths.database,
                workspaceURL: workspace,
                modelsURL: paths.models,
                uiLanguageCode: LocalizationManager.shared.language.localeCode
            )
            currentJobID = jobID
            currentRequest = nil
            resultDirectoryURL = workspace
            snapshot = JobSnapshot(id: jobID, status: .queued, message: String(localized: "모자이크 제거 준비 중"))
            guard let service = remoteService() else {
                errorMessage = VideoLingoError.serviceUnavailable.localizedDescription
                return
            }
            let payload = try WireCodec.encode(request)
            service.startDemosaic(payload) { [weak self] data, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error { self.errorMessage = error; return }
                    if let data { self.snapshot = try? WireCodec.decode(JobSnapshot.self, from: data) }
                    self.beginPolling()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func regenerateSTTAndTranslations() {
        guard canRegenerate, let mediaURL else { return }
        errorMessage = nil
        do {
            let paths = try AppPaths()
            let store = try store(at: paths.database)
            if let currentJobID {
                try store.deleteJob(jobID: currentJobID)
            }
            try MediaSidecarStore.deleteAllGeneratedResults(for: mediaURL)
            let newJobID = UUID()
            UserDefaults.standard.set(newJobID.uuidString, forKey: stableJobKey(for: mediaURL))
            currentJobID = nil
            currentRequest = nil
            snapshot = nil
            transcript = []
            translations = [:]
            processingChunkDuration = ProcessingOptions.defaultChunkDuration
            startOrResume()
        } catch {
            errorMessage = String(localized: "STT·번역 재생성 준비 실패: \(error.localizedDescription)")
        }
    }

    func regenerateTranslations() {
        guard canRegenerate,
              let mediaURL,
              let currentJobID else { return }
        errorMessage = nil
        do {
            let paths = try AppPaths()
            try store(at: paths.database).deleteTranslations(
                jobID: currentJobID,
                language: selectedLanguage,
                modelID: translationModel
            )
            let sidecar = try MediaSidecarStore(
                mediaURL: mediaURL,
                jobID: currentJobID,
                sttModel: sttModel,
                sourceLanguage: sourceLanguage.isEmpty ? nil : sourceLanguage
            )
            try sidecar.deleteTranslationResults(language: selectedLanguage, modelID: translationModel)
            translations = [:]
            if var currentSnapshot = snapshot {
                currentSnapshot.translationProgress = 0
                currentSnapshot.lastTranslationText = nil
                currentSnapshot.message = String(localized: "번역 재생성 준비 완료")
                currentSnapshot.updatedAt = .now
                try store(at: paths.database).save(snapshot: currentSnapshot)
                snapshot = currentSnapshot
            }
            startOrResume()
        } catch {
            errorMessage = String(localized: "번역 재생성 준비 실패: \(error.localizedDescription)")
        }
    }

    /// 전체 STT 구간을 다시 추출하되 기존 결과를 먼저 지우지 않습니다.
    /// 각 구간별 후보를 비교해 품질이 더 나은 결과만 반영합니다.
    func regenerateSTT() {
        guard canRegenerateSTT else { return }
        retrySegments(transcript.sorted { $0.chunkIndex < $1.chunkIndex })
    }

    /// 현재 선택한 번역 언어 기준으로 아직 번역이 채워지지 않은 STT 구간들입니다.
    var untranslatedSegments: [TranscriptSegment] {
        transcript.filter { segment in
            (translations[segment.id]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 번역이 안 된 구간만 STT 추출과 번역을 다시 시도합니다. 이미 번역된 구간은 그대로 보존합니다.
    func retryUntranslatedSegments() {
        guard canRegenerateSegment else { return }
        let pending = untranslatedSegments
        guard !pending.isEmpty else {
            errorMessage = String(localized: "번역이 안 된 항목이 없습니다.")
            return
        }
        if canMutateStorage {
            retrySegments(pending)
        } else {
            queueSegmentRetry(pending)
        }
    }

    /// 기존 결과를 보존한 채 지정 구간의 후보를 만들고 더 나을 때만 교체합니다.
    private func retrySegments(_ segments: [TranscriptSegment]) {
        guard canRegenerate, let mediaURL, let currentJobID, !segments.isEmpty else { return }
        errorMessage = nil
        do {
            let paths = try AppPaths()
            let options = currentProcessingOptions()
            let request = try makeRequest(
                jobID: currentJobID,
                mediaURL: mediaURL,
                paths: paths,
                options: options,
                retryChunkIndices: segments.map(\.chunkIndex)
            )
            currentRequest = request
            snapshot = JobSnapshot(
                id: currentJobID,
                status: .queued,
                message: String(localized: "기존 결과를 유지하며 재추출 후보 비교 준비 중")
            )
            sendStart(request)
        } catch {
            errorMessage = String(localized: "미번역 항목 재시도 준비 실패: \(error.localizedDescription)")
        }
    }

    /// 작업이 완료되면 번역이 비어 있는 구간만 한 번 자동으로 재시도합니다.
    /// STT 품질 상태가 `reviewed`라는 이유만으로 다시 추출하지 않습니다.
    /// 무한 반복을 막기 위해 작업마다 한 번만 수행합니다.
    private func autoRetryUntranslatedAfterCompletionIfNeeded() {
        guard autoRetryUntranslated,
              let jobID = currentJobID,
              canRegenerate,
              !autoRetriedJobIDs.contains(jobID) else { return }
        let targets = untranslatedSegments
        guard !targets.isEmpty else { return }
        autoRetriedJobIDs.insert(jobID)
        retrySegments(targets)
    }

    /// 작업 실행 중(주로 품질 개선 단계)에는 즉시 처리할 수 없으므로, 대상 청크를 대기열에 넣고
    /// 현재 작업을 멈춘 뒤 완료되는 즉시 재추출합니다. (초기 STT/번역 중에는 canRegenerateSegment로 이미 차단됨)
    private func queueSegmentRetry(_ segments: [TranscriptSegment]) {
        guard !segments.isEmpty else { return }
        segments.forEach { pendingRetryChunkIndices.insert($0.chunkIndex) }
        errorMessage = nil
        if var current = snapshot {
            current.message = String(localized: "현재 작업을 멈추고 선택 구간을 재추출 대기열에 추가했습니다")
            current.updatedAt = .now
            snapshot = current
        }
        if let id = currentJobID, let service = remoteService() {
            service.cancelJob(id.uuidString) { _ in }
        }
    }

    /// 대기열에 쌓인 구간을 작업 종료 후 한 번에 재추출합니다. (pollOnce의 종료 처리에서 호출)
    private func flushPendingSegmentRetries() {
        let indices = pendingRetryChunkIndices
        pendingRetryChunkIndices.removeAll()
        guard !indices.isEmpty else { return }
        refreshResults()
        let segments = transcript.filter { indices.contains($0.chunkIndex) }
        guard !segments.isEmpty else { return }
        retrySegments(segments)
    }

    func regenerateSTT(for segment: TranscriptSegment) {
        guard canRegenerateSegment, let mediaURL, let currentJobID else { return }
        guard canMutateStorage else { queueSegmentRetry([segment]); return }
        do {
            let paths = try AppPaths()
            let store = try store(at: paths.database)
            try store.deleteTranscript(jobID: currentJobID, chunkIndex: segment.chunkIndex)
            let remaining = try store.transcript(jobID: currentJobID)
            let sidecar = try MediaSidecarStore(
                mediaURL: mediaURL,
                jobID: currentJobID,
                sttModel: sttModel,
                sourceLanguage: sourceLanguage.isEmpty ? nil : sourceLanguage
            )
            try sidecar.saveTranscripts(remaining)
            for language in targetLanguages {
                try sidecar.deleteTranslationResults(language: language, modelID: translationModel)
            }
            transcript = remaining
            translations.removeValue(forKey: segment.id)
            startOrResume()
        } catch {
            errorMessage = String(localized: "선택 구간 STT 재생성 준비 실패: \(error.localizedDescription)")
        }
    }

    func regenerateTranslation(for segment: TranscriptSegment) {
        guard canRegenerateSegment, let mediaURL, let currentJobID else { return }
        guard canMutateStorage else { queueSegmentRetry([segment]); return }
        do {
            let paths = try AppPaths()
            try store(at: paths.database).deleteTranslation(
                transcriptID: segment.id,
                language: selectedLanguage,
                modelID: translationModel
            )
            let sidecar = try MediaSidecarStore(
                mediaURL: mediaURL,
                jobID: currentJobID,
                sttModel: sttModel,
                sourceLanguage: sourceLanguage.isEmpty ? nil : sourceLanguage
            )
            try sidecar.deleteTranslationResults(language: selectedLanguage, modelID: translationModel)
            translations.removeValue(forKey: segment.id)
            startOrResume()
        } catch {
            errorMessage = String(localized: "선택 문장 번역 재생성 준비 실패: \(error.localizedDescription)")
        }
    }

    func refreshServiceStatus() {
        guard let connection, let service = remoteService(on: connection) else {
            serviceIsAvailable = false
            serviceMessage = String(localized: "내장 AI 서버 연결 안 됨")
            scheduleReconnect()
            return
        }
        let generation = connectionGeneration
        service.serviceStatus { [weak self] data, error in
            Task { @MainActor in
                guard let self, self.connection != nil, self.connectionGeneration == generation else { return }
                if let error {
                    self.serviceIsAvailable = false
                    self.serviceMessage = String(localized: "상태 확인 실패: \(error)")
                    return
                }
                guard let data, let status = try? WireCodec.decode(AIServiceStatus.self, from: data) else {
                    self.serviceIsAvailable = false
                    self.serviceMessage = String(localized: "내장 AI 서버 응답 오류")
                    return
                }
                self.serviceStatus = status
                self.serviceIsAvailable = true
                self.isRestartingService = false
                self.serviceMessage = status.activeJobCount == 0
                    ? String(localized: "내장 AI 서버 정상")
                    : String(localized: "내장 AI 서버 정상 · 작업 \(status.activeJobCount)개 실행 중")
                self.resumeAfterRestartIfNeeded()
                if self.managedModels.contains(where: { $0.state == .downloading }) {
                    self.refreshModelManager()
                }
            }
        }
    }

    func restartService() {
        let wasProcessing = snapshot.map { activeStatuses.contains($0.status) } ?? false
        pendingResumeAfterRestart = wasProcessing && currentRequest != nil
        isRestartingService = true
        serviceIsAvailable = false
        serviceMessage = String(localized: "내장 AI 서버 재시작 중")
        statusTask?.cancel()

        guard let connection, let service = remoteService(on: connection) else {
            forceReconnect(after: .milliseconds(100))
            return
        }
        let generation = connectionGeneration
        service.restart { [weak self] accepted in
            Task { @MainActor in
                guard let self, self.connection != nil, self.connectionGeneration == generation else { return }
                if accepted {
                    self.forceReconnect(after: .milliseconds(800))
                } else {
                    self.isRestartingService = false
                    self.serviceMessage = String(localized: "내장 AI 서버 재시작 요청 실패")
                }
            }
        }
    }

    func refreshSettings() {
        refreshDatabaseStatistics()
        refreshModelManager()
        refreshServiceStatus()
    }

    func refreshDatabaseStatistics() {
        do {
            let paths = try AppPaths()
            databaseStatistics = try store(at: paths.database).statistics()
            databaseSizeInBytes = databaseFilesSize(at: paths.database)
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func optimizeDatabase() {
        guard canMutateStorage else {
            settingsMessage = String(localized: "실행 중인 작업을 완료하거나 취소한 후 DB를 최적화하세요.")
            return
        }
        settingsIsBusy = true
        do {
            let paths = try AppPaths()
            try store(at: paths.database).optimize()
            settingsMessage = String(localized: "DB 체크포인트와 최적화를 완료했습니다.")
            refreshDatabaseStatistics()
        } catch {
            settingsMessage = error.localizedDescription
        }
        settingsIsBusy = false
    }

    func deleteAllDatabaseData() {
        guard canMutateStorage else {
            settingsMessage = String(localized: "실행 중인 작업이 있어 DB를 초기화할 수 없습니다.")
            return
        }
        settingsIsBusy = true
        do {
            let paths = try AppPaths()
            try store(at: paths.database).deleteAllJobs()
            snapshot = nil
            transcript = []
            translations = [:]
            settingsMessage = String(localized: "모든 작업·STT·번역 DB 기록을 삭제했습니다.")
            refreshDatabaseStatistics()
        } catch {
            settingsMessage = error.localizedDescription
        }
        settingsIsBusy = false
    }

    func revealDatabase() {
        guard let paths = try? AppPaths() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([paths.database])
    }

    func revealModelsFolder() {
        guard let paths = try? AppPaths() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([paths.models])
    }

    func refreshModelManager() {
        guard let paths = try? AppPaths(), let service = remoteService() else { return }
        service.modelManagerSnapshot(at: paths.models.path) { [weak self] data, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.settingsMessage = error; return }
                guard let data, let result = try? WireCodec.decode(ModelManagerSnapshot.self, from: data) else { return }
                self.managedModels = result.models
            }
        }
    }

    func downloadModel(kind: ManagedModelKind, modelID: String) {
        guard let paths = try? AppPaths(), let service = remoteService() else {
            settingsMessage = String(localized: "내장 AI 서버에 연결할 수 없습니다.")
            return
        }
        do {
            let request = ModelManagementRequest(kind: kind, modelID: modelID, modelsURL: paths.models)
            service.startModelDownload(try WireCodec.encode(request)) { [weak self] data, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error, data == nil { self.settingsMessage = error; return }
                    if let data, let record = try? WireCodec.decode(ManagedModelRecord.self, from: data) {
                        self.upsertManagedModel(record)
                        self.settingsMessage = String(localized: "\(modelID) 다운로드를 시작했습니다.")
                    }
                }
            }
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func deleteModel(kind: ManagedModelKind, modelID: String) {
        guard canMutateStorage, let paths = try? AppPaths(), let service = remoteService() else {
            settingsMessage = String(localized: "실행 중인 작업을 중지하고 서버 연결을 확인하세요.")
            return
        }
        do {
            let request = ModelManagementRequest(kind: kind, modelID: modelID, modelsURL: paths.models)
            service.deleteManagedModel(try WireCodec.encode(request)) { [weak self] data, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error { self.settingsMessage = error; return }
                    if let data, let record = try? WireCodec.decode(ManagedModelRecord.self, from: data) {
                        self.upsertManagedModel(record)
                        self.settingsMessage = String(localized: "\(modelID) 모델 파일을 삭제했습니다.")
                    }
                }
            }
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func managedModel(kind: ManagedModelKind, modelID: String) -> ManagedModelRecord? {
        managedModels.first { $0.kind == kind && $0.modelID == modelID }
    }

    /// 얼굴 모자이크 제거용 Core ML 모델을 직접 URL에서 내려받아 Models/Demosaic 에 배치합니다.
    func downloadDemosaicModel(name: String, sourceURL: URL) {
        guard let paths = try? AppPaths(), let service = remoteService() else {
            settingsMessage = String(localized: "내장 AI 서버에 연결할 수 없습니다.")
            return
        }
        do {
            let request = ModelManagementRequest(kind: .demosaic, modelID: name, modelsURL: paths.models, sourceURL: sourceURL)
            service.startModelDownload(try WireCodec.encode(request)) { [weak self] data, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error, data == nil { self.settingsMessage = error; return }
                    if let data, let record = try? WireCodec.decode(ManagedModelRecord.self, from: data) {
                        self.upsertManagedModel(record)
                        self.settingsMessage = String(localized: "\(name) 다운로드를 시작했습니다.")
                    }
                }
            }
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func refreshResults() {
        guard let id = currentJobID, let databaseURL, let mediaURL else { return }
        do {
            let store = try store(at: databaseURL)
            let databaseTranscript = try store.transcript(jobID: id)
            let databaseTranslations = try store.translations(
                jobID: id,
                language: selectedLanguage,
                modelID: translationModel
            )
            let sidecar = try MediaSidecarStore(
                mediaURL: mediaURL,
                jobID: id,
                sttModel: sttModel,
                sourceLanguage: sourceLanguage.isEmpty ? nil : sourceLanguage
            )
            transcript = databaseTranscript.isEmpty
                ? try sidecar.loadTranscripts()
                : databaseTranscript
            if databaseTranslations.isEmpty {
                translations = Dictionary(uniqueKeysWithValues: try sidecar.loadTranslations(
                    language: selectedLanguage,
                    modelID: translationModel
                ).map { ($0.transcriptID, $0) })
            } else {
                translations = databaseTranslations
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportSRT() {
        refreshResults()
        guard !transcript.isEmpty else {
            errorMessage = String(localized: "내보낼 자막이 없습니다.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(mediaURL?.deletingPathExtension().lastPathComponent ?? "subtitle")-\(selectedLanguage).srt"
        panel.directoryURL = resultDirectoryURL
        panel.allowedContentTypes = [.init(filenameExtension: "srt")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SubtitleExporter.srt(transcript: transcript, translations: translations).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportMobilePackage() {
        refreshResults()
        guard let mediaURL else {
            errorMessage = String(localized: "먼저 영상을 열어 주세요.")
            return
        }
        guard !transcript.isEmpty else {
            errorMessage = String(localized: "공유할 STT 결과가 없습니다.")
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(mediaURL.deletingPathExtension().lastPathComponent).videolingo"
        panel.directoryURL = resultDirectoryURL
        panel.allowedContentTypes = [.videoLingoPackage]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let transcriptTrack = VideoLingoCaptionTrack(
            id: "transcript-\(sourceLanguage.isEmpty ? "auto" : sourceLanguage)",
            kind: .transcript,
            languageCode: sourceLanguage.isEmpty ? nil : sourceLanguage,
            displayName: String(localized: "원문 STT"),
            cues: transcript.map {
                VideoLingoCaptionCue(startTime: $0.startTime, endTime: $0.endTime, text: $0.text)
            }
        )
        var tracks = [transcriptTrack]
        let languagesToExport = Array(Set(targetLanguages + [selectedLanguage])).sorted()
        for language in languagesToExport {
            let storedTranslations: [UUID: TranslationSegment]
            if language == selectedLanguage {
                storedTranslations = translations
            } else if let currentJobID, let databaseURL,
                      let values = try? store(at: databaseURL).translations(
                        jobID: currentJobID,
                        language: language,
                        modelID: translationModel
                      ) {
                storedTranslations = values
            } else {
                storedTranslations = [:]
            }
            let translatedCues = transcript.compactMap { segment -> VideoLingoCaptionCue? in
                guard let text = storedTranslations[segment.id]?.text, !text.isEmpty else { return nil }
                return VideoLingoCaptionCue(startTime: segment.startTime, endTime: segment.endTime, text: text)
            }
            if !translatedCues.isEmpty {
                tracks.append(VideoLingoCaptionTrack(
                    id: "translation-\(language)",
                    kind: .translation,
                    languageCode: language,
                    displayName: String(localized: "\(language) 번역"),
                    cues: translatedCues
                ))
            }
        }

        isExportingMobilePackage = true
        mobileExportMessage = String(localized: "모바일 패키지를 만드는 중…")
        let title = mediaURL.deletingPathExtension().lastPathComponent
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [destination, mediaURL, title, tracks] in
                    try VideoLingoPackageIO.write(
                        to: destination,
                        mediaURL: mediaURL,
                        title: title,
                        tracks: tracks
                    )
                }.value
                mobileExportMessage = String(localized: "모바일 공유 패키지를 저장했습니다.")
            } catch {
                errorMessage = error.localizedDescription
                mobileExportMessage = ""
            }
            isExportingMobilePackage = false
        }
    }

    func revealOutput() {
        // 원본 옆에 저장하지 못한 경우 앱 관리 폴더에 결과가 있으므로 실제 위치를 우선 엽니다.
        let target = mediaURL.flatMap { MediaSidecarStore.existingResultsDirectoryURL(for: $0) }
            ?? resultDirectoryURL
        guard let target else { return }
        if !FileManager.default.fileExists(atPath: target.path) {
            guard (try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)) != nil else {
                errorMessage = String(localized: "결과 폴더를 열 수 없습니다. 저장 권한을 확인하세요.")
                return
            }
        }
        resultDirectoryURL = target
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func connectService() {
        guard connection == nil else { return }
        serviceMessage = String(localized: "내장 AI 서버 연결 중")
        let connection = NSXPCConnection(serviceName: "com.vvv.VideoLingo.AIService")
        let generation = UUID()
        connectionGeneration = generation
        connection.remoteObjectInterface = NSXPCInterface(with: VideoLingoAIServiceProtocol.self)
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.handleConnectionLoss(generation, message: String(localized: "내장 AI 서버 연결 중단")) }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.handleConnectionLoss(generation, message: String(localized: "내장 AI 서버 연결 종료")) }
        }
        connection.resume()
        self.connection = connection
        refreshServiceStatus()
    }

    private func remoteService() -> VideoLingoAIServiceProtocol? {
        guard let connection else { return nil }
        return remoteService(on: connection)
    }

    private func remoteService(on connection: NSXPCConnection) -> VideoLingoAIServiceProtocol? {
        let generation = connectionGeneration
        return connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.handleConnectionLoss(generation, message: String(localized: "내장 AI 서버 응답 없음")) }
        } as? VideoLingoAIServiceProtocol
    }

    private func sendStart(_ request: StartJobRequest) {
        guard let service = remoteService() else {
            errorMessage = VideoLingoError.serviceUnavailable.localizedDescription
            return
        }
        do {
            let payload = try WireCodec.encode(request)
            service.startJob(payload) { [weak self] data, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error { self.errorMessage = error; return }
                    if let data { self.snapshot = try? WireCodec.decode(JobSnapshot.self, from: data) }
                    self.beginPolling()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginPolling() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                // 고빈도 실시간 갱신은 재설계 전까지 중단하고 저빈도 상태 확인만 유지합니다.
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pollOnce() async {
        guard let id = currentJobID, let service = remoteService() else { return }
        let result: Result<JobSnapshot, Error> = await withCheckedContinuation { continuation in
            service.snapshot(for: id.uuidString) { data, error in
                if let error {
                    continuation.resume(returning: .failure(NSError(domain: "VideoLingo", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
                } else if let data {
                    do { continuation.resume(returning: .success(try WireCodec.decode(JobSnapshot.self, from: data))) }
                    catch { continuation.resume(returning: .failure(error)) }
                } else {
                    continuation.resume(returning: .failure(VideoLingoError.invalidPayload))
                }
            }
        }
        switch result {
        case .success(let value):
            let checkpointChanged = snapshot?.sttProgress != value.sttProgress
                || snapshot?.translationProgress != value.translationProgress
                || snapshot?.refinementRevision != value.refinementRevision
            snapshot = value
            if checkpointChanged { refreshResults() }
            if [.completed, .failed, .cancelled].contains(value.status) {
                statusTask?.cancel()
                if !pendingRetryChunkIndices.isEmpty {
                    flushPendingSegmentRetries()   // 대기 중인 구간 재추출을 우선 처리
                } else if value.status == .completed {
                    refreshResults()
                    autoRetryUntranslatedAfterCompletionIfNeeded()
                }
            }
        case .failure(let error):
            statusTask?.cancel()
            guard !isRestartingService else { return }
            if currentRequest != nil {
                pendingResumeAfterRestart = true
                serviceMessage = String(localized: "저장된 작업 상태 복원 중")
                refreshServiceStatus()
            } else {
                serviceMessage = String(localized: "작업 상태 확인 실패 · 시작/재개 가능: \(error.localizedDescription)")
            }
        }
    }

    private var activeStatuses: Set<JobStatus> {
        [.queued, .extracting, .transcribing, .translating, .synthesizing, .refining]
    }

    private func beginServiceMonitoring() {
        serviceHealthTask?.cancel()
        serviceHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshServiceStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func handleConnectionLoss(_ generation: UUID, message: String) {
        guard connection != nil, connectionGeneration == generation else { return }
        if snapshot.map({ activeStatuses.contains($0.status) }) == true, currentRequest != nil {
            pendingResumeAfterRestart = true
        }
        connection = nil
        serviceStatus = nil
        serviceIsAvailable = false
        serviceMessage = message
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.connectService()
        }
    }

    private func forceReconnect(after delay: Duration) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let oldConnection = self.connection
            self.connection = nil
            oldConnection?.invalidate()
            self.reconnectTask = nil
            self.connectService()
        }
    }

    private func resumeAfterRestartIfNeeded() {
        guard pendingResumeAfterRestart, let request = currentRequest else { return }
        pendingResumeAfterRestart = false
        serviceMessage = String(localized: "내장 AI 서버 정상 · 저장 지점에서 재개 중")
        sendStart(request)
    }

    private func upsertManagedModel(_ record: ManagedModelRecord) {
        managedModels.removeAll { $0.id == record.id }
        managedModels.append(record)
        managedModels.sort { $0.id < $1.id }
    }

    private func databaseFilesSize(at databaseURL: URL) -> Int64 {
        [databaseURL, URL(filePath: databaseURL.path + "-wal"), URL(filePath: databaseURL.path + "-shm")]
            .reduce(into: Int64(0)) { total, url in
                let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            }
    }

    /// 재생 중 주기적으로 현재 프레임을 OCR해 recognizedScreenText를 갱신합니다.
    /// 번역은 뷰의 Translation 프레임워크(.translationTask)가 이어받아 translatedScreenText를 채웁니다.
    private func startScreenTextLoop() {
        screenTextTask?.cancel()
        guard screenTextTranslationEnabled else {
            recognizedScreenText = nil
            translatedScreenText = nil
            return
        }
        screenTextTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self,
                   self.screenTextTranslationEnabled,
                   self.player.timeControlStatus == .playing,
                   let buffer = self.currentVideoFrame(),
                   let text = self.recognizeScreenText(in: buffer),
                   text != self.recognizedScreenText {
                    self.recognizedScreenText = text
                }
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    private func currentVideoFrame() -> CVPixelBuffer? {
        guard let output = videoOutput else { return nil }
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time) else { return nil }
        return output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    }

    private func recognizeScreenText(in buffer: CVPixelBuffer) -> String? {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation -> String? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence > 0.3 else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.count >= 2 ? text : nil
        }
        let joined = lines.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private func setupPlayerObserver() {
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds.isFinite ? time.seconds : 0
                self?.savePlaybackPositionIfNeeded()
            }
        }
    }

    /// 현재 재생 위치를 영상별로 저장합니다. (3초마다 스로틀, 끝부분이면 저장 대신 삭제)
    private func savePlaybackPositionIfNeeded() {
        guard rememberPlaybackPosition, let url = mediaURL else { return }
        let now = Date.now.timeIntervalSince1970
        guard now - lastPositionSaveWallTime >= 3 else { return }
        lastPositionSaveWallTime = now
        let time = player.currentTime().seconds
        guard time.isFinite, time > 1 else { return }
        let key = positionKey(for: url)
        let duration = player.currentItem?.duration.seconds ?? 0
        if duration.isFinite, duration > 0, time > duration - 5 {
            UserDefaults.standard.removeObject(forKey: key)   // 거의 끝까지 봤으면 다음엔 처음부터
        } else {
            UserDefaults.standard.set(time, forKey: key)
        }
    }

    private func positionKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "VideoLingo.playbackPosition.\(digest)"
    }

    private func loadVideo(_ url: URL, remember: Bool, preferredJobID: UUID? = nil) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if remember {
                errorMessage = String(localized: "영상 파일을 찾을 수 없습니다: \(url.lastPathComponent)")
            }
            return
        }
        statusTask?.cancel()
        currentRequest = nil
        mediaURL = url
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        videoOutput = output
        player.replaceCurrentItem(with: item)
        recognizedScreenText = nil
        translatedScreenText = nil
        currentTime = 0
        lastPositionSaveWallTime = 0
        // 이전 재생 위치가 있으면 그 시점부터 이어봅니다.
        if rememberPlaybackPosition,
           let saved = UserDefaults.standard.object(forKey: positionKey(for: url)) as? Double,
           saved > 1 {
            player.seek(
                to: CMTime(seconds: saved, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)
            )
            currentTime = saved
        }
        snapshot = nil
        transcript = []
        translations = [:]
        processingChunkDuration = ProcessingOptions.defaultChunkDuration
        resultDirectoryURL = MediaSidecarStore.existingResultsDirectoryURL(for: url)
            ?? MediaSidecarStore.directoryURL(for: url)
        errorMessage = nil

        do {
            let paths = try AppPaths()
            databaseURL = paths.database
            let store = try store(at: paths.database)
            let databaseJobID: UUID?
            if let preferredJobID {
                databaseJobID = preferredJobID
            } else {
                databaseJobID = try store.mostRecentJobID(for: url)
            }
            let databaseHasResults = try databaseJobID.map { try !store.transcript(jobID: $0).isEmpty } ?? false
            let discoveredSidecar = databaseHasResults ? nil : try MediaSidecarStore.discoverResults(
                for: url,
                preferredLanguage: selectedLanguage,
                preferredTranslationModel: translationModel
            )
            if let discoveredSidecar {
                sttModel = discoveredSidecar.sttModel
                sourceLanguage = discoveredSidecar.sourceLanguage ?? ""
                if let discoveredModel = discoveredSidecar.translationModel {
                    translationModel = discoveredModel
                }
            }
            let jobID = databaseHasResults
                ? databaseJobID!
                : discoveredSidecar?.jobID ?? databaseJobID ?? stableJobID(for: url)
            currentJobID = jobID
            workspaceURL = paths.workspace(for: jobID)
            let storedOptions = try store.processingOptions(jobID: jobID)
            if let storedOptions { applyProcessingOptions(storedOptions) }
            snapshot = try store.snapshot(jobID: jobID)
            refreshResults()
            if transcript.isEmpty, let discoveredSidecar {
                transcript = discoveredSidecar.transcripts
                translations = Dictionary(uniqueKeysWithValues: discoveredSidecar.translations.map {
                    ($0.transcriptID, $0)
                })
            }
            if snapshot.map({ activeStatuses.contains($0.status) }) == true,
               let options = storedOptions {
                currentRequest = try makeRequest(
                    jobID: jobID,
                    mediaURL: url,
                    paths: paths,
                    options: options
                )
                pendingResumeAfterRestart = true
                serviceMessage = String(localized: "저장된 작업을 내장 AI 서버에 복원 중")
                if serviceIsAvailable { resumeAfterRestartIfNeeded() }
            }
            if remember {
                UserDefaults.standard.set(url.path, forKey: "lastMediaPath")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreLastVideo() {
        guard let path = UserDefaults.standard.string(forKey: "lastMediaPath") else { return }
        let url = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            UserDefaults.standard.removeObject(forKey: "lastMediaPath")
            return
        }
        loadVideo(url, remember: false)
    }

    private func stableJobID(for url: URL) -> UUID {
        let key = stableJobKey(for: url)
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    /// 저장된 작업의 번역 모델을 복원하되, 사용자가 이미 Apple Intelligence에서 옮겨 갔다면 되돌리지 않습니다.
    /// 시스템이 Apple Intelligence 모델 자산을 회수하면 앱에서 복구할 수 없어, 다시 선택되면 작업이 전부 실패합니다.
    private func applyRestoredTranslationModel(_ restored: String) {
        if restored == "apple-foundation-models", translationModel != "apple-foundation-models" { return }
        translationModel = restored
    }

    /// 기본 번역 모델입니다. Apple Intelligence는 시스템이 모델 자산을 임의로 회수하면
    /// 앱에서 복구할 방법이 없어, 앱이 직접 내려받아 관리하는 Qwen을 기본으로 씁니다.
    static let defaultTranslationModel = "mlx-community/Qwen3-8B-4bit"

    /// 저장된 값을 쓰되, 예전 기본값(Apple Intelligence)에 머물러 있던 사용자는 한 번만 Qwen으로 옮깁니다.
    static func initialTranslationModel() -> String {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: "translationModel")
        let migrated = defaults.bool(forKey: "translationModelMigratedToQwen")
        if !migrated {
            defaults.set(true, forKey: "translationModelMigratedToQwen")
            if stored == nil || stored == "apple-foundation-models" {
                defaults.set(defaultTranslationModel, forKey: "translationModel")
                return defaultTranslationModel
            }
        }
        return stored ?? defaultTranslationModel
    }

    /// 배치 처리 등에서 파일 경로 기반으로 단일 창과 동일한 안정적 jobID를 얻습니다.
    static func stableJobID(
        forPath path: String,
        sttModel: String,
        sourceLanguage: String,
        chunkDuration: TimeInterval = ProcessingOptions.defaultChunkDuration
    ) -> UUID {
        let identity = [
            path,
            sttModel,
            sourceLanguage,
            String(format: "chunk-%.3f", chunkDuration),
            "speaker-diarization-v1",
            "speech-timing-v2"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = "VideoLingo.job.\(digest)"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    func currentProcessingOptions() -> ProcessingOptions {
        ProcessingOptions(
            sourceLanguage: sourceLanguage.isEmpty ? nil : sourceLanguage,
            targetLanguages: targetLanguages,
            chunkDuration: processingChunkDuration,
            sttModel: sttModel,
            translationModel: translationModel,
            synthesizeSpeech: synthesizeSpeech,
            qualityMode: qualityMode,
            glossary: glossaryEntries,
            continuousImprovement: continuousImprovement,
            maximumRefinementPasses: maximumRefinementPasses
        )
    }

    private func makeRequest(
        jobID: UUID,
        mediaURL: URL,
        paths: AppPaths,
        options: ProcessingOptions,
        retryChunkIndices: [Int] = []
    ) throws -> StartJobRequest {
        databaseURL = paths.database
        let workspace = paths.workspace(for: jobID)
        workspaceURL = workspace
        resultDirectoryURL = MediaSidecarStore.existingResultsDirectoryURL(for: mediaURL)
            ?? MediaSidecarStore.directoryURL(for: mediaURL)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let bookmark = try? mediaURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return StartJobRequest(
            jobID: jobID,
            mediaURL: mediaURL,
            securityScopedBookmark: bookmark,
            options: options,
            databaseURL: paths.database,
            workspaceURL: workspace,
            retryChunkIndices: retryChunkIndices
        )
    }

    private func applyProcessingOptions(_ options: ProcessingOptions) {
        processingChunkDuration = options.chunkDuration
        sourceLanguage = options.sourceLanguage ?? ""
        targetLanguages = options.targetLanguages.isEmpty ? ["ko"] : options.targetLanguages
        if !targetLanguages.contains(selectedLanguage) {
            selectedLanguage = targetLanguages[0]
        }
        sttModel = options.sttModel
        applyRestoredTranslationModel(options.translationModel)
        synthesizeSpeech = options.synthesizeSpeech
        qualityMode = options.qualityMode ?? .fast
        glossaryText = (options.glossary ?? []).map { "\($0.source)=\($0.target)" }.joined(separator: "\n")
        continuousImprovement = options.continuousImprovement ?? false
        maximumRefinementPasses = max(1, options.maximumRefinementPasses ?? 3)
    }

    private func stableJobKey(for url: URL) -> String {
        let identity = [url.path, sttModel, sourceLanguage, "speaker-diarization-v1", "speech-timing-v2"].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "VideoLingo.job.\(digest)"
    }

    private func store(at url: URL) throws -> JobStore {
        if let persistentStore { return persistentStore }
        let created = try JobStore(url: url)
        persistentStore = created
        return created
    }
}
