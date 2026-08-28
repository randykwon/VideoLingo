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
