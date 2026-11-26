import AppKit
import AVFoundation
import AVKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VideoLingoCore

/// 멀티 뷰의 개별 영상 슬롯(1~8개 중 하나)을 독립 제어하는 모델입니다.
@MainActor
@Observable
final class MultiViewTileModel: Identifiable {
    let id = UUID()
    private(set) var url: URL
    private(set) var title: String
    let player = AVPlayer()

    var rect: MultiViewNormalizedRect
    var zIndex: Double
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var volume: Float {
        didSet {
            let clamped = min(1, max(0, volume))
            if volume != clamped { volume = clamped; return }
            player.volume = clamped
            if clamped > 0 && isMuted {
                isMuted = false
            }
        }
    }
    var isMuted: Bool {
        didSet { player.isMuted = isMuted }
    }
    var playbackRate: Float = 1.0 {
        didSet {
            if isPlaying { player.rate = playbackRate }
        }
    }
    var isLooping = true
    var fillsFrame = false

    // MARK: - 슬롯별 자막 상태
    var subtitlesEnabled = true
    private(set) var hasSubtitles = false
    private(set) var subtitleSourceLabel: String?
    private(set) var activeOriginalSubtitle = ""
    private(set) var activeTranslationSubtitle: String?
    private(set) var externalSubtitleURL: URL?

    // MARK: - 슬롯별 코덱·떨림 보정 호환 스트림 상태
    private(set) var isUsingCompatibilityStream = false
    private(set) var compatibilityAssessment: VideoCompatibilityAssessment?
    @ObservationIgnored private var compatibilitySessionID: String?
    @ObservationIgnored private var compatibilityCheckTask: Task<Void, Never>?

    @ObservationIgnored private var subtitleItems: [AlignedSentenceItem] = []
    @ObservationIgnored private var subtitleLoadTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var timeObserver: Any?
    @ObservationIgnored private nonisolated(unsafe) var endObserver: NSObjectProtocol?
    @ObservationIgnored private var durationTask: Task<Void, Never>?

    init(
        url: URL,
        rect: MultiViewNormalizedRect,
        zIndex: Double,
        volume: Float = 0.85,
        isMuted: Bool = false,
        subtitlesEnabled: Bool = true,
        preferredLanguage: String = "ko",
        preferredTranslationModel: String = ""
    ) {
        self.url = url.standardizedFileURL
        self.title = url.lastPathComponent
        self.rect = rect
        self.zIndex = zIndex
        self.volume = volume
        self.isMuted = isMuted
        self.subtitlesEnabled = subtitlesEnabled
        player.volume = volume
        player.isMuted = isMuted
        load(
            url: url,
            autoPlay: false,
            preferredLanguage: preferredLanguage,
            preferredTranslationModel: preferredTranslationModel
        )
    }

    func load(
        url newURL: URL,
        autoPlay: Bool,
        preferredLanguage: String = "ko",
        preferredTranslationModel: String = ""
    ) {
        cleanupObservers()
        releaseCompatibilitySession()
        self.url = newURL.standardizedFileURL
        self.title = newURL.lastPathComponent
        self.currentTime = 0
        self.duration = 0
        self.externalSubtitleURL = nil
        self.subtitleItems = []
        self.hasSubtitles = false
        self.subtitleSourceLabel = nil
        self.activeOriginalSubtitle = ""
        self.activeTranslationSubtitle = nil
        self.compatibilityAssessment = nil
        self.isUsingCompatibilityStream = false

        installPlayerItem(url: self.url, startTime: 0, autoPlay: autoPlay)
        loadSubtitles(preferredLanguage: preferredLanguage, preferredTranslationModel: preferredTranslationModel)
        scheduleCompatibilityInspection(for: self.url)
    }

    private func installPlayerItem(url itemURL: URL, startTime: TimeInterval, autoPlay: Bool) {
        cleanupObservers()
        let asset = AVURLAsset(url: itemURL)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.volume = volume
        player.isMuted = isMuted

        durationTask?.cancel()
        if duration <= 0 {
            durationTask = Task { [weak self] in
                if let loaded = try? await asset.load(.duration), loaded.seconds.isFinite, loaded.seconds > 0 {
                    self?.duration = loaded.seconds
                }
            }
        }

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let sec = time.seconds
            Task { @MainActor [weak self] in
                guard let self, sec.isFinite else { return }
                let clamped = max(0, sec)
                self.currentTime = clamped
                self.updateActiveSubtitle(at: clamped)
                // HLS 버퍼링 중에는 rate가 잠시 0일 수 있으므로 timeControlStatus != .paused로 재생 의도를 유지합니다.
                let running = self.player.timeControlStatus != .paused
                if self.isPlaying != running { self.isPlaying = running }
                if self.duration <= 0,
                   let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isLooping {
                    self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    self.play()
                } else {
                    self.isPlaying = false
                }
            }
        }

        if startTime > 0.5 {
            player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if autoPlay {
            play()
        } else {
            isPlaying = false
        }
    }

    private func scheduleCompatibilityInspection(for videoURL: URL) {
        compatibilityCheckTask?.cancel()
        compatibilityCheckTask = Task { [weak self] in
            guard let assessment = await VideoCompatibilityInspector.shared.inspect(url: videoURL),
                  !Task.isCancelled else { return }
            guard let self, self.url == videoURL else { return }
            self.compatibilityAssessment = assessment
            if self.duration <= 0 && assessment.info.duration > 0 {
                self.duration = assessment.info.duration
            }
            if assessment.needsCompatibilityProxy {
                self.activateCompatibilityStream(using: assessment)
            }
        }
    }

    func setCompatibilityStreamEnabled(_ enabled: Bool) {
        guard enabled != isUsingCompatibilityStream else { return }
        if enabled {
            if let existing = compatibilityAssessment {
                activateCompatibilityStream(using: existing)
            } else {
                let videoURL = self.url
                let fallbackDuration = max(duration, 4)
                compatibilityCheckTask?.cancel()
                compatibilityCheckTask = Task { [weak self] in
                    let probed = await VideoCompatibilityInspector.shared.inspect(url: videoURL)
                    guard let self, self.url == videoURL, !Task.isCancelled else { return }
                    let assessment = probed ?? VideoCompatibilityAssessment(
                        info: VideoStreamProbeInfo(fileExtension: videoURL.pathExtension, codecName: "h264", duration: fallbackDuration),
                        issues: [.brokenFrameOrder]
                    )
                    self.compatibilityAssessment = assessment
                    self.activateCompatibilityStream(using: assessment)
                }
            }
        } else {
            let resumeTime = currentTime
            let wasPlaying = isPlaying
            releaseCompatibilitySession()
            isUsingCompatibilityStream = false
            installPlayerItem(url: self.url, startTime: resumeTime, autoPlay: wasPlaying)
        }
    }

    private func activateCompatibilityStream(using assessment: VideoCompatibilityAssessment) {
        let resumeTime = currentTime
        let wasPlaying = isPlaying || player.timeControlStatus != .paused
        releaseCompatibilitySession(cancelCheckTask: false)
        guard let session = try? LocalCodecStreamProxy.shared.openSession(for: self.url, assessment: assessment) else {
            return
        }
        compatibilitySessionID = session.id
        isUsingCompatibilityStream = true
        if duration <= 0 && assessment.info.duration > 0 {
            duration = assessment.info.duration
        }
        installPlayerItem(url: session.playlistURL, startTime: resumeTime, autoPlay: wasPlaying)
    }

    private func releaseCompatibilitySession(cancelCheckTask: Bool = true) {
        if cancelCheckTask {
            compatibilityCheckTask?.cancel()
            compatibilityCheckTask = nil
        }
        if let id = compatibilitySessionID {
            LocalCodecStreamProxy.shared.releaseSession(id)
            compatibilitySessionID = nil
        }
    }

    func play() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = playbackRate
        if isUsingCompatibilityStream {
            // HLS 온디맨드 스트림은 첫 세그먼트 버퍼링을 기다리도록 play()를 사용해야 멈추지 않습니다.
            player.play()
        } else {
            player.playImmediately(atRate: playbackRate)
        }
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to seconds: TimeInterval) {
        let clamped = duration > 0 ? min(duration, max(0, seconds)) : max(0, seconds)
        currentTime = clamped
        updateActiveSubtitle(at: clamped)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    func toggleMute() {
        isMuted.toggle()
        if !isMuted && volume <= 0.01 {
            volume = 0.8
        }
    }

    func loadSubtitles(preferredLanguage: String, preferredTranslationModel: String) {
        if let external = externalSubtitleURL {
            loadExternalSubtitle(from: external)
            return
        }
        subtitleLoadTask?.cancel()
        let videoURL = self.url
        subtitleLoadTask = Task.detached(priority: .utility) { [weak self] in
            let loaded = Self.discoverSubtitleItems(
                for: videoURL,
                preferredLanguage: preferredLanguage,
                preferredTranslationModel: preferredTranslationModel
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.url == videoURL else { return }
                self.subtitleItems = loaded.items
                self.hasSubtitles = !loaded.items.isEmpty
                self.subtitleSourceLabel = loaded.label
                self.updateActiveSubtitle(at: self.currentTime)
            }
        }
    }

    func loadExternalSubtitle(from subtitleURL: URL) {
        subtitleLoadTask?.cancel()
        externalSubtitleURL = subtitleURL
        guard let content = try? String(contentsOf: subtitleURL, encoding: .utf8) else {
            subtitleItems = []
            hasSubtitles = false
            subtitleSourceLabel = nil
            updateActiveSubtitle(at: currentTime)
            return
        }
        let cues = SubtitleParser.parse(content)
        let dummyID = UUID()
        subtitleItems = cues.enumerated().map { idx, cue in
            AlignedSentenceItem(
                id: "ext:\(idx)",
                segmentID: dummyID,
                chunkIndex: 0,
                sentenceNumber: idx + 1,
                startTime: cue.startTime,
                endTime: cue.endTime,
                originalText: cue.text,
                translatedText: cue.text
            )
        }
        hasSubtitles = !subtitleItems.isEmpty
        subtitleSourceLabel = subtitleURL.lastPathComponent
        subtitlesEnabled = true
        updateActiveSubtitle(at: currentTime)
    }

    func clearExternalSubtitle(preferredLanguage: String, preferredTranslationModel: String) {
        externalSubtitleURL = nil
        loadSubtitles(preferredLanguage: preferredLanguage, preferredTranslationModel: preferredTranslationModel)
    }

    private func updateActiveSubtitle(at time: TimeInterval) {
        guard !subtitleItems.isEmpty,
              let index = SentenceAlignmentGrouper.activeIndex(in: subtitleItems, at: time) else {
            if !activeOriginalSubtitle.isEmpty { activeOriginalSubtitle = "" }
            if activeTranslationSubtitle != nil { activeTranslationSubtitle = nil }
            return
        }
        let item = subtitleItems[index]
        if activeOriginalSubtitle != item.originalText { activeOriginalSubtitle = item.originalText }
        if activeTranslationSubtitle != item.translatedText { activeTranslationSubtitle = item.translatedText }
    }

    private nonisolated static func discoverSubtitleItems(
        for mediaURL: URL,
        preferredLanguage: String,
        preferredTranslationModel: String
    ) -> (items: [AlignedSentenceItem], label: String?) {
        let language = preferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        // 1) 앱이 생성한 .videolingo 사이드카(원본 옆 + 앱 관리 Results 폴더) 우선 탐색
        if let sidecar = try? MediaSidecarStore.discoverResults(
            for: mediaURL,
            preferredLanguage: language.isEmpty ? "ko" : language,
            preferredTranslationModel: preferredTranslationModel
        ), !sidecar.transcripts.isEmpty {
            let translationMap: [UUID: TranslationSegment] = language.isEmpty
                ? [:]
                : Dictionary(uniqueKeysWithValues: sidecar.translations.map { ($0.transcriptID, $0) })
            let items = SentenceAlignmentGrouper.group(
                transcript: sidecar.transcripts,
                translations: translationMap
            )
            let label = (!language.isEmpty && !translationMap.isEmpty) ? "\(language.uppercased()) 번역" : "STT 원문"
            return (items, label)
        }

        // 2) 영상 옆 같은 이름의 .srt / .vtt 파일 자동 감지
        let base = mediaURL.deletingPathExtension()
        let fm = FileManager.default
        var candidates: [URL] = []
        if !language.isEmpty {
            candidates.append(URL(fileURLWithPath: "\(base.path).\(language).srt"))
            candidates.append(URL(fileURLWithPath: "\(base.path).\(language).vtt"))
        }
        candidates.append(base.appendingPathExtension("srt"))
        candidates.append(base.appendingPathExtension("vtt"))

        for fileURL in candidates where fm.fileExists(atPath: fileURL.path) {
            if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                let cues = SubtitleParser.parse(text)
                if !cues.isEmpty {
                    let dummyID = UUID()
                    let items = cues.enumerated().map { idx, cue in
                        AlignedSentenceItem(
                            id: "side:\(idx)",
                            segmentID: dummyID,
                            chunkIndex: 0,
                            sentenceNumber: idx + 1,
                            startTime: cue.startTime,
                            endTime: cue.endTime,
                            originalText: cue.text,
                            translatedText: cue.text
                        )
                    }
                    return (items, fileURL.pathExtension.uppercased())
                }
            }
        }
        return ([], nil)
    }

    func teardown() {
        durationTask?.cancel()
        durationTask = nil
        subtitleLoadTask?.cancel()
        subtitleLoadTask = nil
        releaseCompatibilitySession()
        cleanupObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
    }

    private func cleanupObservers() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}

/// 영상 감상 모드의 1~8개 동시 재생 멀티 뷰 상태를 관리하는 컨트롤러입니다.
@MainActor
@Observable
final class ViewingMultiViewController {
    static let maxTiles = MultiViewLayoutEngine.maximumTileCount

    private(set) var tiles: [MultiViewTileModel] = []
    var activePreset: MultiViewLayoutPreset = .autoGrid
    var selectedTileID: UUID?
    var maximizedTileID: UUID?
    /// 3개 이상 열려 있을 때도 선택한 2개 영상만 캔버스 100% 높이로 나란히 크게 비교하는 모드입니다.
    var dualFocusTileIDs: [UUID]?
    var alwaysShowTileControls = true
    var autoArrangeOnCountChange = true
    /// 멀티 뷰 전체 자막 표시 여부 (추가/제외 토글)
    var subtitlesEnabled = true
    /// 자막 표시 시 원문 STT와 번역 자막을 함께 볼지 여부
    var showOriginalWithTranslation = false
    /// 멀티 뷰 자막 언어 코드 (비어 있으면 원문 STT만 표시)
    var subtitleLanguage: String = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "ko"
    var statusBanner: String?
    /// 타일/툴바에서 중복 정리 시트를 열기 위한 트리거
    var showingDuplicateManager = false
    var duplicateFocusFilenameKey: String?

    @ObservationIgnored private var nextZIndex: Double = 1

    var canAddMore: Bool { tiles.count < Self.maxTiles }
    var remainingSlots: Int { max(0, Self.maxTiles - tiles.count) }
    var anyPlaying: Bool { tiles.contains(where: \.isPlaying) }
    var allMuted: Bool { !tiles.isEmpty && tiles.allSatisfy(\.isMuted) }
    var subtitlesActiveCount: Int { tiles.filter(\.subtitlesEnabled).count }

    func contains(url: URL) -> Bool {
        let std = url.standardizedFileURL
        return tiles.contains { $0.url == std }
    }

    func slotNumber(for url: URL) -> Int? {
        let std = url.standardizedFileURL
        return tiles.firstIndex(where: { $0.url == std }).map { $0 + 1 }
    }

    /// 1개 이상의 영상을 멀티 뷰 슬롯(최대 8개)에 추가합니다.
    @discardableResult
    func addVideos(_ urls: [URL], autoPlay: Bool = true) -> Int {
        var addedCount = 0
        for rawURL in urls {
            let std = rawURL.standardizedFileURL
            if let existing = tiles.first(where: { $0.url == std }) {
                bringToFront(existing.id)
                continue
            }
            guard tiles.count < Self.maxTiles else {
                statusBanner = "멀티 뷰는 최대 \(Self.maxTiles)개까지 동시에 재생할 수 있습니다."
                break
            }
            let isFirst = tiles.isEmpty
            nextZIndex += 1
            let initialRect = MultiViewNormalizedRect(
                x: min(0.45, 0.04 * Double(tiles.count)),
                y: min(0.45, 0.04 * Double(tiles.count)),
                width: 0.48,
                height: 0.48
            )
            let tile = MultiViewTileModel(
                url: std,
                rect: initialRect,
                zIndex: nextZIndex,
                volume: 0.85,
                isMuted: !isFirst, // 첫 번째 영상만 기본 소리 ON, 추가 영상은 혼선 방지를 위해 음소거 시작
                subtitlesEnabled: subtitlesEnabled,
                preferredLanguage: subtitleLanguage,
                preferredTranslationModel: UserDefaults.standard.string(forKey: "translationModel") ?? ""
            )
            tiles.append(tile)
            selectedTileID = tile.id
            if autoPlay {
                tile.play()
            }
            addedCount += 1
        }

        if addedCount > 0 {
            statusBanner = nil
            if autoArrangeOnCountChange {
                applyPreset(activePreset, resetAutoArrange: false)
            }
        }
        return addedCount
    }

    func openVideosWithPanel() {
        guard canAddMore else {
            statusBanner = "이미 최대 \(Self.maxTiles)개 영상이 열려 있습니다."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "멀티 뷰에 추가할 영상 선택 (최대 \(remainingSlots)개 추가 가능)"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addVideos(panel.urls, autoPlay: true)
    }

    func replaceVideoWithPanel(tileID: UUID) {
        guard let tile = tiles.first(where: { $0.id == tileID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "슬롯 영상 교체"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tile.load(
            url: url,
            autoPlay: true,
            preferredLanguage: subtitleLanguage,
            preferredTranslationModel: UserDefaults.standard.string(forKey: "translationModel") ?? ""
        )
        bringToFront(tileID)
    }

    func importExternalSubtitleWithPanel(tileID: UUID) {
        guard let tile = tiles.first(where: { $0.id == tileID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "자막 파일 추가 (.srt / .vtt)"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "srt") ?? .plainText,
            UTType(filenameExtension: "vtt") ?? .plainText
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tile.loadExternalSubtitle(from: url)
        subtitlesEnabled = true
        bringToFront(tileID)
    }

    func setAllSubtitlesEnabled(_ enabled: Bool) {
        subtitlesEnabled = enabled
        for tile in tiles {
            tile.subtitlesEnabled = enabled
        }
    }

    func setSubtitleLanguage(_ language: String, preferredTranslationModel: String) {
        subtitleLanguage = language
        reloadAllSubtitles(preferredTranslationModel: preferredTranslationModel)
    }

    func reloadAllSubtitles(preferredTranslationModel: String) {
        for tile in tiles {
            tile.loadSubtitles(
                preferredLanguage: subtitleLanguage,
                preferredTranslationModel: preferredTranslationModel
            )
        }
    }

    func removeTile(_ id: UUID) {
        guard let idx = tiles.firstIndex(where: { $0.id == id }) else { return }
        let removed = tiles.remove(at: idx)
        removed.teardown()
        if maximizedTileID == id { maximizedTileID = nil }
        if var dual = dualFocusTileIDs {
            dual.removeAll { $0 == id }
            dualFocusTileIDs = dual.count >= 2 ? Array(dual.prefix(2)) : nil
        }
        if selectedTileID == id { selectedTileID = tiles.last?.id }
        if autoArrangeOnCountChange && !tiles.isEmpty {
            applyPreset(activePreset, resetAutoArrange: false)
        }
        statusBanner = nil
    }

    func clearAll() {
        for tile in tiles { tile.teardown() }
        tiles.removeAll()
        selectedTileID = nil
        maximizedTileID = nil
        dualFocusTileIDs = nil
        statusBanner = nil
    }

    func applyPreset(_ preset: MultiViewLayoutPreset, resetAutoArrange: Bool = true) {
        activePreset = preset
        if resetAutoArrange {
            autoArrangeOnCountChange = true
        }
        maximizedTileID = nil
        dualFocusTileIDs = nil
        let rects = MultiViewLayoutEngine.rects(for: tiles.count, preset: preset)
        for (idx, tile) in tiles.enumerated() where idx < rects.count {
            tile.rect = rects[idx]
            nextZIndex += 1
            tile.zIndex = nextZIndex
        }
    }

    func bringToFront(_ id: UUID) {
        guard let tile = tiles.first(where: { $0.id == id }) else { return }
        nextZIndex += 1
        tile.zIndex = nextZIndex
        selectedTileID = id
    }

    /// 선택한 영상을 1번(메인) 위치로 올리고 메인 강조 레이아웃으로 전환합니다.
    func promoteToMain(_ id: UUID) {
        guard let idx = tiles.firstIndex(where: { $0.id == id }) else { return }
        if idx != 0 {
            tiles.swapAt(0, idx)
        }
        applyPreset(.spotlight)
        bringToFront(id)
    }

    /// 선택한 영상을 2개 크게 보기(왼쪽 #1 또는 오른쪽 #2) 슬롯으로 배치합니다.
    func promoteToDualSlot(_ id: UUID, slot: Int) {
        let clampedSlot = min(1, max(0, slot))
        guard tiles.count >= 2, let idx = tiles.firstIndex(where: { $0.id == id }) else {
            applyPreset(.dualSpotlight)
            return
        }
        if idx != clampedSlot {
            tiles.swapAt(clampedSlot, idx)
        }
        if dualFocusTileIDs != nil {
            dualFocusTileIDs = [tiles[0].id, tiles[1].id]
        } else {
            applyPreset(.dualSpotlight)
        }
        bringToFront(id)
    }

    /// 3개 이상 열려 있을 때 2개 영상만 100% 화면 높이로 나란히 크게 비교하거나 전체 보기로 복귀합니다.
    func toggleDualFullCompare() {
        if dualFocusTileIDs != nil {
            dualFocusTileIDs = nil
            return
        }
        guard tiles.count >= 2 else { return }
        maximizedTileID = nil
        // 선택된 타일이 있으면 그 타일을 우선 포함해 2개를 구성합니다.
        if let selectedID = selectedTileID,
           let selectedTile = tiles.first(where: { $0.id == selectedID }),
           let companion = tiles.first(where: { $0.id != selectedID }) {
            dualFocusTileIDs = [selectedTile.id, companion.id]
        } else {
            dualFocusTileIDs = [tiles[0].id, tiles[1].id]
        }
    }

    var activeDualFocusTiles: [MultiViewTileModel]? {
        guard let ids = dualFocusTileIDs, ids.count == 2 else { return nil }
        let matched = ids.compactMap { id in tiles.first(where: { $0.id == id }) }
        return matched.count == 2 ? matched : nil
    }

    /// 중복 비교용으로 선택한 영상 묶음을 멀티뷰에 올리고 2개 크게 보기 배치로 즉시 전환합니다.
    func openForDualComparison(_ urls: [URL]) {
        let targets = urls.map(\.standardizedFileURL)
        guard !targets.isEmpty else { return }
        // 이미 열려 있지 않은 항목이 슬롯 한도를 넘으면 앞 2개 우선 열기
        var prioritized: [URL] = []
        for u in targets {
            if !prioritized.contains(u) { prioritized.append(u) }
        }
        // 자리가 부족하면 첫 2개를 넣을 수 있도록 기존 비대상 슬롯을 정리하지 않고 안내만 하거나 여유분만큼 추가
        if !canAddMore {
            let needed = prioritized.prefix(2).filter { !contains(url: $0) }.count
            if needed > 0 {
                // 가장 오래된(마지막) 비대상 슬롯을 닫아 비교 공간 확보
                let targetSet = Set(prioritized.prefix(2))
                for _ in 0..<needed {
                    if let victim = tiles.last(where: { !targetSet.contains($0.url) }) {
                        removeTile(victim.id)
                    }
                }
            }
        }
        addVideos(Array(prioritized.prefix(Self.maxTiles)), autoPlay: true)
        let matchingTiles = prioritized.compactMap { url in tiles.first(where: { $0.url == url }) }
        if matchingTiles.count >= 2 {
            // 1번·2번 위치로 올려 두 영상을 나란히 크게 배치합니다.
            if let idx0 = tiles.firstIndex(where: { $0.id == matchingTiles[0].id }), idx0 != 0 {
                tiles.swapAt(0, idx0)
            }
            if let idx1 = tiles.firstIndex(where: { $0.id == matchingTiles[1].id }), idx1 != 1 {
                tiles.swapAt(1, idx1)
            }
            applyPreset(.dualSpotlight)
            if tiles.count > 2 {
                dualFocusTileIDs = [tiles[0].id, tiles[1].id]
            }
        } else {
            applyPreset(.dualSpotlight)
        }
    }

    /// 지정한 영상 URL을 휴지통으로 이동하거나 디스크에서 영구 삭제하고 상태 배너를 갱신합니다.
    func deleteVideoFiles(urls: [URL], mode: MediaLibrary.VideoDeleteMode) async -> MediaLibrary.VideoDeletionOutcome {
        let outcome = await MediaLibrary.shared.deleteVideos(urls: urls, mode: mode)
        statusBanner = outcome.summaryMessage
        return outcome
    }

    /// 현재 열린 멀티뷰 타일 + 라이브러리에서 같은 파일명을 가진 파일 수(자신 포함)를 반환합니다.
    func sameFilenameCount(for url: URL) -> Int {
        let key = MediaFilenameDeduplicator.canonicalFilenameKey(for: url)
        var uniquePaths = Set<String>()
        uniquePaths.insert(url.standardizedFileURL.path(percentEncoded: false))
        for tile in tiles where MediaFilenameDeduplicator.canonicalFilenameKey(for: tile.url) == key {
            uniquePaths.insert(tile.url.standardizedFileURL.path(percentEncoded: false))
        }
        for item in MediaLibrary.shared.items where MediaFilenameDeduplicator.canonicalFilenameKey(for: item.videoURL) == key {
            uniquePaths.insert(item.videoURL.standardizedFileURL.path(percentEncoded: false))
        }
        return uniquePaths.count
    }

    func openDuplicateManager(focusing url: URL? = nil) {
        duplicateFocusFilenameKey = url.map { MediaFilenameDeduplicator.canonicalFilenameKey(for: $0) }
        showingDuplicateManager = true
    }

    func moveTileOrder(_ id: UUID, offset: Int) {
        guard let idx = tiles.firstIndex(where: { $0.id == id }) else { return }
        let target = idx + offset
        guard tiles.indices.contains(target) else { return }
        let rectA = tiles[idx].rect
        let rectB = tiles[target].rect
        tiles.swapAt(idx, target)
        tiles[idx].rect = rectA
        tiles[target].rect = rectB
        bringToFront(id)
    }

    func updateTileRect(_ id: UUID, rect: MultiViewNormalizedRect) {
        guard let tile = tiles.first(where: { $0.id == id }) else { return }
        tile.rect = rect
        // 사용자가 직접 위치나 크기를 조정했으면 이후 수동 배치를 유지합니다.
        autoArrangeOnCountChange = false
    }

    func playAll() {
        for tile in tiles { tile.play() }
    }

    func pauseAll() {
        for tile in tiles { tile.pause() }
    }

    func togglePlayPauseAll() {
        if anyPlaying { pauseAll() } else { playAll() }
    }

    /// 모든 영상을 0초로 맞춘 뒤 한꺼번에 동시에 시작합니다.
    func restartAllFromBeginning() {
        for tile in tiles {
            tile.seek(to: 0)
            tile.play()
        }
    }

    /// 모든 영상을 일시 정지하고 0초 위치로 되돌립니다.
    func stopAll() {
        for tile in tiles {
            tile.pause()
            tile.seek(to: 0)
        }
    }

    func seekAll(by delta: TimeInterval) {
        for tile in tiles { tile.seek(by: delta) }
    }

    func muteAll() {
        for tile in tiles { tile.isMuted = true }
    }

    func unmuteAll() {
        for tile in tiles {
            tile.isMuted = false
            if tile.volume <= 0.01 { tile.volume = 0.8 }
        }
    }

    /// 선택한 영상 하나만 소리를 켜고 나머지는 모두 음소거합니다.
    func soloAudio(for id: UUID) {
        for tile in tiles {
            if tile.id == id {
                tile.isMuted = false
                if tile.volume <= 0.01 { tile.volume = 0.85 }
            } else {
                tile.isMuted = true
            }
        }
        bringToFront(id)
    }
}

// MARK: - 멀티 뷰 전체 작업 공간

struct ViewingMultiViewWorkspace: View {
    @Environment(AppModel.self) private var model
    @State private var library = MediaLibrary.shared
    @State private var isDropTargeted = false
    @State private var showClearConfirm = false

    private var controller: ViewingMultiViewController { model.multiView }

    private var duplicateFileCount: Int {
        let urls = controller.tiles.map(\.url) + library.items.map(\.videoURL)
        return MediaFilenameDeduplicator.filenameDuplicateGroups(for: urls)
            .reduce(0) { $0 + max(0, $1.urls.count - 1) }
    }

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            if !model.isTheaterMode {
                multiViewToolbar
                Divider()
            }

            GeometryReader { geometry in
                let canvasSize = geometry.size
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.94)

                    if controller.tiles.isEmpty {
                        emptyCanvasView
                    } else if let maxID = controller.maximizedTileID,
                              let maxTile = controller.tiles.first(where: { $0.id == maxID }) {
                        MultiViewTileCard(
                            tile: maxTile,
                            slotNumber: (controller.tiles.firstIndex(where: { $0.id == maxID }) ?? 0) + 1,
                            canvasSize: canvasSize,
                            isMaximized: true
                        )
                        .frame(width: max(120, canvasSize.width - 12), height: max(100, canvasSize.height - 12))
                        .position(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    } else if let dualTiles = controller.activeDualFocusTiles {
                        // 2개만 100% 전체 높이로 나란히 크게 비교하는 뷰
                        let gap: CGFloat = 8
                        let paneW = max(140, (canvasSize.width - gap * 3) / 2)
                        let paneH = max(110, canvasSize.height - gap * 2)
                        ForEach(Array(dualTiles.enumerated()), id: \.element.id) { pairIdx, tile in
                            let slotNum = (controller.tiles.firstIndex(where: { $0.id == tile.id }) ?? pairIdx) + 1
                            let centerX = gap + paneW / 2 + CGFloat(pairIdx) * (paneW + gap)
                            let centerY = gap + paneH / 2
                            MultiViewTileCard(
                                tile: tile,
                                slotNumber: slotNum,
                                canvasSize: canvasSize,
                                isMaximized: true
                            )
                            .frame(width: paneW, height: paneH)
                            .position(x: centerX, y: centerY)
                        }
                    } else {
                        ForEach(Array(controller.tiles.enumerated()), id: \.element.id) { index, tile in
                            let pixelWidth = max(140, CGFloat(tile.rect.width) * canvasSize.width)
                            let pixelHeight = max(110, CGFloat(tile.rect.height) * canvasSize.height)
                            let centerX = CGFloat(tile.rect.x) * canvasSize.width + pixelWidth / 2
                            let centerY = CGFloat(tile.rect.y) * canvasSize.height + pixelHeight / 2

                            MultiViewTileCard(
                                tile: tile,
                                slotNumber: index + 1,
                                canvasSize: canvasSize,
                                isMaximized: false
                            )
                            .frame(width: pixelWidth, height: pixelHeight)
                            .position(x: centerX, y: centerY)
                            .zIndex(tile.zIndex)
                        }
                    }

                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                Label("여기에 영상을 놓아 멀티 뷰에 추가 (최대 8개)", systemImage: "plus.rectangle.on.rectangle")
                                    .font(.headline)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleFileDrop(providers)
                }
            }

            if let banner = controller.statusBanner {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                    Text(banner)
                        .font(.caption)
                    Spacer()
                    Button("닫기") { controller.statusBanner = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
        .sheet(isPresented: $controller.showingDuplicateManager) {
            MultiViewDuplicateManagerSheet(
                controller: controller,
                initialFocusFilenameKey: controller.duplicateFocusFilenameKey
            )
            .environment(model)
        }
        .confirmationDialog("멀티 뷰의 모든 영상을 닫을까요?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("모두 닫기", role: .destructive) { controller.clearAll() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("현재 열린 \(controller.tiles.count)개의 재생 슬롯을 모두 비웁니다. 원본 파일은 유지됩니다.")
        }
    }

    private var multiViewToolbar: some View {
        @Bindable var controller = controller
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Label("멀티 뷰", systemImage: "rectangle.grid.2x2")
                    .font(.headline)
                Text("\(controller.tiles.count) / \(ViewingMultiViewController.maxTiles)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            Button("영상 추가…", systemImage: "plus") {
                controller.openVideosWithPanel()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!controller.canAddMore)
            .help(controller.canAddMore ? "Finder에서 영상을 선택해 멀티 뷰에 추가 (최대 8개)" : "최대 8개 슬롯이 모두 사용 중입니다")

            Divider().frame(height: 18)

            // 전체 화면 한꺼번에 시작 / 중지 / 처음부터 동시 시작 컨트롤
            HStack(spacing: 4) {
                Button("전체 시작", systemImage: "play.fill") { controller.playAll() }
                    .buttonStyle(.borderedProminent)
                    .help("열린 모든 화면을 한꺼번에 시작 (Space)")
                Button("전체 중지", systemImage: "pause.fill") { controller.pauseAll() }
                    .buttonStyle(.bordered)
                    .help("열린 모든 화면을 한꺼번에 중지 (Space)")
                Button("처음부터 동시 시작", systemImage: "backward.end.fill") { controller.restartAllFromBeginning() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .help("모든 화면을 0초로 맞춰 한꺼번에 시작")
                Button("전체 0초 정지", systemImage: "stop.fill") { controller.stopAll() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .help("모든 화면을 중지하고 0초로 초기화")
                Button(
                    controller.allMuted ? "모두 소리 켜기" : "모두 음소거",
                    systemImage: controller.allMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
                ) {
                    if controller.allMuted { controller.unmuteAll() } else { controller.muteAll() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .help(controller.allMuted ? "모든 영상 음소거 해제" : "모든 영상 음소거")
            }
            .controlSize(.small)
            .disabled(controller.tiles.isEmpty)

            Divider().frame(height: 18)

            // 자막 전체 추가/제외 토글 + 언어/원문 설정 메뉴
            HStack(spacing: 4) {
                Button(
                    controller.subtitlesEnabled ? "자막 켜짐" : "자막 제외",
                    systemImage: controller.subtitlesEnabled ? "captions.bubble.fill" : "captions.bubble"
                ) {
                    controller.setAllSubtitlesEnabled(!controller.subtitlesEnabled)
                }
                .buttonStyle(.bordered)
                .tint(controller.subtitlesEnabled ? Color.accentColor : nil)
                .help(controller.subtitlesEnabled ? "클릭해 모든 화면에서 자막 제외" : "클릭해 모든 화면에 자막 표시")

                Menu {
                    Button("모든 화면에 자막 추가(표시)", systemImage: "captions.bubble.fill") {
                        controller.setAllSubtitlesEnabled(true)
                    }
                    Button("모든 화면에서 자막 제외", systemImage: "captions.bubble") {
                        controller.setAllSubtitlesEnabled(false)
                    }
                    Divider()
                    Toggle("원문과 번역 함께 보기", isOn: $controller.showOriginalWithTranslation)
                    Menu("자막 언어 · \(controller.subtitleLanguage.isEmpty ? "원문 STT" : controller.subtitleLanguage.uppercased())") {
                        Button {
                            controller.setSubtitleLanguage("", preferredTranslationModel: model.translationModel)
                        } label: {
                            if controller.subtitleLanguage.isEmpty {
                                Label("원문 STT만", systemImage: "checkmark")
                            } else {
                                Text("원문 STT만")
                            }
                        }
                        ForEach(model.languages, id: \.self) { lang in
                            Button {
                                controller.setSubtitleLanguage(lang, preferredTranslationModel: model.translationModel)
                            } label: {
                                if controller.subtitleLanguage == lang {
                                    Label(lang.uppercased(), systemImage: "checkmark")
                                } else {
                                    Text(lang.uppercased())
                                }
                            }
                        }
                    }
                    Divider()
                    Button("저장된 자막 다시 불러오기", systemImage: "arrow.clockwise") {
                        controller.reloadAllSubtitles(preferredTranslationModel: model.translationModel)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .menuStyle(.button)
                .fixedSize()
                .help("자막 언어 · 원문 함께 보기 · 전체 추가/제외 설정")
            }
            .controlSize(.small)

            Divider().frame(height: 18)

            // 레이아웃 프리셋 1클릭 정렬
            Menu {
                ForEach(MultiViewLayoutPreset.allCases) { preset in
                    Button {
                        withAnimation(.snappy) {
                            controller.applyPreset(preset)
                        }
                    } label: {
                        if controller.activePreset == preset && controller.autoArrangeOnCountChange {
                            Label(preset.title, systemImage: "checkmark")
                        } else {
                            Label(preset.title, systemImage: preset.symbol)
                        }
                    }
                }
            } label: {
                Label(
                    controller.autoArrangeOnCountChange ? "배치 · \(controller.activePreset.title)" : "배치 · 자유 배치",
                    systemImage: controller.activePreset.symbol
                )
            }
            .controlSize(.small)
            .disabled(controller.tiles.isEmpty)
            .help("프리셋으로 즉시 정렬하거나, 각 화면 상단 바를 드래그해 위치·우하단 핸들로 크기를 자유롭게 조절하세요")

            // 자주 쓰는 3개 프리셋 빠른 버튼 (자동 격자 · 2개 크게 보기 · 메인 강조)
            Button("자동 격자", systemImage: "rectangle.grid.2x2") {
                withAnimation(.snappy) { controller.applyPreset(.autoGrid) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .tint(controller.dualFocusTileIDs == nil && controller.activePreset == .autoGrid ? Color.accentColor : nil)
            .controlSize(.small)
            .disabled(controller.tiles.isEmpty)
            .help("1~8개 자동 격자 정렬")

            Button("2개 크게", systemImage: "rectangle.split.2x1") {
                withAnimation(.snappy) { controller.applyPreset(.dualSpotlight) }
            }
            .buttonStyle(.bordered)
            .tint(controller.dualFocusTileIDs == nil && controller.activePreset == .dualSpotlight ? Color.accentColor : nil)
            .controlSize(.small)
            .disabled(controller.tiles.count < 2)
            .help("1·2번 영상 2개를 동시에 크게 나란히 배치 (3개 이상일 때는 나머지를 하단 스트립에 표시)")

            if controller.tiles.count >= 3 {
                Button(
                    controller.dualFocusTileIDs != nil ? "전체 복귀" : "2개만 꽉 차게",
                    systemImage: controller.dualFocusTileIDs != nil ? "rectangle.grid.2x2" : "rectangle.split.2x1.fill"
                ) {
                    withAnimation(.snappy) { controller.toggleDualFullCompare() }
                }
                .buttonStyle(.bordered)
                .tint(controller.dualFocusTileIDs != nil ? Color.accentColor : nil)
                .controlSize(.small)
                .help(controller.dualFocusTileIDs != nil ? "숨겨둔 나머지 멀티뷰 화면으로 복귀" : "3개 이상 열려 있을 때도 선택한 2개만 화면 100% 높이로 나란히 비교")
            }

            Button("메인 강조", systemImage: "rectangle.leadinghalf.inset.filled") {
                withAnimation(.snappy) { controller.applyPreset(.spotlight) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .tint(controller.dualFocusTileIDs == nil && controller.activePreset == .spotlight ? Color.accentColor : nil)
            .controlSize(.small)
            .disabled(controller.tiles.count < 2)
            .help("1번 영상을 크게, 나머지를 보조 화면으로 배치")

            Divider().frame(height: 18)

            // 중복 파일 검토 · 휴지통 이동 · 영구 삭제
            Button {
                controller.openDuplicateManager(focusing: nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                    Text("중복 정리")
                    if duplicateFileCount > 0 {
                        Text("\(duplicateFileCount)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.22), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(controller.tiles.isEmpty && library.items.isEmpty)
            .help("멀티뷰 및 라이브러리의 중복 영상(같은 이름 · 동일 내용)을 비교하고 휴지통 이동 또는 디스크에서 영구 삭제")

            Spacer(minLength: 4)

            Toggle("컨트롤 표시", isOn: $controller.alwaysShowTileControls)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("끄면 마우스를 올린 영상에만 조작 바가 표시됩니다")

            if !controller.tiles.isEmpty {
                Button("모두 닫기", systemImage: "trash", role: .destructive) {
                    if controller.tiles.count > 1 {
                        showClearConfirm = true
                    } else {
                        controller.clearAll()
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("멀티 뷰의 모든 영상 닫기")
            }

            Button("단일 보기") {
                model.setViewingMultiView(false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("단일 영상 감상 화면으로 돌아가기 (⌘⇧G)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyCanvasView: some View {
        ContentUnavailableView {
            Label("멀티 뷰 (1~8개 동시 재생)", systemImage: "rectangle.grid.2x2")
        } description: {
            Text("왼쪽 영상 목록을 클릭하거나 Finder에서 영상을 끌어다 놓으면 최대 8개 영상을 동시에 재생하고 화면 크기·배치·음량을 각각 조절할 수 있습니다.")
        } actions: {
            Button("영상 파일 선택…") {
                controller.openVideosWithPanel()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let supportedExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm", "ts", "mts"]
        let targetController = controller
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL? = if let data = item as? Data {
                    URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    item as? URL
                }
                guard let url, supportedExtensions.contains(url.pathExtension.lowercased()) else { return }
                Task { @MainActor in
                    targetController.addVideos([url], autoPlay: true)
                }
            }
        }
        return true
    }
}

// MARK: - 개별 멀티 뷰 영상 타일 (독립 재생 · 음량 · 이동 · 크기 조절)

private struct MultiViewTileCard: View {
    @Environment(AppModel.self) private var model
    let tile: MultiViewTileModel
    let slotNumber: Int
    let canvasSize: CGSize
    let isMaximized: Bool

    @State private var isHovering = false
    @State private var moveStartRect: MultiViewNormalizedRect?
    @State private var resizeStartRect: MultiViewNormalizedRect?
    @State private var scrubbingTime: TimeInterval?
    @State private var pendingDeleteMode: MediaLibrary.VideoDeleteMode?
    @State private var isDeletingFile = false

    private var controller: ViewingMultiViewController { model.multiView }
    private var isSelected: Bool { controller.selectedTileID == tile.id }
    private var showChrome: Bool {
        controller.alwaysShowTileControls || isHovering || isSelected || moveStartRect != nil || resizeStartRect != nil
    }
    private var duplicateCount: Int {
        controller.sameFilenameCount(for: tile.url)
    }
    private var tileFileSizeText: String {
        let size = (try? tile.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : ""
    }

    var body: some View {
        @Bindable var tile = tile
        ZStack {
            MultiViewPlayerSurface(player: tile.player, fillsFrame: tile.fillsFrame)
                .contentShape(Rectangle())
                .onTapGesture {
                    controller.bringToFront(tile.id)
                }
                .onTapGesture(count: 2) {
                    tile.togglePlayback()
                }

            VStack(spacing: 0) {
                if showChrome {
                    tileHeaderBar
                }
                Spacer(minLength: 0)
                if controller.subtitlesEnabled && tile.subtitlesEnabled {
                    tileSubtitleOverlay
                }
                if showChrome {
                    tileBottomControls
                }
            }

            // 우하단 자유 리사이즈 핸들 (전체 확대 상태가 아닐 때 표시)
            if !isMaximized {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        resizeHandle
                    }
                }
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.white.opacity(isHovering ? 0.45 : 0.16),
                    lineWidth: isSelected ? 2 : 1
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button(tile.isPlaying ? "일시 정지" : "재생", systemImage: tile.isPlaying ? "pause.fill" : "play.fill") {
                tile.togglePlayback()
            }
            Button("이 영상만 소리 켜기 (솔로)", systemImage: "headphones") {
                controller.soloAudio(for: tile.id)
            }
            Button(tile.isMuted ? "음소거 해제" : "음소거", systemImage: tile.isMuted ? "speaker.wave.2" : "speaker.slash") {
                tile.toggleMute()
            }
            Divider()
            Button(
                tile.subtitlesEnabled ? "이 화면 자막 제외" : "이 화면 자막 표시",
                systemImage: tile.subtitlesEnabled ? "captions.bubble" : "captions.bubble.fill"
            ) {
                tile.subtitlesEnabled.toggle()
                if tile.subtitlesEnabled && !controller.subtitlesEnabled {
                    controller.subtitlesEnabled = true
                }
            }
            Button("외부 자막 파일 추가 (.srt/.vtt)…", systemImage: "doc.badge.plus") {
                controller.importExternalSubtitleWithPanel(tileID: tile.id)
            }
            if tile.externalSubtitleURL != nil {
                Button("외부 자막 제거", systemImage: "trash") {
                    tile.clearExternalSubtitle(
                        preferredLanguage: controller.subtitleLanguage,
                        preferredTranslationModel: model.translationModel
                    )
                }
            }
            Button(
                tile.isUsingCompatibilityStream ? "떨림 보정 · 코덱 호환 끄기" : "떨림 보정 · 코덱 호환 켜기 (FFmpeg)",
                systemImage: "waveform.path.ecg"
            ) {
                tile.setCompatibilityStreamEnabled(!tile.isUsingCompatibilityStream)
            }
            .disabled(!FFmpegToolLocator.isAvailable)
            Divider()
            Button("2개 크게 보기 · 왼쪽(#1)에 배치", systemImage: "rectangle.lefthalf.filled") {
                withAnimation(.snappy) { controller.promoteToDualSlot(tile.id, slot: 0) }
            }
            .disabled(controller.tiles.count < 2)
            Button("2개 크게 보기 · 오른쪽(#2)에 배치", systemImage: "rectangle.righthalf.filled") {
                withAnimation(.snappy) { controller.promoteToDualSlot(tile.id, slot: 1) }
            }
            .disabled(controller.tiles.count < 2)
            Button("메인 화면으로 강조", systemImage: "rectangle.leadinghalf.inset.filled") {
                withAnimation(.snappy) { controller.promoteToMain(tile.id) }
            }
            Button(isMaximized ? "원래 크기로 복귀" : "이 영상만 크게 보기", systemImage: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                withAnimation(.snappy) {
                    if controller.dualFocusTileIDs != nil {
                        controller.dualFocusTileIDs = nil
                    } else {
                        controller.maximizedTileID = isMaximized ? nil : tile.id
                    }
                }
            }
            Button(tile.fillsFrame ? "원본 비율 맞춤" : "화면 꽉 채우기", systemImage: "aspectratio") {
                tile.fillsFrame.toggle()
            }
            Divider()
            Button("이전 슬롯과 자리 바꾸기", systemImage: "arrow.left") {
                withAnimation(.snappy) { controller.moveTileOrder(tile.id, offset: -1) }
            }
            .disabled(slotNumber <= 1)
            Button("다음 슬롯과 자리 바꾸기", systemImage: "arrow.right") {
                withAnimation(.snappy) { controller.moveTileOrder(tile.id, offset: 1) }
            }
            .disabled(slotNumber >= controller.tiles.count)
            Button("다른 영상으로 교체…", systemImage: "arrow.triangle.2.circlepath") {
                controller.replaceVideoWithPanel(tileID: tile.id)
            }
            Button("Finder에서 파일 보기", systemImage: "finder") {
                NSWorkspace.shared.activateFileViewerSelecting([tile.url])
            }
            if duplicateCount > 1 {
                Button("중복 파일 비교 · 정리 (\(duplicateCount)개)…", systemImage: "doc.on.doc") {
                    controller.openDuplicateManager(focusing: tile.url)
                }
            }
            Divider()
            Button("슬롯만 닫기", systemImage: "xmark") {
                withAnimation(.snappy) { controller.removeTile(tile.id) }
            }
            Button("파일 휴지통으로 이동…", systemImage: "trash", role: .destructive) {
                pendingDeleteMode = .moveToTrash
            }
            .disabled(isDeletingFile || AppModel.videoIsBeingProcessed(tile.url))
            Button("파일 영구 삭제 (복구 불가)…", systemImage: "trash.slash.fill", role: .destructive) {
                pendingDeleteMode = .permanentlyDelete
            }
            .disabled(isDeletingFile || AppModel.videoIsBeingProcessed(tile.url))
        }
        .confirmationDialog(
            pendingDeleteMode == .permanentlyDelete
                ? "이 영상 파일을 디스크에서 영구 삭제할까요?"
                : "이 영상 파일을 휴지통으로 이동할까요?",
            isPresented: Binding(
                get: { pendingDeleteMode != nil },
                set: { if !$0 { pendingDeleteMode = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteMode
        ) { mode in
            Button(
                mode == .permanentlyDelete ? "디스크에서 영구 삭제" : "휴지통으로 이동",
                role: .destructive
            ) {
                deleteCurrentTileFile(mode: mode)
            }
            Button("취소", role: .cancel) {}
        } message: { mode in
            let sizeInfo = tileFileSizeText.isEmpty ? "" : " (\(tileFileSizeText))"
            if mode == .permanentlyDelete {
                Text("\(tile.url.path(percentEncoded: false))\(sizeInfo)\n\n휴지통을 거치지 않고 파일 시스템에서 즉시 영구 삭제됩니다. 이 작업은 되돌릴 수 없습니다.")
            } else {
                Text("\(tile.url.path(percentEncoded: false))\(sizeInfo)\n\n멀티뷰에서 닫히고 파일이 Finder의 휴지통으로 이동합니다. 휴지통에서 복구할 수 있습니다.")
            }
        }
    }

    private func deleteCurrentTileFile(mode: MediaLibrary.VideoDeleteMode) {
        guard !isDeletingFile else { return }
        let targetURL = tile.url
        isDeletingFile = true
        Task {
            defer { isDeletingFile = false }
            _ = await controller.deleteVideoFiles(urls: [targetURL], mode: mode)
        }
    }

    private var tileHeaderBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("#\(slotNumber)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                Text(tile.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if tile.isUsingCompatibilityStream {
                    Text(tile.compatibilityAssessment?.badgeTitle ?? "떨림 보정")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.8), in: Capsule())
                        .foregroundStyle(.white)
                        .help("FFmpeg VideoToolbox 호환 스트림 활성 · \(tile.compatibilityAssessment?.summary ?? "타임스탬프·코덱 보정 중")")
                }
                if duplicateCount > 1 {
                    Button {
                        controller.openDuplicateManager(focusing: tile.url)
                    } label: {
                        Text("중복 \(duplicateCount)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("같은 이름의 영상이 \(duplicateCount)개 있습니다. 클릭해 비교하고 정리하세요.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(moveDragGesture)
            .help(isMaximized ? tile.title : "드래그해 화면 위치를 자유롭게 이동하세요")

            HStack(spacing: 4) {
                Button {
                    tile.subtitlesEnabled.toggle()
                    if tile.subtitlesEnabled && !controller.subtitlesEnabled {
                        controller.subtitlesEnabled = true
                    }
                } label: {
                    Image(systemName: (controller.subtitlesEnabled && tile.subtitlesEnabled) ? "captions.bubble.fill" : "captions.bubble")
                        .font(.caption)
                        .foregroundStyle((controller.subtitlesEnabled && tile.subtitlesEnabled) ? (tile.hasSubtitles ? Color.accentColor : Color.white) : Color.white.opacity(0.45))
                }
                .help(
                    (controller.subtitlesEnabled && tile.subtitlesEnabled)
                        ? "이 화면 자막 제외 (\(tile.subtitleSourceLabel ?? "자막 없음"))"
                        : "이 화면 자막 표시"
                )

                if !isMaximized && controller.tiles.count > 1 {
                    Button {
                        withAnimation(.snappy) { controller.promoteToMain(tile.id) }
                    } label: {
                        Image(systemName: slotNumber == 1 ? "star.fill" : "star")
                            .font(.caption)
                    }
                    .help("이 영상을 메인 큰 화면으로 배치")
                }

                Button {
                    withAnimation(.snappy) {
                        if controller.dualFocusTileIDs != nil {
                            controller.dualFocusTileIDs = nil
                        } else {
                            controller.maximizedTileID = isMaximized ? nil : tile.id
                        }
                    }
                } label: {
                    Image(systemName: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .help(isMaximized ? "멀티 뷰로 복귀" : "이 영상만 크게 보기")

                Menu {
                    Menu("재생 속도 (\(String(format: "%.2g×", tile.playbackRate)))") {
                        ForEach([Float(0.5), 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                            Button {
                                tile.playbackRate = rate
                            } label: {
                                if abs(tile.playbackRate - rate) < 0.01 {
                                    Label(String(format: "%.2g×", rate), systemImage: "checkmark")
                                } else {
                                    Text(String(format: "%.2g×", rate))
                                }
                            }
                        }
                    }
                    Toggle("반복 재생", isOn: Binding(get: { tile.isLooping }, set: { tile.isLooping = $0 }))
                    Toggle("화면 꽉 채우기", isOn: Binding(get: { tile.fillsFrame }, set: { tile.fillsFrame = $0 }))
                    Toggle("이 화면 자막 표시", isOn: Binding(get: { tile.subtitlesEnabled }, set: { tile.subtitlesEnabled = $0 }))
                    Toggle("떨림 보정 · 코덱 호환 (FFmpeg)", isOn: Binding(
                        get: { tile.isUsingCompatibilityStream },
                        set: { tile.setCompatibilityStreamEnabled($0) }
                    ))
                    .disabled(!FFmpegToolLocator.isAvailable)
                    Divider()
                    if controller.tiles.count >= 2 {
                        Button("2개 크게 보기 · 왼쪽(#1)", systemImage: "rectangle.lefthalf.filled") {
                            withAnimation(.snappy) { controller.promoteToDualSlot(tile.id, slot: 0) }
                        }
                        Button("2개 크게 보기 · 오른쪽(#2)", systemImage: "rectangle.righthalf.filled") {
                            withAnimation(.snappy) { controller.promoteToDualSlot(tile.id, slot: 1) }
                        }
                    }
                    Button("외부 자막 파일 추가 (.srt/.vtt)…", systemImage: "doc.badge.plus") {
                        controller.importExternalSubtitleWithPanel(tileID: tile.id)
                    }
                    if tile.externalSubtitleURL != nil {
                        Button("외부 자막 제거", systemImage: "trash") {
                            tile.clearExternalSubtitle(
                                preferredLanguage: controller.subtitleLanguage,
                                preferredTranslationModel: model.translationModel
                            )
                        }
                    }
                    Button("다른 영상으로 교체…", systemImage: "arrow.triangle.2.circlepath") {
                        controller.replaceVideoWithPanel(tileID: tile.id)
                    }
                    Button("Finder에서 파일 보기", systemImage: "finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([tile.url])
                    }
                    Divider()
                    Button("파일 휴지통으로 이동…", systemImage: "trash", role: .destructive) {
                        pendingDeleteMode = .moveToTrash
                    }
                    .disabled(isDeletingFile || AppModel.videoIsBeingProcessed(tile.url))
                    Button("파일 영구 삭제…", systemImage: "trash.slash.fill", role: .destructive) {
                        pendingDeleteMode = .permanentlyDelete
                    }
                    .disabled(isDeletingFile || AppModel.videoIsBeingProcessed(tile.url))
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("속도 · 2개 크게 배치 · 파일 휴지통/영구 삭제")

                Button {
                    withAnimation(.snappy) { controller.removeTile(tile.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .help("이 영상 슬롯 닫기")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.62))
    }

    @ViewBuilder
    private var tileSubtitleOverlay: some View {
        let primaryText = tile.activeTranslationSubtitle ?? tile.activeOriginalSubtitle
        let showOriginalLine = controller.showOriginalWithTranslation
            && tile.activeTranslationSubtitle != nil
            && !tile.activeOriginalSubtitle.isEmpty
            && tile.activeOriginalSubtitle != tile.activeTranslationSubtitle
        if !primaryText.isEmpty {
            let tileHeight = isMaximized ? canvasSize.height : CGFloat(tile.rect.height) * canvasSize.height
            let fontSize = max(10, min(18, tileHeight * 0.048))
            VStack(spacing: 2) {
                Text(primaryText)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if showOriginalLine {
                    Text(tile.activeOriginalSubtitle)
                        .font(.system(size: max(9, fontSize * 0.82)))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .allowsHitTesting(false)
        }
    }

    private var tileBottomControls: some View {
        @Bindable var tile = tile
        return VStack(spacing: 4) {
            // 시크 타임라인
            HStack(spacing: 6) {
                Text(formatTime(scrubbingTime ?? tile.currentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { min(scrubbingTime ?? tile.currentTime, max(tile.duration, 0.1)) },
                        set: { scrubbingTime = $0 }
                    ),
                    in: 0...max(tile.duration, 0.1),
                    onEditingChanged: { editing in
                        if !editing, let target = scrubbingTime {
                            tile.seek(to: target)
                            scrubbingTime = nil
                        }
                    }
                )
                .controlSize(.mini)
                .disabled(tile.duration <= 0)

                Text(formatTime(tile.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, alignment: .leading)
            }

            // 재생 제어 + 독립 음량 + 솔로 오디오
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Button { tile.seek(by: -10) } label: {
                        Image(systemName: "gobackward.10")
                    }
                    .help("10초 뒤로")
                    Button { tile.togglePlayback() } label: {
                        Image(systemName: tile.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .help(tile.isPlaying ? "일시 정지" : "재생")
                    Button { tile.seek(by: 10) } label: {
                        Image(systemName: "goforward.10")
                    }
                    .help("10초 앞으로")
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                Spacer(minLength: 4)

                // 솔로 오디오 + 음소거 + 볼륨 슬라이더
                HStack(spacing: 5) {
                    Button {
                        controller.soloAudio(for: tile.id)
                    } label: {
                        Image(systemName: "headphones")
                            .font(.caption)
                            .foregroundStyle(!tile.isMuted && controller.tiles.filter({ !$0.isMuted }).count == 1 ? Color.accentColor : Color.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("이 영상만 소리 켜기 (나머지 음소거)")

                    Button {
                        tile.toggleMute()
                    } label: {
                        Image(systemName: volumeIcon(volume: tile.volume, muted: tile.isMuted))
                            .font(.caption)
                            .foregroundStyle(tile.isMuted ? .orange : .white)
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .help(tile.isMuted ? "음소거 해제" : "음소거")

                    Slider(
                        value: Binding(
                            get: { tile.isMuted ? 0 : Double(tile.volume) },
                            set: { newValue in
                                tile.volume = Float(newValue)
                                tile.isMuted = newValue <= 0.001
                            }
                        ),
                        in: 0...1
                    )
                    .controlSize(.mini)
                    .frame(width: 64)
                    .help("이 영상의 음량 (\(tile.isMuted ? 0 : Int((tile.volume * 100).rounded()))%)")

                    Text("\(tile.isMuted ? 0 : Int((tile.volume * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 28, alignment: .trailing)
                }
                // 우하단 리사이즈 핸들과 겹치지 않도록 오른쪽 여백 확보
                .padding(.trailing, isMaximized ? 0 : 14)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.66))
    }

    private var resizeHandle: some View {
        ZStack {
            Color.clear.frame(width: 20, height: 20)
            Image(systemName: "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(showChrome ? 0.9 : 0.45))
                .padding(3)
                .background(Color.black.opacity(showChrome ? 0.65 : 0.3), in: RoundedRectangle(cornerRadius: 4))
        }
        .contentShape(Rectangle())
        .gesture(resizeDragGesture)
        .help("드래그해 이 영상의 화면 크기를 자유롭게 조절하세요")
    }

    private var moveDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                guard !isMaximized, canvasSize.width > 0, canvasSize.height > 0 else { return }
                if moveStartRect == nil {
                    moveStartRect = tile.rect
                    controller.bringToFront(tile.id)
                }
                guard let start = moveStartRect else { return }
                let dx = Double(value.translation.width / canvasSize.width)
                let dy = Double(value.translation.height / canvasSize.height)
                controller.updateTileRect(tile.id, rect: start.moved(dx: dx, dy: dy))
            }
            .onEnded { _ in
                moveStartRect = nil
            }
    }

    private var resizeDragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                guard !isMaximized, canvasSize.width > 0, canvasSize.height > 0 else { return }
                if resizeStartRect == nil {
                    resizeStartRect = tile.rect
                    controller.bringToFront(tile.id)
                }
                guard let start = resizeStartRect else { return }
                let dw = Double(value.translation.width / canvasSize.width)
                let dh = Double(value.translation.height / canvasSize.height)
                controller.updateTileRect(tile.id, rect: start.resized(dw: dw, dh: dh))
            }
            .onEnded { _ in
                resizeStartRect = nil
            }
    }

    private func volumeIcon(volume: Float, muted: Bool) -> String {
        if muted || volume <= 0.01 { return "speaker.slash.fill" }
        if volume < 0.35 { return "speaker.wave.1.fill" }
        if volume < 0.7 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct MultiViewPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let fillsFrame: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        let gravity: AVLayerVideoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
        if view.videoGravity != gravity { view.videoGravity = gravity }
    }
}

// MARK: - 멀티 뷰 중복 파일 검토 · 비교 · 휴지통/영구 삭제 시트

private struct MultiViewDuplicateManagerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let controller: ViewingMultiViewController
    let initialFocusFilenameKey: String?

    @State private var library = MediaLibrary.shared
    @State private var mode: MediaDuplicateReason = .sameFilename
    @State private var scope: ScanScope = .allLibrary
    @State private var selectedPaths: Set<String> = []
    @State private var contentGroups: [MediaDuplicateGroup] = []
    @State private var isScanningContent = false
    @State private var contentScanTask: Task<Void, Never>?
    @State private var contentScanMessage = ""
    @State private var pendingDeleteMode: MediaLibrary.VideoDeleteMode?
    @State private var isDeleting = false
    @State private var resultBanner = ""

    private enum ScanScope: String, CaseIterable, Identifiable {
        case openAndCurrentFolder
        case allLibrary

        var id: Self { self }
        var title: String {
            switch self {
            case .openAndCurrentFolder: "열린 영상 · 현재 폴더"
            case .allLibrary: "라이브러리 전체"
            }
        }
    }

    private var candidateURLs: [URL] {
        var uniqueByPath: [String: URL] = [:]
        for tile in controller.tiles {
            let std = tile.url.standardizedFileURL
            uniqueByPath[std.path(percentEncoded: false)] = std
        }
        let folderPath = model.playerFolderPath
        let folderPrefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        for item in library.items {
            let path = item.videoURL.standardizedFileURL.path(percentEncoded: false)
            if scope == .openAndCurrentFolder && !folderPath.isEmpty && !path.hasPrefix(folderPrefix) {
                continue
            }
            uniqueByPath[path] = item.videoURL.standardizedFileURL
        }
        return Array(uniqueByPath.values)
    }

    private var libraryItemsByPath: [String: MediaLibraryItem] {
        Dictionary(uniqueKeysWithValues: library.items.map { ($0.id, $0) })
    }

    private var filenameGroups: [MediaDuplicateGroup] {
        let sizesByPath = Dictionary(uniqueKeysWithValues: library.items.map { ($0.id, $0.size) })
        let all = MediaFilenameDeduplicator.filenameDuplicateGroups(for: candidateURLs, sizesByPath: sizesByPath)
        guard let focusKey = initialFocusFilenameKey, !focusKey.isEmpty else { return all }
        return all.sorted { lhs, rhs in
            let lhsFocus = lhs.id == "name:\(focusKey)"
            let rhsFocus = rhs.id == "name:\(focusKey)"
            if lhsFocus != rhsFocus { return lhsFocus }
            return false
        }
    }

    private var activeGroups: [MediaDuplicateGroup] {
        mode == .sameFilename ? filenameGroups : contentGroups
    }

    private var allSelectablePaths: Set<String> {
        var result = Set<String>()
        for url in activeGroups.flatMap(\.urls) where !AppModel.videoIsBeingProcessed(url) {
            result.insert(url.standardizedFileURL.path(percentEncoded: false))
        }
        return result
    }

    private var isAllSelected: Bool {
        let selectable = allSelectablePaths
        return !selectable.isEmpty && selectable.isSubset(of: selectedPaths)
    }

    private var selectedURLs: [URL] {
        let allKnown = Dictionary(uniqueKeysWithValues: activeGroups.flatMap(\.urls).map {
            ($0.standardizedFileURL.path(percentEncoded: false), $0.standardizedFileURL)
        })
        return selectedPaths.compactMap { allKnown[$0] }.sorted { $0.path < $1.path }
    }

    private var selectedByteCount: Int64 {
        selectedURLs.reduce(0) { sum, url in
            let path = url.path(percentEncoded: false)
            if let size = libraryItemsByPath[path]?.size, size > 0 { return sum + size }
            let diskSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return sum + diskSize
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("중복 영상 정리")
                        .font(.title2.weight(.semibold))
                    Text("같은 파일명이나 동일한 내용의 영상을 2개 크게 비교한 뒤 휴지통으로 이동하거나 디스크에서 영구 삭제할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            // 필터 / 스캔 바
            HStack(spacing: 12) {
                Picker("기준", selection: $mode) {
                    ForEach(MediaDuplicateReason.allCases) { reason in
                        Text(reason.title).tag(reason)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Picker("범위", selection: $scope) {
                    ForEach(ScanScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .frame(width: 200)

                Spacer()

                if mode == .identicalContent {
                    if isScanningContent {
                        ProgressView().controlSize(.small)
                        Button("취소", role: .cancel) { cancelContentScan() }
                            .controlSize(.small)
                    } else {
                        Button("내용 해시 스캔", systemImage: "magnifyingglass") {
                            startContentScan()
                        }
                        .controlSize(.small)
                        .disabled(candidateURLs.count < 2)
                    }
                }

                Button(
                    isAllSelected ? "전체 해제" : "전체 선택",
                    systemImage: isAllSelected ? "checkmark.square.fill" : "checkmark.square"
                ) {
                    toggleSelectAll()
                }
                .controlSize(.small)
                .disabled(allSelectablePaths.isEmpty)
                .keyboardShortcut("a", modifiers: .command)
                .help(isAllSelected ? "표시된 모든 중복 영상 선택 해제 (⌘A)" : "표시된 모든 중복 영상 전체 선택 (⌘A)")

                Button("권장 선택 (1개 남김)", systemImage: "checkmark.circle") {
                    selectRecommendedDuplicates()
                }
                .controlSize(.small)
                .disabled(activeGroups.isEmpty)
                .help("각 중복 묶음에서 STT·번역 결과가 있거나 현재 재생 중인 1개만 남기고 나머지 중복 파일을 자동 선택합니다")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            if !contentScanMessage.isEmpty && mode == .identicalContent {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(contentScanMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if !resultBanner.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(resultBanner)
                        .font(.caption)
                    Spacer()
                    Button("닫기", systemImage: "xmark") { resultBanner = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1))
            }

            Divider()

            // 본문 목록
            if mode == .identicalContent && isScanningContent && contentGroups.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("파일 크기와 앞·중간·뒤 해시를 비교하는 중…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if activeGroups.isEmpty {
                ContentUnavailableView {
                    Label(
                        mode == .sameFilename ? "같은 파일명의 중복 영상이 없습니다" : "동일 내용의 중복 영상이 없습니다",
                        systemImage: "checkmark.seal"
                    )
                } description: {
                    Text(
                        mode == .sameFilename
                            ? "파일명이 다르지만 내용이 같은 중복 파일을 찾으려면 ‘동일 내용 (크기·해시)’ 탭에서 스캔해 보세요."
                            : "‘내용 해시 스캔’을 눌러 파일 크기가 같은 영상들의 내용을 비교할 수 있습니다."
                    )
                } actions: {
                    if mode == .identicalContent && !isScanningContent {
                        Button("내용 해시 스캔 시작") { startContentScan() }
                            .buttonStyle(.borderedProminent)
                            .disabled(candidateURLs.count < 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(activeGroups) { group in
                        Section {
                            ForEach(group.urls, id: \.path) { url in
                                duplicateFileRow(url: url, group: group)
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Text(group.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(group.urls.count)개")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.orange)
                                if group.reclaimableBytes > 0 {
                                    Text("정리 시 \(ByteCountFormatter.string(fromByteCount: group.reclaimableBytes, countStyle: .file)) 확보")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                let groupPaths = groupSelectablePaths(for: group)
                                let groupAllSelected = !groupPaths.isEmpty && groupPaths.isSubset(of: selectedPaths)
                                Button(groupAllSelected ? "묶음 해제" : "묶음 선택") {
                                    if groupAllSelected {
                                        selectedPaths.subtract(groupPaths)
                                    } else {
                                        selectedPaths.formUnion(groupPaths)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(groupPaths.isEmpty)
                                .help(groupAllSelected ? "이 묶음의 모든 파일 선택 해제" : "이 묶음의 모든 파일 선택")
                                Button("2개 크게 비교", systemImage: "rectangle.split.2x1") {
                                    controller.openForDualComparison(group.urls)
                                    dismiss()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .help("이 묶음의 영상을 멀티뷰 2개 크게 보기로 바로 열어 화질·자막을 비교합니다")
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // 하단 삭제 액션 바
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("묶음 \(activeGroups.count)개 · 선택 \(selectedURLs.count)개")
                        .font(.caption.weight(.semibold).monospacedDigit())
                    if selectedByteCount > 0 {
                        Text("선택 용량 \(ByteCountFormatter.string(fromByteCount: selectedByteCount, countStyle: .file))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isDeleting {
                    ProgressView().controlSize(.small)
                }

                if !selectedPaths.isEmpty {
                    Button("선택 해제") { selectedPaths.removeAll() }
                        .controlSize(.small)
                }

                Button("휴지통으로 이동…", systemImage: "trash") {
                    pendingDeleteMode = .moveToTrash
                }
                .buttonStyle(.bordered)
                .disabled(selectedURLs.isEmpty || isDeleting)
                .help("선택한 중복 파일을 Finder 휴지통으로 이동합니다 (복구 가능)")

                Button("영구 삭제…", systemImage: "trash.slash.fill", role: .destructive) {
                    pendingDeleteMode = .permanentlyDelete
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedURLs.isEmpty || isDeleting)
                .help("선택한 중복 파일을 휴지통을 거치지 않고 디스크에서 즉시 영구 삭제합니다 (복구 불가)")
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 820, height: 560)
        .onDisappear { cancelContentScan() }
        .onChange(of: mode) { _, newMode in
            selectedPaths.removeAll()
            if newMode == .identicalContent && contentGroups.isEmpty && !isScanningContent {
                startContentScan()
            }
        }
        .onChange(of: scope) { _, _ in
            selectedPaths.removeAll()
            if mode == .identicalContent {
                startContentScan()
            }
        }
        .confirmationDialog(
            pendingDeleteMode == .permanentlyDelete
                ? "선택한 중복 영상 \(selectedURLs.count)개를 디스크에서 영구 삭제할까요?"
                : "선택한 중복 영상 \(selectedURLs.count)개를 휴지통으로 이동할까요?",
            isPresented: Binding(
                get: { pendingDeleteMode != nil },
                set: { if !$0 { pendingDeleteMode = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteMode
        ) { deleteMode in
            Button(
                deleteMode == .permanentlyDelete
                    ? "\(selectedURLs.count)개 파일 영구 삭제"
                    : "\(selectedURLs.count)개 파일 휴지통으로 이동",
                role: .destructive
            ) {
                executeDeletion(mode: deleteMode)
            }
            Button("취소", role: .cancel) {}
        } message: { deleteMode in
            let sizeStr = ByteCountFormatter.string(fromByteCount: selectedByteCount, countStyle: .file)
            if deleteMode == .permanentlyDelete {
                Text("총 \(sizeStr) 용량의 파일 \(selectedURLs.count)개가 휴지통을 거치지 않고 디스크에서 즉시 영구 삭제됩니다. 이 작업은 되돌릴 수 없습니다.")
            } else {
                Text("총 \(sizeStr) 용량의 파일 \(selectedURLs.count)개를 Finder의 휴지통으로 이동합니다. 휴지통에서 복구할 수 있습니다.")
            }
        }
    }

    @ViewBuilder
    private func duplicateFileRow(url: URL, group: MediaDuplicateGroup) -> some View {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let isChecked = selectedPaths.contains(path)
        let libItem = libraryItemsByPath[path]
        let slot = controller.slotNumber(for: url)
        let size = libItem?.size ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
        let busy = AppModel.videoIsBeingProcessed(url)

        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isChecked },
                set: { checked in
                    if checked { selectedPaths.insert(path) } else { selectedPaths.remove(path) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(busy)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let slot {
                        Text("멀티뷰 #\(slot)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    if libItem?.hasResults == true {
                        Label("번역 결과 있음", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if busy {
                        Label("처리 중", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if size > 0 {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "finder")
            }
            .buttonStyle(.borderless)
            .help("Finder에서 보기")
        }
        .padding(.vertical, 2)
    }

    private func groupSelectablePaths(for group: MediaDuplicateGroup) -> Set<String> {
        Set(
            group.urls
                .filter { !AppModel.videoIsBeingProcessed($0) }
                .map { $0.standardizedFileURL.path(percentEncoded: false) }
        )
    }

    private func toggleSelectAll() {
        let selectable = allSelectablePaths
        if !selectable.isEmpty && selectable.isSubset(of: selectedPaths) {
            selectedPaths.subtract(selectable)
        } else {
            selectedPaths.formUnion(selectable)
        }
    }

    private func selectRecommendedDuplicates() {
        var recommended = Set<String>()
        for group in activeGroups where group.urls.count > 1 {
            // 번역 결과가 있거나 멀티뷰 앞 슬롯에 열린 원본 1개를 보존 대상으로 우선 선택합니다.
            let ranked = group.urls.sorted { lhs, rhs in
                let lhsPath = lhs.standardizedFileURL.path(percentEncoded: false)
                let rhsPath = rhs.standardizedFileURL.path(percentEncoded: false)
                let lhsHasResults = libraryItemsByPath[lhsPath]?.hasResults == true
                let rhsHasResults = libraryItemsByPath[rhsPath]?.hasResults == true
                if lhsHasResults != rhsHasResults { return lhsHasResults }
                let lhsSlot = controller.slotNumber(for: lhs) ?? Int.max
                let rhsSlot = controller.slotNumber(for: rhs) ?? Int.max
                if lhsSlot != rhsSlot { return lhsSlot < rhsSlot }
                return lhsPath.localizedStandardCompare(rhsPath) == .orderedAscending
            }
            for redundant in ranked.dropFirst() where !AppModel.videoIsBeingProcessed(redundant) {
                recommended.insert(redundant.standardizedFileURL.path(percentEncoded: false))
            }
        }
        selectedPaths = recommended
    }

    private func startContentScan() {
        cancelContentScan()
        let urls = candidateURLs
        guard urls.count >= 2 else {
            contentGroups = []
            contentScanMessage = "비교할 영상이 2개 이상 필요합니다."
            return
        }
        isScanningContent = true
        contentScanMessage = "\(urls.count)개 영상의 크기와 내용 해시를 비교하는 중…"
        contentScanTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                try MediaFilenameDeduplicator.contentDuplicateGroups(for: urls)
            }
            do {
                let found = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                contentGroups = found
                let removable = found.reduce(0) { $0 + max(0, $1.urls.count - 1) }
                contentScanMessage = found.isEmpty
                    ? "내용이 완전히 같은 중복 영상을 찾지 못했습니다."
                    : "동일 내용 \(found.count)묶음 · 정리 가능 \(removable)개"
            } catch is CancellationError {
                contentScanMessage = "내용 스캔을 취소했습니다."
            } catch {
                contentScanMessage = "스캔 오류: \(error.localizedDescription)"
            }
            isScanningContent = false
        }
    }

    private func cancelContentScan() {
        contentScanTask?.cancel()
        contentScanTask = nil
        isScanningContent = false
    }

    private func executeDeletion(mode deleteMode: MediaLibrary.VideoDeleteMode) {
        let targets = selectedURLs
        guard !targets.isEmpty, !isDeleting else { return }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            let outcome = await controller.deleteVideoFiles(urls: targets, mode: deleteMode)
            let deletedPaths = Set(outcome.deletedURLs.map { $0.standardizedFileURL.path(percentEncoded: false) })
            selectedPaths.subtract(deletedPaths)
            // 삭제된 항목을 내용 중복 목록에서도 즉시 반영
            contentGroups = contentGroups.compactMap { group in
                let remaining = group.urls.filter { !deletedPaths.contains($0.standardizedFileURL.path(percentEncoded: false)) }
                guard remaining.count > 1 else { return nil }
                return MediaDuplicateGroup(
                    id: group.id,
                    reason: group.reason,
                    title: remaining[0].lastPathComponent,
                    byteCount: group.byteCount,
                    urls: remaining
                )
            }
            resultBanner = outcome.summaryMessage
        }
    }
}
