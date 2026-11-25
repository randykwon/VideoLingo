import Foundation
import Testing
@testable import VideoLingoCore

@Test func subtitleExportUsesTranslationAndTimestamps() {
    let jobID = UUID()
    let segment = TranscriptSegment(jobID: jobID, chunkIndex: 0, startTime: 1.25, endTime: 3.5, text: "Hello")
    let translation = TranslationSegment(transcriptID: segment.id, jobID: jobID, targetLanguage: "ko", text: "안녕하세요")
    let result = SubtitleExporter.srt(transcript: [segment], translations: [segment.id: translation])
    #expect(result.contains("00:00:01,250 --> 00:00:03,500"))
    #expect(result.contains("안녕하세요"))
}

@Test func timedTranscriptCuesPersistInDatabase() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JobStore(url: directory.appending(path: "timed-cues.sqlite"))
    let jobID = UUID()
    try store.createJob(id: jobID, mediaURL: directory.appending(path: "timed.mp4"), options: ProcessingOptions())
    let cue = TranscriptCue(startTime: 2.1, endTime: 3.8, text: "[화자 1] 안녕하세요")
    let segment = TranscriptSegment(
        jobID: jobID,
        chunkIndex: 0,
        startTime: cue.startTime,
        endTime: cue.endTime,
        text: cue.text,
        cues: [cue]
    )
    try store.saveTranscript(segment, snapshot: JobSnapshot(id: jobID))

    #expect(try store.transcript(jobID: jobID).first?.cues?.first == cue)
    let srt = SubtitleExporter.srt(transcript: [segment])
    #expect(srt.contains("00:00:02,100 --> 00:00:03,800"))
}

@Test func speakerLabelsAreRewrittenInTranscriptCuesAndTranslations() {
    let jobID = UUID()
    let transcript = TranscriptSegment(
        jobID: jobID,
        chunkIndex: 0,
        startTime: 0,
        endTime: 4,
        text: "[화자 1] 안녕하세요\n[화자 2] 반갑습니다",
        cues: [TranscriptCue(startTime: 0, endTime: 2, text: "[화자 1] 안녕하세요")]
    )
    let translation = TranslationSegment(
        transcriptID: transcript.id,
        jobID: jobID,
        targetLanguage: "en",
        text: "[화자 1] Hello\n[화자 2] Nice to meet you"
    )
    let mapping = ["화자 1": "김민수", "화자 2": "진행자 (추정)"]
    let rewrittenTranscript = SpeakerLabelRewriter.rewrite(transcript, using: mapping)
    let rewrittenTranslation = SpeakerLabelRewriter.rewrite(translation, using: mapping)

    #expect(SpeakerLabelRewriter.labels(in: [transcript]) == ["화자 1", "화자 2"])
    #expect(rewrittenTranscript.text.contains("[김민수]"))
    #expect(rewrittenTranscript.cues?.first?.text == "[김민수] 안녕하세요")
    #expect(rewrittenTranslation.text.contains("[진행자]"))
    #expect(!rewrittenTranslation.text.contains("추정"))
}

@Test func inferenceMarkersAreRemovedFromStoredSpeakerLabels() {
    let text = "[진행자 (추정)] 안녕하세요\n[Host (inferred)] Welcome\n[질문자 추정] 질문입니다"
    let cleaned = SpeakerLabelRewriter.removingInferenceMarkers(from: text)
    #expect(cleaned == "[진행자] 안녕하세요\n[Host] Welcome\n[질문자] 질문입니다")
    #expect(SpeakerLabelRewriter.sanitizedSpeakerName("참여자 [추정]") == "참여자")
}

@Test func serviceStatusRoundTripsAcrossXPCCodec() throws {
    let original = AIServiceStatus(
        processIdentifier: 1234,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        activeJobCount: 2,
        version: "1.0"
    )
    let decoded = try WireCodec.decode(AIServiceStatus.self, from: WireCodec.encode(original))
    #expect(decoded == original)
}

@Test func manualDemosaicRegionsRoundTripAcrossXPCCodec() throws {
    let original = DemosaicOptions(
        model: .classical,
        regionMode: .manual,
        fidelity: 0.82,
        temporalStabilization: true,
        watermarkSynthetic: true,
        manualRegions: [
            DemosaicRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            DemosaicRegion(x: 0.65, y: 0.7, width: 0.2, height: 0.15)
        ]
    )

    let decoded = try WireCodec.decode(DemosaicOptions.self, from: WireCodec.encode(original))
    #expect(decoded == original)
}

@Test func embeddedAPIResponseUsesSTTLMMServerFieldNames() throws {
    let response = DirectSTTResponse(
        language: "ko",
        segments: [DirectSTTSegment(start: 0, end: 1.25, text: "안녕하세요", avgLogprob: -0.2)],
        duration: 1.25,
        processingSeconds: 0.75
    )
    let data = try WireCodec.encode(response)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let segments = try #require(json["segments"] as? [[String: Any]])

    #expect(json["processing_seconds"] as? Double == 0.75)
    #expect(json["processingSeconds"] == nil)
    #expect(segments.first?["avg_logprob"] as? Double == -0.2)
    #expect(segments.first?["avgLogprob"] == nil)

    let decoded = try WireCodec.decode(DirectSTTResponse.self, from: data)
    #expect(decoded.language == "ko")
    #expect(decoded.segments.first?.text == "안녕하세요")
}

@Test func liveSTTAndTranslationRoundTripAcrossXPCCodec() throws {
    let original = JobSnapshot(
        id: UUID(),
        status: .translating,
        liveTranscriptText: "This is being recognized",
        liveTranslationText: "실시간으로 번역 중",
        message: "실시간 생성 중"
    )
    let decoded = try WireCodec.decode(JobSnapshot.self, from: WireCodec.encode(original))
    #expect(decoded.liveTranscriptText == original.liveTranscriptText)
    #expect(decoded.liveTranslationText == original.liveTranslationText)
}

@Test func qualityOptionsAndGlossaryRoundTripAcrossXPCCodec() throws {
    let original = ProcessingOptions(
        sourceLanguage: "en",
        targetLanguages: ["ko", "ja"],
        sttModel: "large-v3-turbo",
        translationModel: "mlx-community/Qwen3-4B-4bit",
        qualityMode: .maximum,
        glossary: [
            GlossaryEntry(source: "Codex", target: "코덱스"),
            GlossaryEntry(source: "agent", target: "에이전트")
        ],
        continuousImprovement: true,
        maximumRefinementPasses: 4
    )
    let decoded = try WireCodec.decode(ProcessingOptions.self, from: WireCodec.encode(original))
    #expect(decoded.sourceLanguage == "en")
    #expect(decoded.qualityMode == ProcessingQualityMode.maximum)
    #expect(decoded.glossary == original.glossary)
    #expect(decoded.continuousImprovement == true)
    #expect(decoded.maximumRefinementPasses == 4)
}

@Test func processingOptionsUseOneMinuteChunksByDefault() {
    #expect(ProcessingOptions.defaultChunkDuration == 60)
    #expect(ProcessingOptions().chunkDuration == 60)
}

@Test func continuousRefinementCheckpointPersistsForRestart() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JobStore(url: directory.appending(path: "refinement.sqlite"))
    let jobID = UUID()
    try store.createJob(id: jobID, mediaURL: directory.appending(path: "movie.mp4"), options: ProcessingOptions())
    let checkpoint = JobSnapshot(
        id: jobID,
        status: .refining,
        progress: 1,
        sttProgress: 1,
        translationProgress: 1,
        message: "백그라운드 품질 개선 중",
        refinementPass: 2,
        refinementProgress: 0.45,
        refinementRevision: 7,
        refinementImprovements: 5
    )
    try store.save(snapshot: checkpoint)

    let reopened = try JobStore(url: directory.appending(path: "refinement.sqlite"))
    let restored = try #require(try reopened.snapshot(jobID: jobID))
    #expect(restored.status == .refining)
    #expect(restored.progress == 1)
    #expect(restored.refinementPass == 2)
    #expect(restored.refinementProgress == 0.45)
    #expect(restored.refinementRevision == 7)
    #expect(restored.refinementImprovements == 5)
}

@Test func qualityMetadataPersistsAndIndividualResultsCanBeRegenerated() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JobStore(url: directory.appending(path: "quality.sqlite"))
    let jobID = UUID()
    try store.createJob(id: jobID, mediaURL: directory.appending(path: "quality.mp4"), options: ProcessingOptions())
    let transcript = TranscriptSegment(
        jobID: jobID,
        chunkIndex: 3,
        startTime: 30,
        endTime: 40,
        text: "A number is 42.",
        qualityStatus: .reviewed,
        retryCount: 1,
        qualityNotes: ["낮은 신뢰도로 재시도"]
    )
    try store.saveTranscript(transcript, snapshot: JobSnapshot(id: jobID))
    let translation = TranslationSegment(
        transcriptID: transcript.id,
        jobID: jobID,
        targetLanguage: "ko",
        modelID: "test-model",
        text: "숫자는 42입니다.",
        qualityStatus: .warning,
        qualityNotes: ["용어집 항목 확인 필요"]
    )
    try store.saveTranslation(translation, snapshot: JobSnapshot(id: jobID))

    let storedTranscript = try #require(store.transcript(jobID: jobID).first)
    let storedTranslation = try #require(store.translations(jobID: jobID, language: "ko", modelID: "test-model")[transcript.id])
    #expect(storedTranscript.qualityStatus == .reviewed)
    #expect(storedTranscript.retryCount == 1)
    #expect(storedTranscript.qualityNotes == ["낮은 신뢰도로 재시도"])
    #expect(storedTranslation.qualityStatus == .warning)
    #expect(storedTranslation.qualityNotes == ["용어집 항목 확인 필요"])

    try store.deleteTranslation(transcriptID: transcript.id, language: "ko", modelID: "test-model")
    #expect(try store.translations(jobID: jobID, language: "ko", modelID: "test-model").isEmpty)
    try store.deleteTranscript(jobID: jobID, chunkIndex: 3)
    #expect(try store.transcript(jobID: jobID).isEmpty)
}

@Test func modelManagementRecordRoundTripsAcrossXPCCodec() throws {
    let record = ManagedModelRecord(
        kind: .stt,
        modelID: "small",
        state: .downloading,
        progress: 0.42,
        sizeInBytes: 123
    )
    let snapshot = ModelManagerSnapshot(models: [record])
    let decoded = try WireCodec.decode(ModelManagerSnapshot.self, from: WireCodec.encode(snapshot))
    #expect(decoded.models.first?.modelID == "small")
    #expect(decoded.models.first?.progress == 0.42)
}

@Test func databaseMaintenanceReportsAndDeletesAllRecords() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JobStore(url: directory.appending(path: "maintenance.sqlite"))
    let jobID = UUID()
    try store.createJob(id: jobID, mediaURL: URL(filePath: "/tmp/settings.mp4"), options: ProcessingOptions())
    let transcript = TranscriptSegment(jobID: jobID, chunkIndex: 0, startTime: 0, endTime: 10, text: "text")
    try store.saveTranscript(transcript, snapshot: JobSnapshot(id: jobID))
    #expect(try store.statistics().jobCount == 1)
    #expect(try store.statistics().transcriptCount == 1)
    try store.deleteAllJobs()
    #expect(try store.statistics().jobCount == 0)
    #expect(try store.statistics().transcriptCount == 0)
}

@Test func translationRecordsTrackTheSelectedModel() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JobStore(url: directory.appending(path: "translation-model.sqlite"))
    let jobID = UUID()
    try store.createJob(id: jobID, mediaURL: URL(filePath: "/tmp/model.mp4"), options: ProcessingOptions())
    let transcript = TranscriptSegment(jobID: jobID, chunkIndex: 0, startTime: 0, endTime: 10, text: "Hello")
    try store.saveTranscript(transcript, snapshot: JobSnapshot(id: jobID))

    let mlxModel = "mlx-community/Qwen3-0.6B-4bit"
    let translation = TranslationSegment(
        transcriptID: transcript.id,
        jobID: jobID,
        targetLanguage: "ko",
        modelID: mlxModel,
        text: "안녕하세요"
    )
    try store.saveTranslation(translation, snapshot: JobSnapshot(id: jobID))

    #expect(try store.translations(jobID: jobID, language: "ko", modelID: mlxModel)[transcript.id]?.text == "안녕하세요")
    #expect(try store.translations(jobID: jobID, language: "ko", modelID: "apple-foundation-models").isEmpty)
    try store.deleteTranslations(jobID: jobID, language: "ko", modelID: mlxModel)
    #expect(try store.translations(jobID: jobID, language: "ko", modelID: mlxModel).isEmpty)
    try store.deleteJob(jobID: jobID)
    #expect(try store.snapshot(jobID: jobID) == nil)
    #expect(try store.transcript(jobID: jobID).isEmpty)
}

@Test func mostRecentJobCanBeFoundByMediaURL() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JobStore(url: directory.appending(path: "recent-job.sqlite"))
    let mediaURL = directory.appending(path: "movie.mp4")
    let olderJobID = UUID()
    let newerJobID = UUID()
    try store.createJob(id: olderJobID, mediaURL: mediaURL, options: ProcessingOptions())
    try store.save(snapshot: JobSnapshot(id: olderJobID, updatedAt: Date(timeIntervalSince1970: 1)))
    try store.createJob(id: newerJobID, mediaURL: mediaURL, options: ProcessingOptions(sttModel: "small"))
    try store.save(snapshot: JobSnapshot(id: newerJobID, updatedAt: Date(timeIntervalSince1970: 2)))

    #expect(try store.mostRecentJobID(for: mediaURL) == newerJobID)
}

@Test func sidecarFilesPersistBesideMediaAndRestoreResults() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let mediaURL = directory.appending(path: "sample.mp4")
    let jobID = UUID()
    let store = try MediaSidecarStore(mediaURL: mediaURL, jobID: jobID, sttModel: "small", sourceLanguage: "en")
    let transcript = TranscriptSegment(jobID: jobID, chunkIndex: 0, startTime: 1, endTime: 4, text: "Hello")
    let translation = TranslationSegment(
        transcriptID: transcript.id,
        jobID: jobID,
        targetLanguage: "ko",
        modelID: "mlx-community/Qwen3-0.6B-4bit",
        text: "안녕하세요"
    )

    try store.saveTranscripts([transcript])
    try store.saveTranslations(
        [translation],
        language: "ko",
        modelID: translation.modelID,
        transcripts: [transcript]
    )

    #expect(try store.loadTranscripts().first?.text == "Hello")
    #expect(try store.loadTranslations(language: "ko", modelID: translation.modelID).first?.text == "안녕하세요")
    let discovered = try MediaSidecarStore.discoverResults(
        for: mediaURL,
        preferredLanguage: "ko",
        preferredTranslationModel: translation.modelID
    )
    #expect(discovered?.jobID == jobID)
    #expect(discovered?.transcripts.first?.text == "Hello")
    #expect(discovered?.translations.first?.text == "안녕하세요")
    let files = try FileManager.default.contentsOfDirectory(at: store.directoryURL, includingPropertiesForKeys: nil)
    #expect(files.contains { $0.pathExtension == "json" })
    #expect(files.contains { $0.pathExtension == "txt" })
    #expect(files.contains { $0.pathExtension == "srt" })
    #expect(store.directoryURL.deletingLastPathComponent() == mediaURL.deletingLastPathComponent())

    try store.deleteTranslationResults(language: "ko", modelID: translation.modelID)
    #expect(try store.loadTranslations(language: "ko", modelID: translation.modelID).isEmpty)
    try MediaSidecarStore.deleteAllGeneratedResults(for: mediaURL)
    #expect(try MediaSidecarStore.discoverResults(
        for: mediaURL,
        preferredLanguage: "ko",
        preferredTranslationModel: translation.modelID
    ) == nil)

    let movedJobID = UUID()
    let reopened = try MediaSidecarStore(mediaURL: mediaURL, jobID: movedJobID, sttModel: "small", sourceLanguage: "en")
    #expect(try reopened.loadTranscripts().isEmpty)
    #expect(try reopened.loadTranslations(language: "ko", modelID: translation.modelID).isEmpty)
}

@Test func whisperSpecialTokensAreRemovedBeforePersistenceAndTranslation() {
    let raw = "<|startoftranscript|><|ja|><|transcribe|><|0.00|>こんにちは<|2.00|> 世界<|endoftext|>"
    #expect(TranscriptTextSanitizer.cleanWhisperText(raw) == "こんにちは 世界")
}

@Test func mediaLibrarySummaryFindsTranscriptAndAllTranslationLanguages() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let mediaURL = directory.appending(path: "library-sample.mp4")
    try Data().write(to: mediaURL)
    let jobID = UUID()
    let store = try MediaSidecarStore(mediaURL: mediaURL, jobID: jobID, sttModel: "small", sourceLanguage: "en")
    let transcript = TranscriptSegment(jobID: jobID, chunkIndex: 0, startTime: 0, endTime: 2, text: "Hello")
    try store.saveTranscripts([transcript])
    for language in ["ko", "ja"] {
        let translation = TranslationSegment(transcriptID: transcript.id, jobID: jobID, targetLanguage: language, modelID: "test-model", text: language)
        try store.saveTranslations([translation], language: language, modelID: "test-model", transcripts: [transcript])
    }

    let summary = MediaSidecarStore.resultSummary(for: mediaURL)
    #expect(summary.hasTranscript)
    #expect(summary.transcriptSegmentCount == 1)
    #expect(summary.translationLanguages == ["ja", "ko"])
    #expect(summary.translationFileCount == 2)
    #expect(summary.newestUpdate != nil)
}

@Test func storePersistsChunkAtomicallyForResume() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JobStore(url: directory.appending(path: "test.sqlite"))
    let jobID = UUID()
    let options = ProcessingOptions(targetLanguages: ["ko"])
    try store.createJob(id: jobID, mediaURL: URL(filePath: "/tmp/sample.mp4"), options: options)
    let segment = TranscriptSegment(jobID: jobID, chunkIndex: 2, startTime: 60, endTime: 90, text: "Test")
    let translation = TranslationSegment(transcriptID: segment.id, jobID: jobID, targetLanguage: "ko", text: "시험")
    let snapshot = JobSnapshot(id: jobID, status: .translating, progress: 0.5, currentChunk: 3, totalChunks: 6, message: "saved")
    try store.saveChunk(transcript: segment, translations: [translation], snapshot: snapshot)
    #expect(try store.completedChunkIndices(jobID: jobID) == [2])
    #expect(try store.transcript(jobID: jobID).first?.text == "Test")
    #expect(try store.translations(jobID: jobID, language: "ko")[segment.id]?.text == "시험")
}

@Test func retryQualityComparisonNeverReplacesUsefulTranscriptWithEmptyCandidate() {
    let jobID = UUID()
    let existing = TranscriptSegment(
        jobID: jobID,
        chunkIndex: 1,
        startTime: 30,
        endTime: 60,
        text: "기존 전사",
        confidence: 0.4,
        qualityStatus: .reviewed
    )
    let emptyCandidate = TranscriptSegment(
        id: existing.id,
        jobID: jobID,
        chunkIndex: 1,
        startTime: 30,
        endTime: 60,
        text: "",
        confidence: nil,
        qualityStatus: .warning
    )
    #expect(!SegmentQualityComparator.prefersCandidate(emptyCandidate, over: existing))
}

@Test func retryQualityComparisonAcceptsMeaningfullyBetterTranscript() {
    let jobID = UUID()
    let existing = TranscriptSegment(
        jobID: jobID,
        chunkIndex: 2,
        startTime: 60,
        endTime: 90,
        text: "기존 전사",
        confidence: 0.41,
        qualityStatus: .reviewed
    )
    let candidate = TranscriptSegment(
        id: existing.id,
        jobID: jobID,
        chunkIndex: 2,
        startTime: 60,
        endTime: 90,
        text: "개선된 전사",
        confidence: 0.62,
        qualityStatus: .good
    )
    #expect(SegmentQualityComparator.prefersCandidate(candidate, over: existing))
}

@Test func transcriptCoverageRejectsLegacyEmptyCheckpointButAcceptsVerifiedSilence() {
    let jobID = UUID()
    let spoken = TranscriptSegment(jobID: jobID, chunkIndex: 0, startTime: 0, endTime: 30, text: "대사")
    let legacyEmpty = TranscriptSegment(jobID: jobID, chunkIndex: 1, startTime: 30, endTime: 60, text: "")
    let verifiedSilence = TranscriptSegment(
        jobID: jobID,
        chunkIndex: 2,
        startTime: 60,
        endTime: 90,
        text: "",
        qualityNotes: [
            TranscriptCoverage.verifiedSilenceNote,
            TranscriptCoverage.promptFreeVerificationNote
        ]
    )
    let legacyPromptedSilence = TranscriptSegment(
        jobID: jobID,
        chunkIndex: 3,
        startTime: 90,
        endTime: 120,
        text: "",
        qualityNotes: [TranscriptCoverage.verifiedSilenceNote]
    )

    #expect(TranscriptCoverage.missingChunkIndices(
        transcripts: [spoken, legacyEmpty, verifiedSilence, legacyPromptedSilence],
        totalChunks: 4
    ) == [1, 3])
    #expect(TranscriptCoverage.completedChunkCount(
        transcripts: [spoken, legacyEmpty, verifiedSilence, legacyPromptedSilence],
        totalChunks: 4
    ) == 2)
}

@Test func emptyVADResultAlwaysRequiresNonVADVerification() {
    #expect(TranscriptCoverage.requiresNonVADVerification(vadText: ""))
    #expect(TranscriptCoverage.requiresNonVADVerification(vadText: " \n\t"))
    #expect(!TranscriptCoverage.requiresNonVADVerification(vadText: "대사 있음"))
}

@Test func storeRestoresProcessingOptionsForServerRestart() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JobStore(url: directory.appending(path: "restart.sqlite"))
    let jobID = UUID()
    let options = ProcessingOptions(
        sourceLanguage: "ja",
        targetLanguages: ["ko", "en"],
        chunkDuration: 30,
        sttModel: "large-v3-v20240930_626MB",
        translationModel: "mlx-community/Qwen3-4B-4bit",
        qualityMode: .maximum,
        continuousImprovement: true,
        maximumRefinementPasses: 4
    )
    try store.createJob(id: jobID, mediaURL: URL(filePath: "/tmp/restart.mp4"), options: options)

    let restored = try #require(try store.processingOptions(jobID: jobID))
    #expect(restored == options)
    #expect(restored.chunkDuration == 30)
}

@Test func storeRetriesConcurrentReadersAndWriters() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "concurrent.sqlite")
    let jobID = UUID()
    let initialStore = try JobStore(url: databaseURL)
    try initialStore.createJob(
        id: jobID,
        mediaURL: URL(filePath: "/tmp/concurrent.mp4"),
        options: ProcessingOptions()
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
        for worker in 0..<8 {
            group.addTask {
                let store = try JobStore(url: databaseURL)
                for iteration in 0..<12 {
                    let snapshot = JobSnapshot(
                        id: jobID,
                        status: .transcribing,
                        progress: Double(iteration) / 12,
                        currentChunk: iteration,
                        totalChunks: 12,
                        message: "worker-\(worker)"
                    )
                    try store.save(snapshot: snapshot)
                    #expect(try store.snapshot(jobID: jobID) != nil)
                }
            }
        }
        try await group.waitForAll()
    }
}

@Test func storePersistsSTTBeforeTranslationAndResumesEachStage() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "resume.sqlite")
    let jobID = UUID()

    do {
        let store = try JobStore(url: databaseURL)
        try store.createJob(
            id: jobID,
            mediaURL: URL(filePath: "/tmp/resume.mp4"),
            options: ProcessingOptions(targetLanguages: ["ko"])
        )
        let transcript = TranscriptSegment(
            jobID: jobID,
            chunkIndex: 0,
            startTime: 0,
            endTime: 15,
            text: "Persist before translation"
        )
        let sttSnapshot = JobSnapshot(
            id: jobID,
            status: .transcribing,
            progress: 0.25,
            currentChunk: 0,
            totalChunks: 2,
            sttProgress: 0.5,
            translationProgress: 0,
            lastTranscriptText: transcript.text,
            message: "STT saved"
        )
        try store.saveTranscript(transcript, snapshot: sttSnapshot)
    }

    let resumedStore = try JobStore(url: databaseURL)
    let storedTranscripts = try resumedStore.transcript(jobID: jobID)
    let storedSnapshot = try resumedStore.snapshot(jobID: jobID)
    let resumedTranscript = try #require(storedTranscripts.first)
    let resumedSnapshot = try #require(storedSnapshot)
    #expect(resumedSnapshot.sttProgress == 0.5)
    #expect(resumedSnapshot.translationProgress == 0)
    #expect(resumedSnapshot.lastTranscriptText == "Persist before translation")
    #expect(try resumedStore.translations(jobID: jobID, language: "ko").isEmpty)

    let translation = TranslationSegment(
        transcriptID: resumedTranscript.id,
        jobID: jobID,
        targetLanguage: "ko",
        text: "번역 전에 저장"
    )
    var translatedSnapshot = resumedSnapshot
    translatedSnapshot.status = .translating
    translatedSnapshot.progress = 0.5
    translatedSnapshot.translationProgress = 0.5
    translatedSnapshot.lastTranslationText = translation.text
    try resumedStore.saveTranslation(translation, snapshot: translatedSnapshot)

    let verifiedStore = try JobStore(url: databaseURL)
    #expect(try verifiedStore.translations(jobID: jobID, language: "ko")[resumedTranscript.id]?.text == "번역 전에 저장")
    #expect(try verifiedStore.snapshot(jobID: jobID)?.translationProgress == 0.5)
    #expect(try verifiedStore.snapshot(jobID: jobID)?.lastTranslationText == "번역 전에 저장")
}

@Test func sidecarFallsBackToManagedFolderWhenMediaFolderIsReadOnly() throws {
    // 원본 영상 폴더에 쓸 수 없을 때도 결과가 저장되고, 나중에 다시 찾아낼 수 있어야 합니다.
    let fileManager = FileManager.default
    let readOnlyDirectory = fileManager.temporaryDirectory.appending(path: "vl-readonly-\(UUID().uuidString)")
    try fileManager.createDirectory(at: readOnlyDirectory, withIntermediateDirectories: true)
    let mediaURL = readOnlyDirectory.appending(path: "sample-\(UUID().uuidString.prefix(8)).mp4")
    try Data().write(to: mediaURL)
    try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyDirectory.path)
    defer {
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDirectory.path)
        try? fileManager.removeItem(at: readOnlyDirectory)
        try? MediaSidecarStore.deleteAllGeneratedResults(for: mediaURL)
    }

    let jobID = UUID()
    let sidecar = try MediaSidecarStore(mediaURL: mediaURL, jobID: jobID, sttModel: "tiny", sourceLanguage: "en")
    #expect(sidecar.usesManagedFallback)
    #expect(!sidecar.directoryURL.path.hasPrefix(readOnlyDirectory.path))

    let segment = TranscriptSegment(jobID: jobID, chunkIndex: 0, startTime: 0, endTime: 1, text: "Hello")
    try sidecar.saveTranscripts([segment])

    // 저장한 결과를 원본 경로만 알고도 다시 찾을 수 있어야 합니다.
    let discovered = try MediaSidecarStore.discoverResults(
        for: mediaURL,
        preferredLanguage: "ko",
        preferredTranslationModel: "apple-foundation-models"
    )
    #expect(discovered?.transcripts.first?.text == "Hello")
    #expect(MediaSidecarStore.existingResultsDirectoryURL(for: mediaURL) != nil)
}

@Test func rerunningAJobClearsPreviousFailure() throws {
    // 재실행할 때 이전 실패 상태가 남아 있으면, 배치가 곧바로 옛 오류를 다시 보고합니다.
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JobStore(url: directory.appending(path: "rerun.sqlite"))
    let jobID = UUID()
    let mediaURL = directory.appending(path: "clip.mp4")
    try store.createJob(id: jobID, mediaURL: mediaURL, options: ProcessingOptions())

    var failed = try #require(try store.snapshot(jobID: jobID))
    failed.status = .failed
    failed.error = "번역이 연속 8회 실패했습니다."
    failed.progress = 0.42
    failed.sttProgress = 1
    try store.save(snapshot: failed)
    #expect(try store.snapshot(jobID: jobID)?.status == .failed)

    // 같은 작업을 다시 시작하면 깨끗한 상태에서 출발해야 합니다.
    try store.createJob(id: jobID, mediaURL: mediaURL, options: ProcessingOptions())
    let restarted = try #require(try store.snapshot(jobID: jobID))
    #expect(restarted.status == .queued)
    #expect(restarted.error == nil)
    #expect(restarted.progress == 0)
    #expect(restarted.sttProgress == 0)
}

@Test func externalServerURLIsNormalizedForCommonLocalServers() throws {
    // 사용자가 어떤 형태로 주소를 넣어도 같은 채팅 엔드포인트를 가리켜야 합니다.
    let inputs = [
        "http://localhost:11434",
        "http://localhost:11434/",
        "http://localhost:11434/v1",
        "http://localhost:11434/v1/chat/completions",
        "localhost:11434"
    ]
    for input in inputs {
        let config = try #require(
            ExternalLLMClient.Configuration(endpoint: input, model: "qwen2.5:7b", apiKey: nil),
            "정규화 실패: \(input)"
        )
        #expect(config.endpoint.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    // 키를 비워 두면 인증 헤더를 붙이지 않도록 nil로 정리합니다.
    let noKey = try #require(ExternalLLMClient.Configuration(endpoint: "localhost:1234", model: "m", apiKey: "   "))
    #expect(noKey.apiKey == nil)

    // 주소나 모델 이름이 비면 설정 자체가 만들어지지 않아야 합니다.
    #expect(ExternalLLMClient.Configuration(endpoint: "", model: "m", apiKey: nil) == nil)
    #expect(ExternalLLMClient.Configuration(endpoint: "localhost:1234", model: "", apiKey: nil) == nil)
}

@Test func playbackSubtitleIndexMatchesLinearLookupAcrossSeeksAndGaps() {
    let job = UUID()
    let segments = [
        TranscriptSegment(jobID: job, chunkIndex: 0, startTime: 10, endTime: 20, text: "overlap"),
        TranscriptSegment(jobID: job, chunkIndex: 1, startTime: 0, endTime: 30, text: "cues", cues: [
            TranscriptCue(startTime: 0, endTime: 2, text: "first"),
            TranscriptCue(startTime: 12, endTime: 14, text: "overlapping"),
            TranscriptCue(startTime: 25, endTime: 30, text: "last")
        ]),
        TranscriptSegment(jobID: job, chunkIndex: 2, startTime: 40, endTime: 45, text: "tail")
    ]
    let index = PlaybackSubtitleIndex(segments)
    let times = [-1.0, 0, 1, 2, 9, 10, 12, 14, 20, 25, 30, 40, 45, .infinity, .nan]
    for time in times.reversed() {
        let expected = segments.firstIndex { segment in
            let cues = segment.cues ?? []
            return cues.isEmpty
                ? time >= segment.startTime && time < segment.endTime
                : cues.contains { time >= $0.startTime && time < $0.endTime }
        }
        #expect(index.segmentIndex(at: time) == expected)
    }
    #expect(PlaybackSubtitleIndex([]).segmentIndex(at: 1) == nil)
}

@Test func playbackSubtitleIndexHandlesLongLibrariesAndInvalidIntervals() {
    let job = UUID()
    var segments = (0..<10_000).map { i in
        TranscriptSegment(jobID: job, chunkIndex: i, startTime: Double(i * 3), endTime: Double(i * 3 + 1), text: "cue")
    }
    segments.append(TranscriptSegment(jobID: job, chunkIndex: 10_000, startTime: .nan, endTime: .infinity, text: "invalid"))
    let index = PlaybackSubtitleIndex(segments)
    for i in stride(from: 9_999, through: 0, by: -7) {
        #expect(index.segmentIndex(at: Double(i * 3)) == i)
        #expect(index.segmentIndex(at: Double(i * 3 + 2)) == nil)
    }
}

@Test func playerFilenameFilterPreservesDistinctFilesAndPreferredCopy() {
    let urls = ["/a/video.mp4", "/b/VIDEO.mp4", "/c/video.mov", "/a/cafe.mp4", "/b/café.mp4", "/c/cafe\u{301}.mp4"].map { URL(filePath: $0) }
    #expect(MediaFilenameDeduplicator.representativeIndices(for: urls) == [0, 2, 3, 4])
    #expect(MediaFilenameDeduplicator.representativeIndices(for: urls, preferredURL: urls[1]) == [1, 2, 3, 4])
    #expect(MediaFilenameDeduplicator.representativeIndices(for: []) == [])
    #expect(MediaFilenameDeduplicator.representativeIndices(for: urls, preferredURL: URL(filePath: "/missing/video.mp4")) == [0, 2, 3, 4])
}

@Test func whisperSanitizerCollapsesRepetitionLoopsAndFiltersHallucinationsSafely() {
    #expect(TranscriptTextSanitizer.cleanWhisperText("네 네 네 네 네 네") == "네")
    #expect(TranscriptTextSanitizer.cleanWhisperText("はい。はい。はい。はい。はい。") == "はい。")
    #expect(TranscriptTextSanitizer.cleanWhisperText("안녕하세요 반갑습니다") == "안녕하세요 반갑습니다")

    // 순수 기호·음악 태그는 신뢰도와 무관하게 필터링
    #expect(TranscriptTextSanitizer.isLikelyHallucination("[음악]", noSpeechProb: 0.1, avgLogprob: -0.1))
    #expect(TranscriptTextSanitizer.isLikelyHallucination("♪ ... ♪", noSpeechProb: 0.1, avgLogprob: -0.1))

    // 알려진 Whisper 환각 문구는 무음 확률이 높거나 로그 확률이 낮을 때만 차단
    #expect(TranscriptTextSanitizer.isLikelyHallucination("시청해주셔서 감사합니다.", noSpeechProb: 0.45, avgLogprob: -0.5))
    #expect(TranscriptTextSanitizer.isLikelyHallucination("Thanks for watching!", noSpeechProb: 0.2, avgLogprob: -0.9))
    // 실제 높은 신뢰도의 끝인사는 보존
    #expect(!TranscriptTextSanitizer.isLikelyHallucination("시청해주셔서 감사합니다.", noSpeechProb: 0.05, avgLogprob: -0.15))
    #expect(!TranscriptTextSanitizer.isLikelyHallucination("오늘 회의를 시작하겠습니다.", noSpeechProb: 0.5, avgLogprob: -0.8))
}

@Test func chunkBoundaryAssignmentEliminatesOverlapDuplicatesWithoutGaps() {
    // 청크 0: [0, 60] (추출 [0, 62]), 청크 1: [60, 120] (추출 [58, 120], 마지막 청크)
    // 경계(59.0~60.6, 중심 59.8) 발화는 청크 0에만, (59.6~61.2, 중심 60.4) 발화는 청크 1에만 귀속되어야 함
    let chunk0Cues = TranscriptTextSanitizer.assignChunkCues(
        [
            TranscriptCue(startTime: 59.0, endTime: 60.6, text: "경계 앞 문장"),
            TranscriptCue(startTime: 59.6, endTime: 61.2, text: "경계 뒤 문장")
        ],
        extractionStart: 0,
        chunkStart: 0,
        chunkEnd: 60,
        isLastChunk: false
    )
    let chunk1Cues = TranscriptTextSanitizer.assignChunkCues(
        [
            TranscriptCue(startTime: 1.0, endTime: 2.6, text: "경계 앞 문장"),
            TranscriptCue(startTime: 1.6, endTime: 3.2, text: "경계 뒤 문장")
        ],
        extractionStart: 58,
        chunkStart: 60,
        chunkEnd: 120,
        isLastChunk: true
    )

    #expect(chunk0Cues.map(\.text) == ["경계 앞 문장"])
    #expect(chunk0Cues.first?.startTime == 59.0)
    #expect(chunk0Cues.first?.endTime == 60.0)
    #expect(chunk1Cues.map(\.text) == ["경계 뒤 문장"])
    #expect(chunk1Cues.first?.startTime == 60.0)
    #expect(chunk1Cues.first?.endTime == 61.2)
}

@Test func languageLockRequiresConfidentSpeechOrConsecutiveAgreement() {
    // 짧은 감탄사나 낮은 신뢰도 1회만으로는 언어를 고정하지 않음
    #expect(TranscriptTextSanitizer.shouldLockDetectedLanguage(
        candidate: "en",
        text: "[화자 1] OK",
        confidence: 0.7,
        recentDetections: []
    ) == nil)
    #expect(TranscriptTextSanitizer.shouldLockDetectedLanguage(
        candidate: "ja",
        text: "[화자 1] 今日はとても良い天気ですね。",
        confidence: 0.4,
        recentDetections: []
    ) == nil)

    // 충분한 길이 + 높은 신뢰도면 즉시 고정
    #expect(TranscriptTextSanitizer.shouldLockDetectedLanguage(
        candidate: "JA",
        text: "[화자 1] 今日はとても良い天気ですね。",
        confidence: 0.65,
        recentDetections: []
    ) == "ja")

    // 보통 신뢰도라도 2개 청크가 같은 언어로 일치하면 고정
    #expect(TranscriptTextSanitizer.shouldLockDetectedLanguage(
        candidate: "ko",
        text: "[화자 1] 안녕하세요 반갑습니다",
        confidence: 0.42,
        recentDetections: ["ko"]
    ) == "ko")
}

@Test func translationSanitizerStripsThinkingFencesHeadersAndOuterQuotes() {
    #expect(TranslationTextSanitizer.cleanLLMOutput("<think>Let me translate this.</think>\n안녕하세요") == "안녕하세요")
    #expect(TranslationTextSanitizer.cleanLLMOutput("<think>아직 사고 중...") == "")
    #expect(TranslationTextSanitizer.cleanLLMOutput("```text\nCURRENT SUBTITLE:\n안녕하세요\n```") == "안녕하세요")
    #expect(TranslationTextSanitizer.cleanLLMOutput("\"안녕하세요\"", source: "Hello") == "안녕하세요")
    #expect(TranslationTextSanitizer.cleanLLMOutput("\"안녕하세요\"", source: "\"Hello\"") == "\"안녕하세요\"")
}

@Test func translationContextTrimsLongChunksFiltersGlossaryAndScalesTokenBudget() {
    let longPrev = (1...30).map { "이전 문장 \($0) 입니다." }.joined(separator: "\n")
    let trimmedPrev = TranslationContextBuilder.trimPreviousContext([longPrev], maxCharacters: 120)
    #expect(trimmedPrev.joined().count <= 120)
    #expect(trimmedPrev.last?.contains("30") == true)

    let longNext = (1...30).map { "다음 문장 \($0) 입니다." }.joined(separator: "\n")
    let trimmedNext = TranslationContextBuilder.trimNextContext([longNext], maxCharacters: 100)
    #expect(trimmedNext.joined().count <= 100)
    #expect(trimmedNext.first?.contains("1") == true)

    let largeGlossary = (1...20).map { GlossaryEntry(source: "Term\($0)", target: "용어\($0)") }
    let relevant = TranslationContextBuilder.relevantGlossary(largeGlossary, for: "Here we use Term7 and Term19.")
    #expect(relevant.map(\.source) == ["Term7", "Term19"])

    let denseChunk = String(repeating: "a", count: 900)
    #expect(TranslationContextBuilder.maxResponseTokens(for: denseChunk, backend: .mlx) > 1000)
    #expect(TranslationContextBuilder.maxResponseTokens(for: denseChunk, backend: .appleFoundation) > 1000)
    #expect(TranslationContextBuilder.maxResponseTokens(for: denseChunk, backend: .externalServer) >= 2700)
}

@Test func translationValidatorRepairsSpeakerLabelsChecksIssuesAndGuardsAgainstRegression() {
    let source = "[화자 1] Hello world, it costs 1,000 dollars.\n[화자 2] Nice to meet you."
    let mangledLabels = "[Speaker 1] 안녕하세요, 1000달러입니다.\n만나서 반갑습니다."
    let repaired = TranslationQualityValidator.repairSpeakerLabelsIfAligned(source: source, translation: mangledLabels)
    #expect(repaired == "[화자 1] 안녕하세요, 1000달러입니다.\n[화자 2] 만나서 반갑습니다.")

    // 천단위 쉼표 정규화(1,000 == 1000) 및 복원된 화자 라벨은 결함 없음
    let cleanIssues = TranslationQualityValidator.issues(
        source: source,
        translation: repaired,
        sourceLanguage: "en",
        targetLanguage: "ko",
        glossary: []
    )
    #expect(cleanIssues.isEmpty)

    // 원문 그대로 반환한 번역 누락 탐지
    let echoedIssues = TranslationQualityValidator.issues(
        source: "This sentence was never translated at all.",
        translation: "This sentence was never translated at all.",
        sourceLanguage: "en",
        targetLanguage: "ko",
        glossary: []
    )
    #expect(echoedIssues.contains("원문이 번역되지 않고 그대로 남음"))

    // 짧은 CJK -> 영어 번역에서 길이 오탐이 나지 않아야 함
    let shortCjkIssues = TranslationQualityValidator.issues(
        source: "はい",
        translation: "Yes, of course.",
        sourceLanguage: "ja",
        targetLanguage: "en",
        glossary: []
    )
    #expect(shortCjkIssues.isEmpty)

    // 검수 결과가 오히려 결함을 늘리면 채택하지 않음
    #expect(!TranslationQualityValidator.prefersRepaired(
        draft: "초안",
        repaired: "망가진 검수본",
        draftIssues: ["필수 용어 누락: Foo"],
        repairedIssues: ["화자 라벨 누락", "번역 길이 이상"],
        qualityMode: .enhanced
    ))
    #expect(TranslationQualityValidator.prefersRepaired(
        draft: "초안",
        repaired: "개선된 검수본",
        draftIssues: ["필수 용어 누락: Foo"],
        repairedIssues: [],
        qualityMode: .enhanced
    ))

    // 동일 언어 판별
    #expect(TranslationQualityValidator.isSameLanguage("ko-KR", "ko"))
    #expect(TranslationQualityValidator.isSameLanguage("en_US", "en"))
    #expect(!TranslationQualityValidator.isSameLanguage("zh-Hans", "zh-Hant"))
    #expect(!TranslationQualityValidator.isSameLanguage("en", "ko"))
}

@Test func managedRuntimeCatalogHas19VerifiedModelsAndIsolatedPorts() {
    let sttModels = ManagedRuntimeModelCatalog.all.filter { $0.role == .stt }
    let translationModels = ManagedRuntimeModelCatalog.all.filter { $0.role == .translation }
    #expect(sttModels.count == 9)
    #expect(translationModels.count == 10)
    #expect(Set(ManagedRuntimeModelCatalog.all.map(\.id)).count == 19)
    for model in ManagedRuntimeModelCatalog.all {
        #expect(model.sha256.count == 64)
        #expect(model.bytes > 0)
        #expect(model.url.scheme == "https")
    }
    // SpikDoum(18880/18881)과 포트 충돌이 없어야 함
    #expect(ManagedRuntimeRole.stt.port == 18882)
    #expect(ManagedRuntimeRole.translation.port == 18883)
}

@Test func managedRuntimeModelStoreVerifiesSizeAndSHA256() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "vl-model-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = ManagedRuntimeModelStore(root: directory)
    let payload = Data("mock-ggml-model-bytes".utf8)
    // SHA-256 of "mock-ggml-model-bytes"
    let expectedHash = "9c3f18c7d7c2b0e4c8557f1f8953359f3e7b6a15c9e1ef3b4a428ef6e0c7f2a1"
    let tempFile = directory.appending(path: "download.tmp")
    try payload.write(to: tempFile)

    let badHashModel = ManagedRuntimeModel(
        id: "test-bad-hash",
        name: "Test",
        role: .stt,
        repository: "org/repo",
        revision: "rev",
        filename: "test.bin",
        bytes: Int64(payload.count),
        sha256: expectedHash,
        note: "test"
    )
    #expect(throws: Error.self) {
        try store.finalize(tempFile, model: badHashModel)
    }
    #expect(!store.installed(badHashModel))

    let badSizeModel = ManagedRuntimeModel(
        id: "test-bad-size",
        name: "Test",
        role: .stt,
        repository: "org/repo",
        revision: "rev",
        filename: "test.bin",
        bytes: Int64(payload.count + 10),
        sha256: expectedHash,
        note: "test"
    )
    #expect(throws: Error.self) {
        try store.finalize(tempFile, model: badSizeModel)
    }
}

@Test func managedWhisperClientBuildsWavAndParsesVerboseJSONWithHallucinationFilter() throws {
    let wav = ManagedWhisperClient.wavData(pcm16Mono: Data(repeating: 0, count: 320))
    #expect(wav.prefix(4) == Data("RIFF".utf8))
    #expect(wav.count == 320 + 44)

    let client = ManagedWhisperClient(apiKey: "secret-token")
    let request = client.makeRequest(audioData: wav, language: "ja")
    #expect(request.url?.absoluteString == "http://127.0.0.1:18882/inference")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")

    let sampleJSON = Data("""
    {
      "language": "ja",
      "text": "こんにちは [音楽]",
      "segments": [
        {"start": 0.0, "end": 1.8, "text": "こんにちは", "avg_logprob": -0.2, "no_speech_prob": 0.05},
        {"start": 1.8, "end": 3.0, "text": "[音楽]", "avg_logprob": -0.9, "no_speech_prob": 0.8}
      ]
    }
    """.utf8)
    let parsed = try ManagedWhisperClient.parse(sampleJSON)
    #expect(parsed.language == "ja")
    #expect(parsed.cues.count == 1)
    #expect(parsed.cues.first?.text == "こんにちは")
}

@Test func deepgramClientBuildsNova3RequestAndParsesDiarizedUtterances() throws {
    let client = DeepgramPreRecordedClient(apiKey: "dg-test-key")
    let autoRequest = try client.makeRequest(audioData: Data([1, 2, 3]), language: nil)
    #expect(autoRequest.value(forHTTPHeaderField: "Authorization") == "Token dg-test-key")
    #expect(autoRequest.url?.absoluteString.contains("model=nova-3") == true)
    #expect(autoRequest.url?.absoluteString.contains("diarize=true") == true)
    #expect(autoRequest.url?.absoluteString.contains("detect_language=true") == true)

    let fixedRequest = try client.makeRequest(audioData: Data([1, 2, 3]), language: "ko")
    #expect(fixedRequest.url?.absoluteString.contains("language=ko") == true)

    let payload = Data("""
    {
      "results": {
        "channels": [{"detected_language": "en", "alternatives": [{"transcript": "Hello Hi", "confidence": 0.96}]}],
        "utterances": [
          {"start": 0.2, "end": 1.4, "confidence": 0.95, "transcript": "Hello there.", "speaker": 0},
          {"start": 1.6, "end": 2.8, "confidence": 0.97, "transcript": "Hi!", "speaker": 1}
        ]
      }
    }
    """.utf8)
    let parsed = try DeepgramPreRecordedClient.parse(payload)
    #expect(parsed.language == "en")
    #expect(parsed.cues.count == 2)
    #expect(parsed.cues[0].text == "[화자 1] Hello there.")
    #expect(parsed.cues[1].text == "[화자 2] Hi!")
}

@Test func customLocalTranslatorSubstitutesPlaceholdersOnceAndParsesNestedPaths() throws {
    let settings = LocalTranslationAPISettings(
        endpoint: "http://127.0.0.1:8848/v1/translate",
        timeout: 25,
        requestJSON: #"{"text":"{{text}}","source":"{{source}}","target":"{{target}}"}"#,
        responsePath: ""
    )
    let client = CustomLocalTranslatorClient(settings: settings, apiKey: "local-secret")
    let request = try client.makeRequest(text: "Literal {{target}} inside text", source: "en", target: "ko")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-secret")
    let requestBody = try #require(request.httpBody)
    let sentBody = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
    // 원문 내부의 {{target}}은 재치환되지 않고 그대로 보존되어야 함
    #expect(sentBody["text"] as? String == "Literal {{target}} inside text")
    #expect(sentBody["source"] as? String == "en")
    #expect(sentBody["target"] as? String == "ko")

    #expect(try CustomLocalTranslatorClient.parse(Data(#"{"data":{"translation":"안녕하세요"}}"#.utf8)) == "안녕하세요")
    #expect(try CustomLocalTranslatorClient.parse(Data(#"{"translations":[{"text":"반갑습니다"}]}"#.utf8)) == "반갑습니다")
    #expect(try CustomLocalTranslatorClient.parse(Data(#"{"custom":{"out":"결과"}}"#.utf8), path: "custom.out") == "결과")
    #expect(throws: Error.self) {
        _ = try CustomLocalTranslatorClient.parse(Data(#"{"choices":[{"finish_reason":"length","message":{"content":"잘림"}}]}"#.utf8))
    }
}

@Test func azureTranslatorBatchParserAndLanguageCatalogWorkCorrectly() throws {
    let azureJSON = Data("""
    [
      {"translations": [{"text": "안녕하세요", "to": "ko"}]},
      {"translations": [{"text": "반갑습니다", "to": "ko"}]}
    ]
    """.utf8)
    #expect(try AzureTranslatorClient.parseBatch(azureJSON) == ["안녕하세요", "반갑습니다"])

    #expect(VideoLingoLanguageCatalog.azureCode(for: "zh") == "zh-Hans")
    #expect(VideoLingoLanguageCatalog.azureCode(for: "zh-Hant") == "zh-Hant")
    #expect(VideoLingoLanguageCatalog.whisperParameter(for: "zh-TW") == "zh")
    #expect(VideoLingoLanguageCatalog.detectLanguage(for: "[화자 1] 今日はとても良い天気ですね")?.code == "ja")
    #expect(VideoLingoLanguageCatalog.detectLanguage(for: "[화자 1] 오늘 회의 내용을 정리하겠습니다.")?.code == "ko")
}

@Test func processingOptionsInferLegacyEnginesAndRoundTripMultiEngineConfig() throws {
    let legacyApple = ProcessingOptions(translationModel: "apple-foundation-models")
    #expect(legacyApple.effectiveSTTEngine == .whisperKit)
    #expect(legacyApple.effectiveTranslationEngine == .appleFoundation)

    let multi = ProcessingOptions(
        sourceLanguage: "ja",
        targetLanguages: ["ko", "zh-Hant"],
        sttModel: "managed-whisper:whisper-large-v3-turbo-q5",
        translationModel: ProcessingOptions.appleTranslationModelID,
        sttEngine: .managedWhisper,
        translationEngine: .appleTranslation,
        managedSTTURL: "http://127.0.0.1:18882",
        azureRegion: "koreacentral",
        localTranslationAPI: LocalTranslationAPISettings(endpoint: "http://localhost:8848/v1/translate")
    )
    let decoded = try WireCodec.decode(ProcessingOptions.self, from: WireCodec.encode(multi))
    #expect(decoded.effectiveSTTEngine == .managedWhisper)
    #expect(decoded.effectiveTranslationEngine == .appleTranslation)
    #expect(decoded.managedSTTURL == "http://127.0.0.1:18882")
    #expect(decoded.azureRegion == "koreacentral")
    #expect(decoded.localTranslationAPI?.endpoint == "http://localhost:8848/v1/translate")
}

@Test func builtinModelCatalogAndServerModelDiscoveryWork() throws {
    #expect(ModelCatalog.whisperKitModels.count == 12)
    #expect(ModelCatalog.mlxTranslationModels.count == 13)
    #expect(ModelCatalog.deepgramModels.count == 5)
    #expect(Set(ModelCatalog.whisperKitModels.map(\.id)).count == 12)
    #expect(Set(ModelCatalog.mlxTranslationModels.map(\.id)).count == 13)

    let dgMeeting = try DeepgramPreRecordedClient(apiKey: "dg-key", model: "nova-2-meeting")
        .makeRequest(audioData: Data([1]), language: "ko")
    #expect(dgMeeting.url?.absoluteString.contains("model=nova-2-meeting") == true)

    #expect(ExternalLLMClient.modelsEndpointURL(from: "http://localhost:11434")?.absoluteString == "http://localhost:11434/v1/models")
    #expect(ExternalLLMClient.modelsEndpointURL(from: "http://localhost:11434/v1/chat/completions")?.absoluteString == "http://localhost:11434/v1/models")
    #expect(ExternalLLMClient.modelsEndpointURL(from: "https://api.openai.com/v1")?.absoluteString == "https://api.openai.com/v1/models")

    let openAIList = Data(#"{"data":[{"id":"qwen3:8b"},{"id":"gemma3:12b"}]}"#.utf8)
    #expect(try ExternalLLMClient.parseModelList(openAIList) == ["gemma3:12b", "qwen3:8b"])

    let ollamaList = Data(#"{"models":[{"name":"qwen2.5:7b"},{"name":"llama3.2:3b"}]}"#.utf8)
    #expect(try ExternalLLMClient.parseModelList(ollamaList) == ["llama3.2:3b", "qwen2.5:7b"])
}

@Test func videoRestorationThreeTracksAndComfyUIWorkflowBuilderWork() throws {
    // 1. 3가지 트랙 분류 및 카탈로그 확인
    #expect(DemosaicModel.lamaCoreML.track == .coreMLNative)
    #expect(DemosaicModel.realESRGAN.track == .coreMLNative)
    #expect(DemosaicModel.gfpganCoreML.track == .coreMLNative)
    #expect(DemosaicModel.flashVSRMLX.track == .mlxFlashVSR)
    #expect(DemosaicModel.wanVACE.track == .comfyOrUVMPS)
    #expect(DemosaicModel.seedVR2.track == .comfyOrUVMPS)

    let downloadablePresets = VideoRestorationCatalog.coreMLPresets.filter { $0.downloadURL != nil }
    #expect(downloadablePresets.count == 3)
    #expect(VideoRestorationCatalog.coreMLPreset(for: .lamaCoreML)?.id == "lama")

    // 2. 구버전 DemosaicOptions JSON 하위 호환 디코딩 + 신버전 라운드트립
    let legacyJSON = Data(#"{"model":"realESRGAN","regionMode":"face","fidelity":0.7,"temporalStabilization":true,"watermarkSynthetic":true,"manualRegions":[]}"#.utf8)
    let legacyDecoded = try WireCodec.decode(DemosaicOptions.self, from: legacyJSON)
    #expect(legacyDecoded.model == .realESRGAN)
    #expect(legacyDecoded.externalBackend == .comfyUI)
    #expect(legacyDecoded.flashVSRScale == 2)
    #expect(legacyDecoded.clipDurationSeconds == nil)

    let modern = DemosaicOptions(
        model: .wanVACE,
        regionMode: .manual,
        manualRegions: [DemosaicRegion(x: 0.2, y: 0.2, width: 0.3, height: 0.3)],
        clipStartSeconds: 12.5,
        clipDurationSeconds: 5.0,
        externalBackend: .localWorker,
        comfyUIBaseURL: "http://127.0.0.1:8188",
        flashVSRScale: 4,
        prompt: "clean background"
    )
    let modernDecoded = try WireCodec.decode(DemosaicOptions.self, from: WireCodec.encode(modern))
    #expect(modernDecoded == modern)

    // 3. ComfyUI 기본 워크플로 및 커스텀 템플릿 치환
    let params = ComfyUIWorkflowBuilder.TemplateParameters(
        inputVideoFilename: "clip.mp4",
        maskVideoFilename: "mask.mp4",
        promptText: "sharp restoration",
        outputPrefix: "test_out",
        frameRate: 30,
        width: 1280,
        height: 720
    )
    let seedData = try ComfyUIWorkflowBuilder.defaultSeedVR2Workflow(parameters: params)
    let seedObj = try #require(JSONSerialization.jsonObject(with: seedData) as? [String: Any])
    let seedPrompt = try #require(seedObj["prompt"] as? [String: Any])
    #expect(seedPrompt["4"] != nil)

    let vaceData = try ComfyUIWorkflowBuilder.defaultWanVACEWorkflow(parameters: params)
    let vaceObj = try #require(JSONSerialization.jsonObject(with: vaceData) as? [String: Any])
    let vacePrompt = try #require(vaceObj["prompt"] as? [String: Any])
    #expect(vacePrompt["7"] != nil)
    #expect(vacePrompt["11"] != nil)

    let custom = try ComfyUIWorkflowBuilder.renderCustomWorkflow(
        jsonString: #"{"1":{"class_type":"VHS_LoadVideo","inputs":{"video":"{{INPUT_VIDEO}}","mask":"{{MASK_VIDEO}}"}}}"#,
        model: .wanVACE,
        parameters: params
    )
    let customStr = try #require(String(data: custom, encoding: .utf8))
    #expect(customStr.contains("\"prompt\""))
    #expect(customStr.contains("clip.mp4"))
    #expect(customStr.contains("mask.mp4"))
}

@Test func sentenceAlignmentGrouperMergesFragmentsSplitsMultiSentenceAndTracksPlayback() throws {
    let jobID = UUID()
    let seg1ID = UUID()
    let seg1 = TranscriptSegment(
        id: seg1ID,
        jobID: jobID,
        chunkIndex: 0,
        startTime: 0,
        endTime: 18,
        text: "[화자 1] Hello everyone,\n[화자 1] welcome to the demo.\n[화자 2] Thanks for having me! How are you?",
        cues: [
            TranscriptCue(startTime: 0.0, endTime: 2.0, text: "[화자 1] Hello everyone,"),
            TranscriptCue(startTime: 2.2, endTime: 4.5, text: "[화자 1] welcome to the demo."),
            TranscriptCue(startTime: 5.0, endTime: 11.0, text: "[화자 2] Thanks for having me! How are you?")
        ]
    )
    let tr1 = TranslationSegment(
        transcriptID: seg1ID,
        jobID: jobID,
        targetLanguage: "ko",
        modelID: "mlx-community/Qwen3-8B-4bit",
        text: "[화자 1] 여러분 안녕하세요,\n[화자 1] 데모에 오신 것을 환영합니다.\n[화자 2] 초대해 주셔서 감사합니다! 잘 지내시나요?"
    )

    let items = SentenceAlignmentGrouper.group(transcript: [seg1], translations: [seg1ID: tr1])
    // 앞의 2개 조각은 1문장으로 병합되고, 마지막 2문장 큐는 2문장으로 분리되어 총 3문장이 됩니다.
    #expect(items.count == 3)

    #expect(items[0].startTime == 0.0)
    #expect(items[0].endTime == 4.5)
    #expect(items[0].originalText == "[화자 1] Hello everyone, welcome to the demo.")
    #expect(items[0].translatedText == "[화자 1] 여러분 안녕하세요, 데모에 오신 것을 환영합니다.")

    #expect(items[1].speaker == "[화자 2]")
    #expect(items[1].originalText.contains("Thanks for having me!"))
    #expect(items[1].translatedText?.contains("감사합니다!") == true)

    #expect(items[2].speaker == "[화자 2]")
    #expect(items[2].originalText.contains("How are you?"))
    #expect(items[2].translatedText?.contains("잘 지내시나요?") == true)

    // 재생 시각 이진 탐색 검증
    #expect(SentenceAlignmentGrouper.activeIndex(in: items, at: 3.0) == 0)
    #expect(SentenceAlignmentGrouper.activeIndex(in: items, at: 5.5) == 1)
    #expect(SentenceAlignmentGrouper.activeIndex(in: items, at: 10.5) == 2)
    #expect(SentenceAlignmentGrouper.activeIndex(in: items, at: 15.0) == nil)
}

@Test func multiViewLayoutEngineComputesValidBoundsFor1To8TilesAndClampsDragResize() {
    for count in 1...8 {
        for preset in MultiViewLayoutPreset.allCases {
            let rects = MultiViewLayoutEngine.rects(for: count, preset: preset)
            #expect(rects.count == count)
            for rect in rects {
                #expect(rect.x >= -0.0001 && rect.y >= -0.0001)
                #expect(rect.width > 0.05 && rect.height > 0.05)
                #expect(rect.x + rect.width <= 1.0001)
                #expect(rect.y + rect.height <= 1.0001)
            }
        }
    }

    // 8개 상한 초과 시 8개로 클램프
    #expect(MultiViewLayoutEngine.rects(for: 12, preset: .autoGrid).count == 8)

    // 메인 강조 모드에서 1번 타일이 보조 타일보다 넓어야 함
    let spotlight6 = MultiViewLayoutEngine.rects(for: 6, preset: .spotlight)
    #expect(spotlight6[0].width > spotlight6[1].width)
    #expect(spotlight6[0].height > spotlight6[1].height)

    // 자유 이동·리사이즈 경계 클램핑 검증
    let base = MultiViewNormalizedRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
    let movedRight = base.moved(dx: 0.9, dy: -0.5)
    #expect(abs(movedRight.x - 0.6) < 0.0001)
    #expect(abs(movedRight.y - 0.0) < 0.0001)

    let shrunk = base.resized(dw: -0.9, dh: -0.9)
    #expect(shrunk.width >= 0.16)
    #expect(shrunk.height >= 0.16)

    let expanded = base.resized(dw: 2.0, dh: 2.0)
    #expect(expanded.x + expanded.width <= 1.0001)
    #expect(expanded.y + expanded.height <= 1.0001)
}

@Test func subtitleParserParsesSRTAndWebVTTCleanly() {
    let srt = """
    1
    00:00:01,500 --> 00:00:04,250
    <i>안녕하세요</i>
    두 번째 줄입니다.

    2
    00:00:05,000 --> 00:00:08,000
    반갑습니다.
    """
    let srtCues = SubtitleParser.parse(srt)
    #expect(srtCues.count == 2)
    #expect(abs(srtCues[0].startTime - 1.5) < 0.001)
    #expect(abs(srtCues[0].endTime - 4.25) < 0.001)
    #expect(srtCues[0].text == "안녕하세요\n두 번째 줄입니다.")
    #expect(srtCues[1].text == "반갑습니다.")

    let vtt = """
    WEBVTT

    00:10.500 --> 00:14.000 align:start
    Hello world!
    """
    let vttCues = SubtitleParser.parse(vtt)
    #expect(vttCues.count == 1)
    #expect(abs(vttCues[0].startTime - 10.5) < 0.001)
    #expect(vttCues[0].text == "Hello world!")
}

@Test func videoCodecCompatibilityAdvisorDetectsBrokenBFramesInterlacingAndBuildsVODPlaylist() {
    let healthy = VideoCodecCompatibilityAdvisor.assess(VideoStreamProbeInfo(
        fileExtension: "mp4",
        codecName: "h264",
        pixelFormat: "yuv420p",
        fieldOrder: "progressive",
        frameRate: 30000.0 / 1001.0,
        duration: 120,
        sampledFrames: 25,
        backwardsPTSCount: 0
    ))
    #expect(!healthy.needsCompatibilityProxy)

    let jittery = VideoCodecCompatibilityAdvisor.assess(VideoStreamProbeInfo(
        fileExtension: "mp4",
        codecName: "h264",
        pixelFormat: "yuv420p",
        fieldOrder: "progressive",
        frameRate: 30000.0 / 1001.0,
        duration: 3600,
        sampledFrames: 25,
        backwardsPTSCount: 14
    ))
    #expect(jittery.needsCompatibilityProxy)
    #expect(jittery.issues.contains(.brokenFrameOrder))
    #expect(jittery.badgeTitle == "떨림 보정")
    #expect(VideoCodecCompatibilityAdvisor.videoFilterChain(for: jittery).contains("setpts=N/"))

    let interlacedMKV = VideoCodecCompatibilityAdvisor.assess(VideoStreamProbeInfo(
        fileExtension: "mkv",
        codecName: "vp9",
        pixelFormat: "yuv420p",
        fieldOrder: "tt",
        duration: 10
    ))
    #expect(interlacedMKV.issues.contains(.unsupportedContainer))
    #expect(interlacedMKV.issues.contains(.unsupportedCodec))
    #expect(interlacedMKV.issues.contains(.interlaced))
    #expect(VideoCodecCompatibilityAdvisor.videoFilterChain(for: interlacedMKV).contains("yadif="))

    let playlist = VideoCodecCompatibilityAdvisor.buildVODPlaylist(duration: 10.0, segmentDuration: 4.0)
    #expect(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
    #expect(playlist.contains("seg_0.ts"))
    #expect(playlist.contains("seg_2.ts"))
    #expect(playlist.contains("#EXT-X-ENDLIST"))

    let seg2 = VideoCodecCompatibilityAdvisor.segmentBounds(index: 2, duration: 10.0, segmentDuration: 4.0)
    #expect(seg2?.start == 8.0)
    #expect(seg2?.length == 2.0)
    #expect(VideoCodecCompatibilityAdvisor.segmentBounds(index: 3, duration: 10.0, segmentDuration: 4.0) == nil)
}
