import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class MobileVideoLibrary {
    let player = AVPlayer()
    private(set) var videoURL: URL?
    private(set) var captionTracks: [VideoLingoCaptionTrack] = []
    var selectedTrackID: String?
    private(set) var currentTime: TimeInterval = 0
    private(set) var isImporting = false
    var errorMessage: String?

    init() {
        player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.currentTime = time.seconds.isFinite ? time.seconds : 0 }
        }
        restoreLastVideo()
    }

    var title: String {
        videoURL?.deletingPathExtension().lastPathComponent ?? "VideoLingo"
    }

    var selectedTrack: VideoLingoCaptionTrack? {
        captionTracks.first { $0.id == selectedTrackID }
    }

    var currentCaption: String? {
        selectedTrack?.cues.first { currentTime >= $0.startTime && currentTime < $0.endTime }?.text
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
            captionTracks = []
            selectedTrackID = nil
            UserDefaults.standard.set(destination.lastPathComponent, forKey: "lastMobileVideo")
            UserDefaults.standard.removeObject(forKey: "lastMobilePackage")
        } catch {
            errorMessage = "영상을 가져오지 못했습니다. 파일 접근 권한과 저장 공간을 확인해 주세요.\n\(error.localizedDescription)"
        }
    }

    func importPackage(from sourceURL: URL) async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            let packages = try Self.packageDirectory()
            let destination = packages
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathExtension("videolingo")
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            }.value
            try loadPackage(at: destination)
            UserDefaults.standard.set(destination.lastPathComponent, forKey: "lastMobilePackage")
            UserDefaults.standard.removeObject(forKey: "lastMobileVideo")
        } catch {
            errorMessage = "VideoLingo 패키지를 가져오지 못했습니다.\n\(error.localizedDescription)"
        }
    }

    func clearVideo() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoURL = nil
        captionTracks = []
        selectedTrackID = nil
        UserDefaults.standard.removeObject(forKey: "lastMobileVideo")
        UserDefaults.standard.removeObject(forKey: "lastMobilePackage")
    }

    private func load(_ url: URL) {
        videoURL = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    private func restoreLastVideo() {
        if let packageName = UserDefaults.standard.string(forKey: "lastMobilePackage"),
           let directory = try? Self.packageDirectory(),
           (try? loadPackage(at: directory.appendingPathComponent(packageName))) != nil {
            return
        }
        guard let filename = UserDefaults.standard.string(forKey: "lastMobileVideo"),
              let directory = try? Self.videoDirectory(),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path)
        else { return }
        load(directory.appendingPathComponent(filename))
    }

    private func loadPackage(at url: URL) throws {
        let (manifest, mediaURL) = try VideoLingoPackageIO.read(from: url)
        load(mediaURL)
        captionTracks = manifest.tracks
        selectedTrackID = manifest.tracks.first(where: { $0.kind == .translation })?.id
            ?? manifest.tracks.first?.id
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

    private static func packageDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Imported Packages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
