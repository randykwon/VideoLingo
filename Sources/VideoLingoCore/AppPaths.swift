import Foundation

public struct AppPaths: Sendable {
    public let root: URL
    public let database: URL
    public let jobs: URL
    public let models: URL

    public init(fileManager: FileManager = .default) throws {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        root = support.appending(path: "VideoLingo", directoryHint: .isDirectory)
        database = root.appending(path: "videolingo.sqlite")
        jobs = root.appending(path: "Jobs", directoryHint: .isDirectory)
        models = root.appending(path: "Models", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: jobs, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: models, withIntermediateDirectories: true)
    }

    public func workspace(for jobID: UUID) -> URL {
        jobs.appending(path: jobID.uuidString, directoryHint: .isDirectory)
    }
}
