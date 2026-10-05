import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import VideoLingoCore

struct MediaLibraryItem: Identifiable, Sendable {
    let videoURL: URL
    let rootURL: URL
    let size: Int64
    let modifiedAt: Date?
    let resultSummary: MediaSidecarSummary

    var id: String { videoURL.standardizedFileURL.path(percentEncoded: false) }
    var title: String { videoURL.deletingPathExtension().lastPathComponent }
    var directoryName: String { videoURL.deletingLastPathComponent().lastPathComponent }
    var hasResults: Bool { resultSummary.hasTranscript || resultSummary.translationFileCount > 0 }
}

@MainActor
@Observable
final class MediaLibrary {
    static let shared = MediaLibrary()

    private static let foldersKey = "mediaLibraryFolderPaths"
    var folders: [URL] = []
    private(set) var items: [MediaLibraryItem] = []
    private(set) var isScanning = false
    private(set) var statusMessage = ""
    private(set) var lastScannedAt: Date?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    private init() {
        folders = (UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? [])
            .map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        persistFolders()
        if !folders.isEmpty { refresh() }
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "영상 라이브러리에 추가할 폴더를 선택하세요")
        panel.prompt = String(localized: "라이브러리에 추가")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        PanelLocationMemory.restore(into: panel, purpose: .batchFolders)
        guard panel.runModal() == .OK else { return }
        PanelLocationMemory.remember(first: panel.urls, purpose: .batchFolders)
        addFolders(panel.urls)
    }

    func addFolders(_ urls: [URL]) {
        let additions = urls
            .map(\.standardizedFileURL)
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for url in additions where !folders.contains(url) { folders.append(url) }
        folders.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        persistFolders()
        refresh()
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        persistFolders()
        refresh()
    }

    func refresh() {
        scanTask?.cancel()
        guard !folders.isEmpty else {
            items = []
            isScanning = false
            statusMessage = "관리할 폴더를 추가하세요."
            return
        }
        let roots = folders
        isScanning = true
        statusMessage = String(localized: "등록된 \(roots.count)개 폴더에서 영상과 번역 파일을 찾는 중…")
        scanTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try Self.discover(in: roots) }
            do {
                let discovered = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled else { return }
                self.items = discovered
                self.lastScannedAt = .now
                let translated = discovered.filter(\.hasResults).count
                self.statusMessage = String(localized: "영상 \(discovered.count)개 · STT/번역 결과 있음 \(translated)개")
            } catch is CancellationError {
                self?.statusMessage = String(localized: "라이브러리 검색을 취소했습니다.")
            } catch {
                self?.statusMessage = String(localized: "라이브러리를 검색하지 못했습니다: \(error.localizedDescription)")
            }
            self?.isScanning = false
            self?.scanTask = nil
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func revealVideo(_ item: MediaLibraryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.videoURL])
    }

    func revealResults(_ item: MediaLibraryItem) {
        guard let directory = MediaSidecarStore.existingResultsDirectoryURL(for: item.videoURL) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    nonisolated private static func discover(in roots: [URL]) throws -> [MediaLibraryItem] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey, .fileSizeKey, .contentModificationDateKey]
        let managedDirectories = ((try? manager.contentsOfDirectory(
            at: MediaSidecarStore.managedResultsRootURL(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "videolingo" }
        var found: [String: MediaLibraryItem] = [:]
        for root in roots {
            try Task.checkCancellation()
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true, isVideo(url, contentType: values.contentType) else { continue }
                let standardized = url.standardizedFileURL
                let item = MediaLibraryItem(
                    videoURL: standardized,
                    rootURL: root,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate,
                    resultSummary: MediaSidecarStore.resultSummary(
                        for: standardized,
                        cachedManagedDirectories: managedDirectories
                    )
                )
                found[item.id] = item
            }
        }
        return found.values.sorted { $0.videoURL.path.localizedStandardCompare($1.videoURL.path) == .orderedAscending }
    }

    nonisolated private static func isVideo(_ url: URL, contentType: UTType?) -> Bool {
        if let contentType, contentType.conforms(to: .movie) || contentType.conforms(to: .audiovisualContent) { return true }
        return ["mp4", "mov", "m4v", "mkv", "avi", "webm"].contains(url.pathExtension.lowercased())
    }

    private func persistFolders() {
        UserDefaults.standard.set(folders.map { $0.path(percentEncoded: false) }, forKey: Self.foldersKey)
    }
}
