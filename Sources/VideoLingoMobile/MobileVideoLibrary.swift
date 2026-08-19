import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class MobileVideoLibrary {
    let player = AVPlayer()
    private(set) var videoURL: URL?
    private(set) var isImporting = false
    var errorMessage: String?

    init() {
        restoreLastVideo()
    }

    var title: String {
        videoURL?.deletingPathExtension().lastPathComponent ?? "VideoLingo"
    }

    func importVideo(from sourceURL: URL) async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let destination = try Self.destinationURL(for: sourceURL)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
            load(destination)
            UserDefaults.standard.set(destination.lastPathComponent, forKey: "lastMobileVideo")
        } catch {
            errorMessage = "영상을 가져오지 못했습니다. 파일 접근 권한과 저장 공간을 확인해 주세요.\n\(error.localizedDescription)"
        }
    }

    func clearVideo() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoURL = nil
        UserDefaults.standard.removeObject(forKey: "lastMobileVideo")
    }

    private func load(_ url: URL) {
        videoURL = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    private func restoreLastVideo() {
        guard let filename = UserDefaults.standard.string(forKey: "lastMobileVideo"),
              let directory = try? Self.videoDirectory(),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path)
        else { return }
        load(directory.appendingPathComponent(filename))
    }

    private static func destinationURL(for sourceURL: URL) throws -> URL {
        let directory = try videoDirectory()
        let safeName = sourceURL.lastPathComponent.isEmpty ? "video.mov" : sourceURL.lastPathComponent
        return directory.appendingPathComponent(safeName)
    }

    private static func videoDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Imported Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
