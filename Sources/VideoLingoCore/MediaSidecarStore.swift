import Foundation

public struct DiscoveredMediaSidecar: Sendable {
    public let jobID: UUID
    public let sttModel: String
    public let sourceLanguage: String?
    public let transcripts: [TranscriptSegment]
    public let translations: [TranslationSegment]
    public let translationModel: String?
}

public final class MediaSidecarStore: @unchecked Sendable {
    private struct TranscriptDocument: Codable {
        let version: Int
        let jobID: UUID
        let sttModel: String
        let sourceLanguage: String?
        let updatedAt: Date
        let segments: [TranscriptSegment]
    }

    private struct TranslationDocument: Codable {
        let version: Int
        let jobID: UUID
        let language: String
        let modelID: String
        let updatedAt: Date
        let segments: [TranslationSegment]
    }

    public let directoryURL: URL
    /// 원본 옆에 저장하지 못해 앱 관리 폴더로 대체했는지 여부입니다.
    public private(set) var usesManagedFallback = false
    private let jobID: UUID
    private let sttModel: String
    private let sourceLanguage: String?
    private let lock = NSLock()

    /// 결과를 저장할 폴더를 정합니다. 원본 영상 옆(또는 지정한 대체 폴더)에 쓸 수 없으면
    /// 앱이 관리하는 폴더로 자동 대체합니다. 예전에는 여기서 실패하면 작업 전체가 중단됐습니다.
    public init(mediaURL: URL, jobID: UUID, sttModel: String, sourceLanguage: String?, alternateRootURL: URL? = nil) throws {
        self.jobID = jobID
        self.sttModel = sttModel
        self.sourceLanguage = sourceLanguage
        let preferred = alternateRootURL.map {
            Self.alternateDirectoryURL(for: mediaURL, jobID: jobID, rootURL: $0)
        } ?? Self.directoryURL(for: mediaURL)
        if let usable = Self.prepareWritableDirectory(preferred) {
            directoryURL = usable
            return
        }
        let fallback = Self.managedDirectoryURL(for: mediaURL, jobID: jobID)
        guard let usable = Self.prepareWritableDirectory(fallback) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        directoryURL = usable
        self.usesManagedFallback = true
    }

    /// 폴더를 만들고 실제로 쓸 수 있는지까지 확인합니다. 폴더가 이미 있어도 읽기 전용일 수 있습니다.
    private static func prepareWritableDirectory(_ url: URL) -> URL? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return fileManager.isWritableFile(atPath: url.path) ? url : nil
    }

    /// 원본 옆에 저장할 수 없을 때 사용하는 앱 관리 결과 폴더입니다.
    public static func managedResultsRootURL() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL.temporaryDirectory
        return support
            .appending(path: "VideoLingo", directoryHint: .isDirectory)
            .appending(path: "Results", directoryHint: .isDirectory)
    }

    public static func managedDirectoryURL(for mediaURL: URL, jobID: UUID) -> URL {
        alternateDirectoryURL(for: mediaURL, jobID: jobID, rootURL: managedResultsRootURL())
    }

    /// 이 영상의 결과가 있을 수 있는 모든 폴더입니다. 원본 옆을 먼저 보고, 없으면 앱 관리 폴더를 찾습니다.
    public static func resultDirectoryCandidates(for mediaURL: URL) -> [URL] {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        let beside = directoryURL(for: mediaURL)
        if fileManager.fileExists(atPath: beside.path) { candidates.append(beside) }
        let root = managedResultsRootURL()
        let prefix = mediaURL.deletingPathExtension().lastPathComponent + "-"
        if let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: entries.filter {
                $0.pathExtension == "videolingo" && $0.lastPathComponent.hasPrefix(prefix)
            })
        }
        return candidates
    }

    /// 실제로 결과가 저장된 폴더입니다. 결과 폴더 열기 같은 UI에서 사용합니다.
    public static func existingResultsDirectoryURL(for mediaURL: URL) -> URL? {
        resultDirectoryCandidates(for: mediaURL).first {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: $0.path) else { return false }
            return files.contains { $0.hasPrefix("stt-") || $0.hasPrefix("translation-") }
        }
    }

    public static func directoryURL(for mediaURL: URL) -> URL {
        mediaURL.deletingPathExtension().appendingPathExtension("videolingo")
    }

    public static func alternateDirectoryURL(for mediaURL: URL, jobID: UUID, rootURL: URL) -> URL {
        let filename = mediaURL.deletingPathExtension().lastPathComponent
        let suffix = String(jobID.uuidString.prefix(8)).lowercased()
        return rootURL.appending(
            path: "\(filename)-\(suffix).videolingo",
            directoryHint: .isDirectory
        )
    }

    public static func discoverResults(
        for mediaURL: URL,
        preferredLanguage: String,
        preferredTranslationModel: String
    ) throws -> DiscoveredMediaSidecar? {
        // 원본 옆과 앱 관리 폴더를 모두 살펴, 가장 최근에 저장된 결과를 사용합니다.
        let files = resultDirectoryCandidates(for: mediaURL).flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
        guard !files.isEmpty else { return nil }
        let transcriptDocuments = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("stt-") }
            .compactMap { try? WireCodec.decode(TranscriptDocument.self, from: Data(contentsOf: $0)) }
        guard let transcriptDocument = transcriptDocuments.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }

        let translationDocuments = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("translation-") }
            .compactMap { try? WireCodec.decode(TranslationDocument.self, from: Data(contentsOf: $0)) }
            .filter { $0.jobID == transcriptDocument.jobID && $0.language == preferredLanguage }
        let translationDocument = translationDocuments.first(where: { $0.modelID == preferredTranslationModel })
            ?? translationDocuments.max(by: { $0.updatedAt < $1.updatedAt })

        return DiscoveredMediaSidecar(
            jobID: transcriptDocument.jobID,
            sttModel: transcriptDocument.sttModel,
            sourceLanguage: transcriptDocument.sourceLanguage,
            transcripts: transcriptDocument.segments.sorted { $0.chunkIndex < $1.chunkIndex },
            translations: translationDocument?.segments ?? [],
            translationModel: translationDocument?.modelID
        )
    }

    public func loadTranscripts() throws -> [TranscriptSegment] {
        try lock.withLock {
            let url = transcriptJSONURL
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let document = try WireCodec.decode(TranscriptDocument.self, from: Data(contentsOf: url))
            guard document.jobID == jobID else { return [] }
            return document.segments.map { segment in
                TranscriptSegment(
                    id: segment.id,
                    jobID: jobID,
                    chunkIndex: segment.chunkIndex,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    text: SpeakerLabelRewriter.removingInferenceMarkers(from: segment.text),
                    language: segment.language,
                    confidence: segment.confidence,
                    cues: (segment.cues ?? []).map {
                        TranscriptCue(
                            startTime: $0.startTime,
                            endTime: $0.endTime,
                            text: SpeakerLabelRewriter.removingInferenceMarkers(from: $0.text)
                        )
                    },
                    qualityStatus: segment.qualityStatus,
                    retryCount: segment.retryCount,
                    qualityNotes: segment.qualityNotes
                )
            }.sorted { $0.chunkIndex < $1.chunkIndex }
        }
    }

    public func loadTranslations(language: String, modelID: String) throws -> [TranslationSegment] {
        try lock.withLock {
            let url = translationJSONURL(language: language, modelID: modelID)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let document = try WireCodec.decode(TranslationDocument.self, from: Data(contentsOf: url))
            guard document.jobID == jobID,
                  document.language == language,
                  document.modelID == modelID else { return [] }
            return document.segments.map { translation in
                TranslationSegment(
                    id: translation.id,
                    transcriptID: translation.transcriptID,
                    jobID: jobID,
                    targetLanguage: translation.targetLanguage,
                    modelID: translation.modelID,
                    text: SpeakerLabelRewriter.removingInferenceMarkers(from: translation.text),
                    qualityStatus: translation.qualityStatus,
                    qualityNotes: translation.qualityNotes
                )
            }
        }
    }

    public func saveTranscripts(_ segments: [TranscriptSegment]) throws {
        try lock.withLock {
            let sorted = segments.sorted { $0.chunkIndex < $1.chunkIndex }
            let document = TranscriptDocument(
                version: 1,
                jobID: jobID,
                sttModel: sttModel,
                sourceLanguage: sourceLanguage,
                updatedAt: .now,
                segments: sorted
            )
            try WireCodec.encode(document).write(to: transcriptJSONURL, options: .atomic)
            try plainText(transcripts: sorted).write(to: transcriptTextURL, atomically: true, encoding: .utf8)
            try SubtitleExporter.srt(transcript: sorted, translations: [:])
                .write(to: transcriptSRTURL, atomically: true, encoding: .utf8)
        }
    }

    public func saveTranslations(
        _ values: [TranslationSegment],
        language: String,
        modelID: String,
        transcripts: [TranscriptSegment]
    ) throws {
        try lock.withLock {
            let transcriptOrder = Dictionary(uniqueKeysWithValues: transcripts.map { ($0.id, $0.chunkIndex) })
            let sorted = values.sorted {
                transcriptOrder[$0.transcriptID, default: .max] < transcriptOrder[$1.transcriptID, default: .max]
            }
            let document = TranslationDocument(
                version: 1,
                jobID: jobID,
                language: language,
                modelID: modelID,
                updatedAt: .now,
                segments: sorted
            )
            try WireCodec.encode(document).write(to: translationJSONURL(language: language, modelID: modelID), options: .atomic)
            let mapped = Dictionary(uniqueKeysWithValues: sorted.map { ($0.transcriptID, $0) })
            try plainText(transcripts: transcripts, translations: mapped)
                .write(to: translationTextURL(language: language, modelID: modelID), atomically: true, encoding: .utf8)
            try SubtitleExporter.srt(transcript: transcripts, translations: mapped)
                .write(to: translationSRTURL(language: language, modelID: modelID), atomically: true, encoding: .utf8)
        }
    }

    public func deleteTranslationResults(language: String, modelID: String) throws {
        try lock.withLock {
            for url in [
                translationJSONURL(language: language, modelID: modelID),
                translationTextURL(language: language, modelID: modelID),
                translationSRTURL(language: language, modelID: modelID)
            ] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public static func deleteAllGeneratedResults(for mediaURL: URL) throws {
        for directoryURL in resultDirectoryCandidates(for: mediaURL) {
            let files = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.lastPathComponent.hasPrefix("stt-") || url.lastPathComponent.hasPrefix("translation-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private var transcriptStem: String {
        "stt-\(slug(sttModel))-\(slug(sourceLanguage ?? "auto"))"
    }

    private var transcriptJSONURL: URL { directoryURL.appending(path: "\(transcriptStem).json") }
    private var transcriptTextURL: URL { directoryURL.appending(path: "\(transcriptStem).txt") }
    private var transcriptSRTURL: URL { directoryURL.appending(path: "\(transcriptStem).srt") }

    private func translationStem(language: String, modelID: String) -> String {
        "translation-\(slug(language))-\(slug(modelID))"
    }

    private func translationJSONURL(language: String, modelID: String) -> URL {
        directoryURL.appending(path: "\(translationStem(language: language, modelID: modelID)).json")
    }

    private func translationTextURL(language: String, modelID: String) -> URL {
        directoryURL.appending(path: "\(translationStem(language: language, modelID: modelID)).txt")
    }

    private func translationSRTURL(language: String, modelID: String) -> URL {
        directoryURL.appending(path: "\(translationStem(language: language, modelID: modelID)).srt")
    }

    private func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.lowercased().unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(scalars).replacingOccurrences(of: "--", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func plainText(
        transcripts: [TranscriptSegment],
        translations: [UUID: TranslationSegment] = [:]
    ) -> String {
        transcripts.map { segment in
            let text = translations[segment.id]?.text ?? segment.text
            return "[\(timestamp(segment.startTime)) - \(timestamp(segment.endTime))]\n\(text)"
        }.joined(separator: "\n\n") + "\n"
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let secs = (milliseconds % 60_000) / 1_000
        let millis = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
