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
    private static let disabledFoldersKey = "mediaLibraryDisabledFolderPaths"
    var folders: [URL] = []
    private(set) var disabledFolderPaths: Set<String> = []
    private(set) var items: [MediaLibraryItem] = []
    private(set) var isScanning = false
    private(set) var movingVideoPaths: Set<String> = []
    private(set) var statusMessage = ""
    private(set) var lastScannedAt: Date?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    private init() {
        folders = (UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? [])
            .map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL }
        disabledFolderPaths = Set(UserDefaults.standard.stringArray(forKey: Self.disabledFoldersKey) ?? [])
        persistFolders()
        if !enabledFolders.isEmpty { refresh() }
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
        additions.forEach { disabledFolderPaths.remove(folderKey($0)) }
        folders.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        persistFolders()
        refresh()
    }

    func removeFolder(_ url: URL) {
        removeFolders([url])
    }

    func removeFolders(_ urls: [URL]) {
        let keys = Set(urls.map(folderKey))
        folders.removeAll { keys.contains(folderKey($0)) }
        disabledFolderPaths.subtract(keys)
        persistFolders()
        refresh()
    }

    func removeUnavailableFolders() {
        removeFolders(folders.filter { !isFolderAvailable($0) })
    }

    func isFolderEnabled(_ url: URL) -> Bool {
        !disabledFolderPaths.contains(folderKey(url))
    }

    func isFolderAvailable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func setFolder(_ url: URL, enabled: Bool) {
        let key = folderKey(url)
        if enabled {
            disabledFolderPaths.remove(key)
        } else {
            disabledFolderPaths.insert(key)
        }
        persistFolders()
        refresh()
    }

    var enabledFolders: [URL] {
        folders.filter { isFolderEnabled($0) && isFolderAvailable($0) }
    }

    var unavailableFolderCount: Int {
        folders.lazy.filter { !self.isFolderAvailable($0) }.count
    }

    func videoCount(in folder: URL) -> Int {
        items.lazy.filter { $0.rootURL.standardizedFileURL == folder.standardizedFileURL }.count
    }

    func refresh() {
        scanTask?.cancel()
        let roots = enabledFolders
        guard !roots.isEmpty else {
            items = []
            isScanning = false
            statusMessage = folders.isEmpty
                ? "관리할 폴더를 추가하세요."
                : "검색 가능한 활성 폴더가 없습니다. 폴더 상태를 확인하세요."
            return
        }
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
                return // A replaced scan must not clear the newer scan's progress state.
            } catch {
                self?.statusMessage = String(localized: "라이브러리를 검색하지 못했습니다: \(error.localizedDescription)")
            }
            self?.isScanning = false
            self?.scanTask = nil
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        statusMessage = String(localized: "라이브러리 검색을 취소했습니다.")
    }

    func revealVideo(_ item: MediaLibraryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.videoURL])
    }

    /// 단일 영상의 STT·번역 사이드카 요약만 즉시 갱신합니다 (전체 폴더 재검색 없음).
    func refreshResultSummary(for url: URL) {
        let target = url.standardizedFileURL
        guard let index = items.firstIndex(where: { $0.videoURL.standardizedFileURL == target }) else { return }
        let current = items[index]
        let updatedSummary = MediaSidecarStore.resultSummary(for: current.videoURL)
        items[index] = MediaLibraryItem(
            videoURL: current.videoURL,
            rootURL: current.rootURL,
            size: current.size,
            modifiedAt: current.modifiedAt,
            resultSummary: updatedSummary
        )
    }

    func revealVideos(_ items: [MediaLibraryItem]) {
        let urls = items.map(\.videoURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    enum VideoDeleteMode: Sendable, Equatable {
        case moveToTrash
        case permanentlyDelete

        var actionTitle: String {
            switch self {
            case .moveToTrash: "휴지통으로 이동"
            case .permanentlyDelete: "영구 삭제"
            }
        }
    }

    struct VideoDeletionOutcome: Sendable {
        let deletedURLs: [URL]
        let failed: [String]
        let mode: VideoDeleteMode

        var deletedCount: Int { deletedURLs.count }

        var summaryMessage: String {
            let verb = mode == .permanentlyDelete ? "디스크에서 영구 삭제했습니다" : "휴지통으로 이동했습니다"
            if failed.isEmpty {
                return "영상 \(deletedCount)개를 \(verb)."
            }
            let prefix = deletedCount > 0 ? "영상 \(deletedCount)개 처리 · " : ""
            return "\(prefix)실패 \(failed.count)개: \(failed.prefix(3).joined(separator: ", "))"
        }
    }

    func isMovingVideo(_ url: URL) -> Bool {
        movingVideoPaths.contains(url.standardizedFileURL.path(percentEncoded: false))
    }

    func trashVideos(_ items: [MediaLibraryItem]) async -> String {
        let outcome = await deleteVideos(urls: items.map(\.videoURL), mode: .moveToTrash)
        return outcome.summaryMessage
    }

    /// 영상 파일을 휴지통으로 이동하거나 디스크에서 즉시 영구 삭제합니다.
    /// 삭제 전 열려 있는 플레이어·멀티뷰·호환 스트림 세션을 먼저 해제해 외장 디스크(ExFAT 등)에서도 안전하게 정리합니다.
    func deleteVideos(urls rawURLs: [URL], mode: VideoDeleteMode) async -> VideoDeletionOutcome {
        var uniqueByPath: [String: URL] = [:]
        for url in rawURLs {
            let std = url.standardizedFileURL
            uniqueByPath[std.path(percentEncoded: false)] = std
        }
        let uniqueURLs = Array(uniqueByPath.values)
        guard !uniqueURLs.isEmpty else {
            return VideoDeletionOutcome(deletedURLs: [], failed: ["삭제할 영상이 없습니다."], mode: mode)
        }

        let paths = Set(uniqueByPath.keys)
        guard movingVideoPaths.isDisjoint(with: paths) else {
            return VideoDeletionOutcome(deletedURLs: [], failed: ["이미 삭제 작업이 진행 중인 영상이 포함되어 있습니다."], mode: mode)
        }

        var deletableURLs: [URL] = []
        var preFailed: [String] = []
        for url in uniqueURLs {
            if AppModel.videoIsBeingProcessed(url) {
                preFailed.append("\(url.lastPathComponent): 번역 처리 중")
            } else {
                deletableURLs.append(url)
            }
        }
        guard !deletableURLs.isEmpty else {
            return VideoDeletionOutcome(deletedURLs: [], failed: preFailed, mode: mode)
        }

        movingVideoPaths.formUnion(paths)
        defer { movingVideoPaths.subtract(paths) }

        // 파일 디스크립터 및 FFmpeg 호환 프록시 세션을 삭제 전에 먼저 해제합니다.
        for url in deletableURLs {
            AppModel.releaseDeletedVideo(url)
        }

        let targetURLs = deletableURLs
        let result = await Task.detached(priority: .userInitiated) {
            var deletedURLs: [URL] = []
            var removedPaths: Set<String> = []
            var failed: [String] = []
            let fm = FileManager.default
            for url in targetURLs {
                do {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    switch mode {
                    case .moveToTrash:
                        try fm.trashItem(at: url, resultingItemURL: nil)
                    case .permanentlyDelete:
                        try fm.removeItem(at: url)
                    }
                    deletedURLs.append(url)
                    removedPaths.insert(url.standardizedFileURL.path(percentEncoded: false))
                } catch {
                    failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return (deletedURLs: deletedURLs, failed: failed, removedPaths: removedPaths)
        }.value

        if !result.removedPaths.isEmpty {
            self.items.removeAll { result.removedPaths.contains($0.id) }
            refresh()
        }
        return VideoDeletionOutcome(
            deletedURLs: result.deletedURLs,
            failed: preFailed + result.failed,
            mode: mode
        )
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
        disabledFolderPaths.formIntersection(Set(folders.map(folderKey)))
        UserDefaults.standard.set(folders.map { $0.path(percentEncoded: false) }, forKey: Self.foldersKey)
        UserDefaults.standard.set(Array(disabledFolderPaths).sorted(), forKey: Self.disabledFoldersKey)
    }

    private func folderKey(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }
}
