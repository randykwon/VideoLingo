import AppKit
import AVKit
import SwiftUI

private enum MediaLibraryResultFilter: String, CaseIterable, Identifiable {
    case all, translated, untranslated
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "전체"
        case .translated: "결과 있음"
        case .untranslated: "미처리"
        }
    }
}

struct PlayerMediaLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var library = MediaLibrary.shared
    @State private var searchText = ""

    private var visibleItems: [MediaLibraryItem] {
        guard !searchText.isEmpty else { return library.items }
        return library.items.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.videoURL.path.localizedCaseInsensitiveContains(searchText)
                || $0.resultSummary.translationLanguages.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("영상·폴더·번역 언어 검색", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button("새로 고침", systemImage: "arrow.clockwise") { library.refresh() }
                    .labelStyle(.iconOnly)
                    .disabled(library.isScanning || library.folders.isEmpty)
                    .help("등록한 모든 폴더 다시 검색")
                Menu("라이브러리 폴더", systemImage: "folder") {
                    Button("폴더 추가…", systemImage: "folder.badge.plus") { library.chooseFolders() }
                    if !library.folders.isEmpty {
                        Divider()
                        ForEach(library.folders, id: \.path) { folder in
                            Menu(folder.lastPathComponent) {
                                Button("Finder에서 보기", systemImage: "finder") { NSWorkspace.shared.open(folder) }
                                Button("라이브러리에서 제거", systemImage: "minus.circle", role: .destructive) { library.removeFolder(folder) }
                            }
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .help("라이브러리 폴더 관리")
            }

            if library.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(library.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("취소", role: .cancel) { library.cancelScan() }.controlSize(.small)
                }
            } else if library.folders.isEmpty {
                ContentUnavailableView {
                    Label("영상 폴더를 추가하세요", systemImage: "folder.badge.plus")
                } description: {
                    Text("여러 폴더의 영상과 번역 결과를 한곳에서 찾을 수 있습니다.")
                } actions: {
                    Button("폴더 추가…") { library.chooseFolders() }.buttonStyle(.borderedProminent)
                }
            } else if visibleItems.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(visibleItems) { item in
                    Button { model.openLibraryVideo(item.videoURL) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.hasResults ? "play.rectangle.fill" : "play.rectangle")
                                .foregroundStyle(item.hasResults ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(item.directoryName)
                                    if item.resultSummary.hasTranscript { Text("STT \(item.resultSummary.transcriptSegmentCount)") }
                                    if !item.resultSummary.translationLanguages.isEmpty {
                                        Text(item.resultSummary.translationLanguages.map { $0.uppercased() }.joined(separator: ", "))
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("재생", systemImage: "play.fill") { model.openLibraryVideo(item.videoURL) }
                        Button("Finder에서 영상 보기", systemImage: "finder") { library.revealVideo(item) }
                        Button("번역 결과 폴더 열기", systemImage: "captions.bubble") { library.revealResults(item) }
                            .disabled(!item.hasResults)
                    }
                }
                .frame(minHeight: 180, idealHeight: 280)
            }

            if !library.statusMessage.isEmpty, !library.isScanning, !library.folders.isEmpty {
                Text(library.statusMessage).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct BatchMediaLibraryView: View {
    @Environment(BatchProcessor.self) private var processor
    @State private var library = MediaLibrary.shared
    @State private var selection: Set<String> = []
    @State private var searchText = ""
    @State private var filter: MediaLibraryResultFilter = .all
    @State private var sourceSelection = "smart:all"
    @State private var sortOrder: LibrarySortOrder = .name
    @State private var presentation: LibraryPresentation = .list
    @State private var multiViewItems: [MediaLibraryItem] = []
    @State private var pendingFolderRemoval: URL?
    @State private var showingFolderManager = false

    private enum LibraryPresentation: String, CaseIterable, Identifiable {
        case list, multiView
        var id: Self { self }
        var title: String { self == .list ? "목록" : "멀티뷰" }
        var symbol: String { self == .list ? "list.bullet" : "rectangle.grid.2x2" }
    }

    private enum LibrarySortOrder: String, CaseIterable, Identifiable {
        case name, modified, size, folder
        var id: Self { self }
        var title: String {
            switch self {
            case .name: "이름"
            case .modified: "최근 수정"
            case .size: "파일 크기"
            case .folder: "폴더"
            }
        }
    }

    private var visibleItems: [MediaLibraryItem] {
        library.items.filter { item in
            let matchesSource: Bool
            switch sourceSelection {
            case "smart:translated": matchesSource = item.hasResults
            case "smart:untranslated": matchesSource = !item.hasResults
            case "smart:recent":
                matchesSource = item.modifiedAt.map { $0 >= Date.now.addingTimeInterval(-30 * 86_400) } ?? false
            case let value where value.hasPrefix("folder:"):
                matchesSource = item.rootURL.standardizedFileURL.path(percentEncoded: false) == String(value.dropFirst(7))
            default: matchesSource = true
            }
            let matchesFilter = switch filter {
            case .all: true
            case .translated: item.hasResults
            case .untranslated: !item.hasResults
            }
            let matchesSearch = searchText.isEmpty
                || item.title.localizedCaseInsensitiveContains(searchText)
                || item.videoURL.path.localizedCaseInsensitiveContains(searchText)
                || item.resultSummary.translationLanguages.contains { $0.localizedCaseInsensitiveContains(searchText) }
            return matchesSource && matchesFilter && matchesSearch
        }
        .sorted(by: sortItems)
    }

    var body: some View {
        NavigationSplitView {
            librarySidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            VStack(spacing: 0) {
                libraryToolbar
                Divider()
                libraryContent
                Divider()
                libraryFooter
            }
        }
        .confirmationDialog(
            "라이브러리에서 이 폴더를 제거할까요?",
            isPresented: Binding(
                get: { pendingFolderRemoval != nil },
                set: { if !$0 { pendingFolderRemoval = nil } }
            ),
            presenting: pendingFolderRemoval
        ) { folder in
            Button("라이브러리에서 제거", role: .destructive) {
                library.removeFolder(folder)
                sourceSelection = "smart:all"
                selection.removeAll()
                pendingFolderRemoval = nil
            }
            Button("취소", role: .cancel) { pendingFolderRemoval = nil }
        } message: { folder in
            Text("‘\(folder.lastPathComponent)’ 폴더의 실제 파일은 삭제되지 않습니다.")
        }
        .sheet(isPresented: $showingFolderManager) {
            LibraryFolderManagerView()
        }
        .onChange(of: sourceSelection) { _, _ in selection.removeAll() }
        .onChange(of: Set(library.items.map(\.id))) { _, availableIDs in
            selection.formIntersection(availableIDs)
            multiViewItems.removeAll { !availableIDs.contains($0.id) }
        }
    }

    private var librarySidebar: some View {
        List(selection: $sourceSelection) {
            Section("분류") {
                librarySourceRow("전체 영상", symbol: "film.stack", count: library.items.count, tag: "smart:all")
                librarySourceRow("번역 결과 있음", symbol: "checkmark.circle", count: library.items.filter(\.hasResults).count, tag: "smart:translated")
                librarySourceRow("미처리", symbol: "circle.dashed", count: library.items.filter { !$0.hasResults }.count, tag: "smart:untranslated")
                librarySourceRow("최근 30일", symbol: "clock", count: library.items.filter { $0.modifiedAt.map { $0 >= Date.now.addingTimeInterval(-30 * 86_400) } ?? false }.count, tag: "smart:recent")
            }
            Section("라이브러리 폴더") {
                ForEach(library.folders, id: \.path) { folder in
                    HStack(spacing: 8) {
                        Label(
                            folder.lastPathComponent,
                            systemImage: !library.isFolderAvailable(folder)
                                ? "folder.badge.questionmark"
                                : (library.isFolderEnabled(folder) ? "folder" : "folder.fill.badge.minus")
                        )
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(library.videoCount(in: folder))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(library.isFolderEnabled(folder) && library.isFolderAvailable(folder) ? .primary : .secondary)
                    .tag("folder:\(folder.standardizedFileURL.path(percentEncoded: false))")
                    .contextMenu {
                        Button(library.isFolderEnabled(folder) ? "검색에서 제외" : "검색에 포함",
                               systemImage: library.isFolderEnabled(folder) ? "pause.circle" : "play.circle") {
                            library.setFolder(folder, enabled: !library.isFolderEnabled(folder))
                        }
                        .disabled(!library.isFolderAvailable(folder))
                        Button("Finder에서 보기", systemImage: "finder") { NSWorkspace.shared.open(folder) }
                            .disabled(!library.isFolderAvailable(folder))
                        Divider()
                        Button("라이브러리에서 제거", systemImage: "minus.circle", role: .destructive) {
                            pendingFolderRemoval = folder
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("폴더 추가", systemImage: "plus") { library.chooseFolders() }
                    .labelStyle(.iconOnly)
                    .help("영상 라이브러리 폴더 추가")
                Button("선택 폴더 제거", systemImage: "minus") {
                    if let folder = selectedFolder { pendingFolderRemoval = folder }
                }
                .labelStyle(.iconOnly)
                .disabled(selectedFolder == nil)
                .help(selectedFolder == nil ? "제거할 폴더를 선택하세요" : "선택한 폴더를 라이브러리에서 제거")
                Button("폴더 목록 관리", systemImage: "slider.horizontal.3") {
                    showingFolderManager = true
                }
                .labelStyle(.iconOnly)
                .help("폴더 상태 확인 및 여러 폴더 관리")
                Spacer()
                Button("새로 고침", systemImage: "arrow.clockwise") { library.refresh() }
                    .labelStyle(.iconOnly)
                    .disabled(library.isScanning || library.folders.isEmpty)
                    .help("등록한 폴더 다시 검색")
            }
            .padding(8)
            .background(.bar)
        }
    }

    private var libraryToolbar: some View {
        HStack(spacing: 12) {
            TextField("영상·경로·번역 언어 검색", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Picker("결과", selection: $filter) {
                ForEach(MediaLibraryResultFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Picker("정렬", selection: $sortOrder) {
                ForEach(LibrarySortOrder.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 130)
            Spacer(minLength: 8)
            if library.isScanning { ProgressView().controlSize(.small) }
            Picker("보기", selection: $presentation) {
                ForEach(LibraryPresentation.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
        }
        .padding(12)
    }

    @ViewBuilder private var libraryContent: some View {
        if library.folders.isEmpty {
            ContentUnavailableView {
                Label("공용 영상 라이브러리", systemImage: "rectangle.stack.badge.plus")
            } description: {
                Text("여러 폴더를 등록하고 영상과 STT·번역 결과를 한곳에서 분류해 볼 수 있습니다.")
            } actions: {
                Button("폴더 추가…") { library.chooseFolders() }.buttonStyle(.borderedProminent)
            }
        } else if visibleItems.isEmpty && !library.isScanning {
            ContentUnavailableView(
                searchText.isEmpty ? "이 분류에 영상이 없습니다" : "검색 결과가 없습니다",
                systemImage: "film.stack",
                description: Text(searchText.isEmpty ? "다른 분류나 폴더를 선택하세요." : "다른 검색어를 입력해 보세요.")
            )
        } else if presentation == .multiView {
            LibraryMultiView(items: multiViewItems)
        } else {
            List(selection: $selection) {
                ForEach(visibleItems) { item in
                    libraryRow(item)
                        .tag(item.id)
                        .contextMenu { libraryContextMenu(item) }
                }
            }
        }
    }

    private var libraryFooter: some View {
        HStack(spacing: 12) {
            Text(library.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text("\(selection.count)개 선택").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button("멀티뷰로 보기", systemImage: "rectangle.grid.2x2") {
                multiViewItems = library.items.filter { selection.contains($0.id) }
                presentation = .multiView
            }
            .disabled(selection.isEmpty)
            .help(selection.isEmpty ? "먼저 재생할 영상을 선택하세요" : "선택한 영상을 멀티뷰에서 열기")
            Button("대량번역 목록에 추가", systemImage: "text.badge.plus") {
                let urls = library.items.filter { selection.contains($0.id) }.map(\.videoURL)
                _ = processor.add(urls)
                selection.removeAll()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)
        }
        .padding(12)
        .background(.bar)
    }

    private func librarySourceRow(_ title: String, symbol: String, count: Int, tag: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .tag(tag)
    }

    private func libraryRow(_ item: MediaLibraryItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.hasResults ? "checkmark.circle.fill" : "film")
                .foregroundStyle(item.hasResults ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(item.videoURL.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.resultSummary.hasTranscript {
                Label("STT \(item.resultSummary.transcriptSegmentCount)", systemImage: "waveform")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !item.resultSummary.translationLanguages.isEmpty {
                Text(item.resultSummary.translationLanguages.map { $0.uppercased() }.joined(separator: ", "))
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
            }
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func libraryContextMenu(_ item: MediaLibraryItem) -> some View {
        Button("멀티뷰 선택에 추가", systemImage: "rectangle.grid.2x2") {
            selection.insert(item.id)
            multiViewItems = library.items.filter { selection.contains($0.id) }
        }
        Button("대량번역 목록에 추가", systemImage: "text.badge.plus") { _ = processor.add([item.videoURL]) }
        Divider()
        Button("Finder에서 영상 보기", systemImage: "finder") { library.revealVideo(item) }
        Button("번역 결과 폴더 열기", systemImage: "captions.bubble") { library.revealResults(item) }
            .disabled(!item.hasResults)
    }

    private var selectedFolder: URL? {
        guard sourceSelection.hasPrefix("folder:") else { return nil }
        let path = String(sourceSelection.dropFirst(7))
        return library.folders.first { $0.standardizedFileURL.path(percentEncoded: false) == path }
    }

    private func sortItems(_ lhs: MediaLibraryItem, _ rhs: MediaLibraryItem) -> Bool {
        switch sortOrder {
        case .name: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case .modified: return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
        case .size: return lhs.size > rhs.size
        case .folder:
            let result = lhs.directoryName.localizedStandardCompare(rhs.directoryName)
            return result == .orderedSame
                ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                : result == .orderedAscending
        }
    }
}

private struct LibraryMultiView: View {
    let items: [MediaLibraryItem]
    @AppStorage("libraryMultiViewColumns") private var columnCount = 2
    @State private var playingItems: Set<String> = []

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView(
                "멀티뷰에 영상이 없습니다",
                systemImage: "rectangle.grid.2x2",
                description: Text("목록 보기에서 영상을 여러 개 선택한 다음 ‘멀티뷰로 보기’를 누르세요.")
            )
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("선택 영상 \(items.count)개")
                        .font(.headline).monospacedDigit()
                    Text("재생할 영상만 체크하면 시스템 부하를 줄일 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(playingItems.isEmpty ? "전체 재생" : "전체 정지",
                           systemImage: playingItems.isEmpty ? "play.fill" : "stop.fill") {
                        playingItems = playingItems.isEmpty ? Set(items.map(\.id)) : []
                    }
                    Stepper(value: $columnCount, in: 1...4) {
                        Text("\(columnCount)열").monospacedDigit()
                    }
                    .fixedSize()
                }
                .controlSize(.small)
                .padding(12)
                Divider()
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount), spacing: 12) {
                        ForEach(items) { item in
                            LibraryMultiViewTile(
                                item: item,
                                playsVideo: Binding(
                                    get: { playingItems.contains(item.id) },
                                    set: { shouldPlay in
                                        if shouldPlay {
                                            playingItems.insert(item.id)
                                        } else {
                                            playingItems.remove(item.id)
                                        }
                                    }
                                )
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct LibraryMultiViewTile: View {
    let item: MediaLibraryItem
    @Binding var playsVideo: Bool
    @State private var player: AVPlayer?
    @State private var isMuted = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ZStack {
                        Color.black
                        Image(systemName: "play.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(.black)
            HStack(spacing: 8) {
                Toggle("재생", isOn: $playsVideo).toggleStyle(.checkbox)
                Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Button(isMuted ? "소리 켜기" : "소리 끄기", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    isMuted.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(isMuted ? "이 영상의 소리 켜기" : "이 영상 음소거")
            }
            .padding(10)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(playsVideo ? Color.accentColor : Color.secondary.opacity(0.2))
        }
        .onAppear { updatePlayback() }
        .onDisappear { releasePlayer() }
        .onChange(of: playsVideo) { _, _ in updatePlayback() }
        .onChange(of: isMuted) { _, value in player?.isMuted = value }
    }

    private func updatePlayback() {
        guard playsVideo else {
            player?.pause()
            return
        }
        if player == nil { player = AVPlayer(url: item.videoURL) }
        player?.isMuted = isMuted
        player?.play()
    }

    private func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}
