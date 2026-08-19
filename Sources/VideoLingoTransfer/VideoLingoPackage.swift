import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let videoLingoPackage = UTType(exportedAs: "com.vvv.videolingo.package", conformingTo: .package)
}

struct VideoLingoPackageManifest: Codable, Sendable {
    static let currentVersion = 1

    let formatVersion: Int
    let title: String
    let createdAt: Date
    let mediaFilename: String
    let tracks: [VideoLingoCaptionTrack]
}

struct VideoLingoCaptionTrack: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case transcript
        case translation
    }

    let id: String
    let kind: Kind
    let languageCode: String?
    let displayName: String
    let cues: [VideoLingoCaptionCue]
}

struct VideoLingoCaptionCue: Codable, Hashable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

enum VideoLingoPackageIO {
    static let manifestFilename = "manifest.json"

    static func write(
        to destination: URL,
        mediaURL: URL,
        title: String,
        tracks: [VideoLingoCaptionTrack]
    ) throws {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathExtension("videolingo")
        defer { try? manager.removeItem(at: staging) }

        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        let mediaFilename = "video.\(mediaURL.pathExtension.isEmpty ? "mp4" : mediaURL.pathExtension.lowercased())"
        try manager.copyItem(at: mediaURL, to: staging.appendingPathComponent(mediaFilename))

        let manifest = VideoLingoPackageManifest(
            formatVersion: VideoLingoPackageManifest.currentVersion,
            title: title,
            createdAt: Date(),
            mediaFilename: mediaFilename,
            tracks: tracks
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: staging.appendingPathComponent(manifestFilename),
            options: .atomic
        )

        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
    }

    static func read(from packageURL: URL) throws -> (VideoLingoPackageManifest, URL) {
        let manifestURL = packageURL.appendingPathComponent(manifestFilename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(VideoLingoPackageManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.formatVersion <= VideoLingoPackageManifest.currentVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "이 패키지는 더 새로운 VideoLingo 버전에서 생성되었습니다."
            ])
        }
        let mediaURL = packageURL.appendingPathComponent(manifest.mediaFilename)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "패키지에 영상 파일이 없습니다."])
        }
        return (manifest, mediaURL)
    }
}
