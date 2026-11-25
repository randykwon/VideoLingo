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

        let asset = AVURLAsset(url: self.url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.volume = volume
        player.isMuted = isMuted

        durationTask?.cancel()
        durationTask = Task { [weak self] in
            if let loaded = try? await asset.load(.duration), loaded.seconds.isFinite, loaded.seconds > 0 {
                self?.duration = loaded.seconds
            }
        }

        loadSubtitles(preferredLanguage: preferredLanguage, preferredTranslationModel: preferredTranslationModel)

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let sec = time.seconds
            Task { @MainActor [weak self] in
                guard let self, sec.isFinite else { return }
                let clamped = max(0, sec)
                self.currentTime = clamped
                self.updateActiveSubtitle(at: clamped)
                let running = self.player.rate != 0
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
                    self.player.playImmediately(atRate: self.playbackRate)
                    self.isPlaying = true
                } else {
                    self.isPlaying = false
                }
            }
        }

        if autoPlay {
            play()
        } else {
            isPlaying = false
        }
    }

    func play() {
        player.playImmediately(atRate: playbackRate)
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
    var alwaysShowTileControls = true
    var autoArrangeOnCountChange = true
    /// 멀티 뷰 전체 자막 표시 여부 (추가/제외 토글)
    var subtitlesEnabled = true
    /// 자막 표시 시 원문 STT와 번역 자막을 함께 볼지 여부
    var showOriginalWithTranslation = false
    /// 멀티 뷰 자막 언어 코드 (비어 있으면 원문 STT만 표시)
    var subtitleLanguage: String = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "ko"
    var statusBanner: String?

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
        statusBanner = nil
    }

    func applyPreset(_ preset: MultiViewLayoutPreset, resetAutoArrange: Bool = true) {
        activePreset = preset
        if resetAutoArrange {
            autoArrangeOnCountChange = true
        }
        maximizedTileID = nil
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
    @State private var isDropTargeted = false
    @State private var showClearConfirm = false

    private var controller: ViewingMultiViewController { model.multiView }

    var body: some View {
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

            // 전체 재생/음소거 제어
            HStack(spacing: 4) {
                Button("모두 재생", systemImage: "play.fill") { controller.playAll() }
                    .labelStyle(.iconOnly)
                    .help("열린 모든 영상 재생")
                Button("모두 일시 정지", systemImage: "pause.fill") { controller.pauseAll() }
                    .labelStyle(.iconOnly)
                    .help("열린 모든 영상 일시 정지")
                Button(
                    controller.allMuted ? "모두 소리 켜기" : "모두 음소거",
                    systemImage: controller.allMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
                ) {
                    if controller.allMuted { controller.unmuteAll() } else { controller.muteAll() }
                }
                .labelStyle(.iconOnly)
                .help(controller.allMuted ? "모든 영상 음소거 해제" : "모든 영상 음소거")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(controller.tiles.isEmpty)

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

            // 자주 쓰는 2개 프리셋 빠른 버튼
            Button("자동 격자", systemImage: "rectangle.grid.2x2") {
                withAnimation(.snappy) { controller.applyPreset(.autoGrid) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(controller.tiles.isEmpty)
            .help("1~8개 자동 격자 정렬")

            Button("메인 강조", systemImage: "rectangle.split.2x1") {
                withAnimation(.snappy) { controller.applyPreset(.spotlight) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(controller.tiles.count < 2)
            .help("1번 영상을 크게, 나머지를 보조 화면으로 배치")

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

    private var controller: ViewingMultiViewController { model.multiView }
    private var isSelected: Bool { controller.selectedTileID == tile.id }
    private var showChrome: Bool {
        controller.alwaysShowTileControls || isHovering || isSelected || moveStartRect != nil || resizeStartRect != nil
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
            Button("메인 화면으로 강조", systemImage: "rectangle.split.2x1") {
                withAnimation(.snappy) { controller.promoteToMain(tile.id) }
            }
            Button(isMaximized ? "원래 크기로 복귀" : "이 영상만 크게 보기", systemImage: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                withAnimation(.snappy) {
                    controller.maximizedTileID = isMaximized ? nil : tile.id
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
            Divider()
            Button("슬롯 닫기", systemImage: "xmark", role: .destructive) {
                withAnimation(.snappy) { controller.removeTile(tile.id) }
            }
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(moveDragGesture)
            .help(isMaximized ? tile.title : "드래그해 화면 위치를 자유롭게 이동하세요")

            HStack(spacing: 4) {
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
                        controller.maximizedTileID = isMaximized ? nil : tile.id
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
                    Divider()
                    Button("다른 영상으로 교체…", systemImage: "arrow.triangle.2.circlepath") {
                        controller.replaceVideoWithPanel(tileID: tile.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("속도 · 반복 · 화면 맞춤 · 영상 교체")

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
