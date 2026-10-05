import AppKit
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

    private var visibleItems: [MediaLibraryItem] {
        library.items.filter { item in
            let matchesFilter = switch filter {
            case .all: true
            case .translated: item.hasResults
            case .untranslated: !item.hasResults
            }
            let matchesSearch = searchText.isEmpty
                || item.title.localizedCaseInsensitiveContains(searchText)
                || item.videoURL.path.localizedCaseInsensitiveContains(searchText)
                || item.resultSummary.translationLanguages.contains { $0.localizedCaseInsensitiveContains(searchText) }
            return matchesFilter && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("영상·경로·번역 언어 검색", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Picker("결과", selection: $filter) {
                    ForEach(MediaLibraryResultFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
                if library.isScanning { ProgressView().controlSize(.small) }
                Button("새로 고침", systemImage: "arrow.clockwise") { library.refresh() }
                    .disabled(library.isScanning || library.folders.isEmpty)
                Button("폴더 추가…", systemImage: "folder.badge.plus") { library.chooseFolders() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            if library.folders.isEmpty {
                ContentUnavailableView {
                    Label("공용 영상 라이브러리", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("여러 디렉터리를 등록하면 영상과 STT·번역 결과를 찾아 대량번역 목록에서 함께 관리합니다.")
                } actions: {
                    Button("폴더 추가…") { library.chooseFolders() }.buttonStyle(.borderedProminent)
                }
            } else if visibleItems.isEmpty && !library.isScanning {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(selection: $selection) {
                    ForEach(visibleItems) { item in
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
                        }
                        .tag(item.id)
                        .contextMenu {
                            Button("대량번역 목록에 추가", systemImage: "text.badge.plus") { _ = processor.add([item.videoURL]) }
                            Button("Finder에서 영상 보기", systemImage: "finder") { library.revealVideo(item) }
                            Button("번역 결과 폴더 열기", systemImage: "captions.bubble") { library.revealResults(item) }
                                .disabled(!item.hasResults)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 12) {
                Text(library.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("\(selection.count)개 선택").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("선택 항목을 대량번역 목록에 추가", systemImage: "text.badge.plus") {
                    let urls = library.items.filter { selection.contains($0.id) }.map(\.videoURL)
                    _ = processor.add(urls)
                    selection.removeAll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
            }
            .padding(16)
            .background(.bar)
        }
    }
}
