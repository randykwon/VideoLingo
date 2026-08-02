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
    private let jobID: UUID
    private let sttModel: String
    private let sourceLanguage: String?
    private let lock = NSLock()

    public init(mediaURL: URL, jobID: UUID, sttModel: String, sourceLanguage: String?) throws {
        directoryURL = Self.directoryURL(for: mediaURL)
        self.jobID = jobID
        self.sttModel = sttModel
        self.sourceLanguage = sourceLanguage
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public static func directoryURL(for mediaURL: URL) -> URL {
        mediaURL.deletingPathExtension().appendingPathExtension("videolingo")
    }

    public static func discoverResults(
        for mediaURL: URL,
        preferredLanguage: String,
        preferredTranslationModel: String
    ) throws -> DiscoveredMediaSidecar? {
        let directoryURL = directoryURL(for: mediaURL)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
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
        let directoryURL = directoryURL(for: mediaURL)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        for url in files where url.lastPathComponent.hasPrefix("stt-") || url.lastPathComponent.hasPrefix("translation-") {
            try FileManager.default.removeItem(at: url)
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
