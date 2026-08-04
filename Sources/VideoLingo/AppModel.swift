import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Observation
import VideoLingoCore

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
    var translationModel = UserDefaults.standard.string(forKey: "translationModel") ?? "apple-foundation-models" {
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
    var isMiniViewer = false
    var hideTranscriptPanel = false
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

    private var currentJobID: UUID?
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
        // 앱 시작 시 기본은 무음입니다. 사용자가 음량을 올리면 그때부터 소리가 납니다.
        player.volume = 0
        setupPlayerObserver()
        connectService()
        beginServiceMonitoring()
        if autoloadLastVideo {
            AppModel.hasAutoloadedInitialVideo = true
            restoreLastVideo()
        }
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

    var activeSubtitle: String {
        guard let segment = activeTranscriptSegment else { return "" }
        let cues = segment.cues ?? []
        guard !cues.isEmpty,
              let cueIndex = cues.firstIndex(where: { currentTime >= $0.startTime && currentTime < $0.endTime }) else {
            return translations[segment.id]?.text ?? segment.text
        }
        if let translation = translations[segment.id]?.text {
            let translatedLines = translation
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if translatedLines.indices.contains(cueIndex) {
                return translatedLines[cueIndex]
            }
        }
        return cues[cueIndex].text
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

    func adjustVolume(by amount: Float) {
        player.volume = min(1, max(0, player.volume + amount))
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

    /// 현재 선택한 번역 언어 기준으로 아직 번역이 채워지지 않은 STT 구간들입니다.
    var untranslatedSegments: [TranscriptSegment] {
        transcript.filter { segment in
            (translations[segment.id]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 번역이 안 된 구간만 STT 추출과 번역을 다시 시도합니다. 이미 번역된 구간은 그대로 보존합니다.
    func retryUntranslatedSegments() {
        guard canRegenerate, let mediaURL, let currentJobID else { return }
        let pending = untranslatedSegments
        guard !pending.isEmpty else {
            errorMessage = String(localized: "번역이 안 된 항목이 없습니다.")
            return
        }
        errorMessage = nil
        do {
            let paths = try AppPaths()
            let store = try store(at: paths.database)
            let sidecar = try MediaSidecarStore(
                mediaURL: mediaURL,
                jobID: currentJobID,
                sttModel: sttModel,
                sourceLanguage: sourceLanguage.isEmpty ? nil : sourceLanguage
            )
            for segment in pending {
                try store.deleteTranscript(jobID: currentJobID, chunkIndex: segment.chunkIndex)
            }
            let remaining = try store.transcript(jobID: currentJobID)
            try sidecar.saveTranscripts(remaining)
            for language in targetLanguages {
                try sidecar.deleteTranslationResults(language: language, modelID: translationModel)
            }
            transcript = remaining
            for segment in pending {
                translations.removeValue(forKey: segment.id)
            }
            startOrResume()
        } catch {
            errorMessage = String(localized: "미번역 항목 재시도 준비 실패: \(error.localizedDescription)")
        }
    }

    func regenerateSTT(for segment: TranscriptSegment) {
        guard canRegenerate, let mediaURL, let currentJobID else { return }
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
        guard canRegenerate, let mediaURL, let currentJobID else { return }
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

    func revealOutput() {
        guard let resultDirectoryURL else { return }
        if !FileManager.default.fileExists(atPath: resultDirectoryURL.path) {
            try? FileManager.default.createDirectory(at: resultDirectoryURL, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([resultDirectoryURL])
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
                try? await Task.sleep(for: .milliseconds(300))
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
            if [.completed, .failed, .cancelled].contains(value.status) { statusTask?.cancel() }
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

    private func setupPlayerObserver() {
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    private func loadVideo(_ url: URL, remember: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if remember {
                errorMessage = String(localized: "영상 파일을 찾을 수 없습니다: \(url.lastPathComponent)")
            }
            return
        }
        statusTask?.cancel()
        currentRequest = nil
        mediaURL = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        currentTime = 0
        snapshot = nil
        transcript = []
        translations = [:]
        resultDirectoryURL = MediaSidecarStore.directoryURL(for: url)
        errorMessage = nil

        do {
            let paths = try AppPaths()
            databaseURL = paths.database
            let store = try store(at: paths.database)
            let databaseJobID = try store.mostRecentJobID(for: url)
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

    private func currentProcessingOptions() -> ProcessingOptions {
        ProcessingOptions(
            sourceLanguage: sourceLanguage.isEmpty ? nil : sourceLanguage,
            targetLanguages: targetLanguages,
            chunkDuration: 30,
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
        options: ProcessingOptions
    ) throws -> StartJobRequest {
        databaseURL = paths.database
        let workspace = paths.workspace(for: jobID)
        workspaceURL = workspace
        resultDirectoryURL = MediaSidecarStore.directoryURL(for: mediaURL)
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
            workspaceURL: workspace
        )
    }

    private func applyProcessingOptions(_ options: ProcessingOptions) {
        sourceLanguage = options.sourceLanguage ?? ""
        targetLanguages = options.targetLanguages.isEmpty ? ["ko"] : options.targetLanguages
        if !targetLanguages.contains(selectedLanguage) {
            selectedLanguage = targetLanguages[0]
        }
        sttModel = options.sttModel
        translationModel = options.translationModel
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
