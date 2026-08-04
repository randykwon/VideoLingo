import AVFoundation
import Foundation
import VideoLingoCore

final class MediaPipeline: @unchecked Sendable {
    private let stt = WhisperSTTEngine()
    private let translator = FoundationTranslationEngine()
    private let tts = LocalTTSEngine()
    private let onSnapshot: @Sendable (JobSnapshot) -> Void
    private let onLiveTranscript: @Sendable (UUID, Int, Int, String) -> Void
    private let onLiveTranslation: @Sendable (UUID, Int, Int, String, String) -> Void

    init(
        onSnapshot: @escaping @Sendable (JobSnapshot) -> Void,
        onLiveTranscript: @escaping @Sendable (UUID, Int, Int, String) -> Void,
        onLiveTranslation: @escaping @Sendable (UUID, Int, Int, String, String) -> Void
    ) {
        self.onSnapshot = onSnapshot
        self.onLiveTranscript = onLiveTranscript
        self.onLiveTranslation = onLiveTranslation
    }

    func run(_ request: StartJobRequest) async {
        var snapshot = JobSnapshot(id: request.jobID)
        var accessedURL: URL?
        do {
            let mediaURL = try resolveMediaURL(request, accessedURL: &accessedURL)
            defer { accessedURL?.stopAccessingSecurityScopedResource() }

            try FileManager.default.createDirectory(at: request.workspaceURL, withIntermediateDirectories: true)
            let chunksFolder = request.workspaceURL.appending(path: "AudioChunks", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: chunksFolder, withIntermediateDirectories: true)
            let speechFolder = request.workspaceURL.appending(path: "TranslatedSpeech", directoryHint: .isDirectory)
            if request.options.synthesizeSpeech {
                try FileManager.default.createDirectory(at: speechFolder, withIntermediateDirectories: true)
            }
            let modelsURL = request.databaseURL.deletingLastPathComponent().appending(path: "Models", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)

            let store = try JobStore(url: request.databaseURL)
            try store.createJob(id: request.jobID, mediaURL: mediaURL, options: request.options)
            snapshot = try store.snapshot(jobID: request.jobID) ?? snapshot
            snapshot.error = nil
            let sidecar = try MediaSidecarStore(
                mediaURL: mediaURL,
                jobID: request.jobID,
                sttModel: request.options.sttModel,
                sourceLanguage: request.options.sourceLanguage
            )
            var existingByChunk = Dictionary(uniqueKeysWithValues: try store.transcript(jobID: request.jobID).map { ($0.chunkIndex, $0) })
            for transcript in try sidecar.loadTranscripts() where existingByChunk[transcript.chunkIndex] == nil {
                try store.saveTranscript(transcript, snapshot: snapshot)
                existingByChunk[transcript.chunkIndex] = transcript
            }
            if !existingByChunk.isEmpty {
                try sidecar.saveTranscripts(Array(existingByChunk.values))
            }
            var existingTranslations: [String: [UUID: TranslationSegment]] = [:]
            for language in request.options.targetLanguages {
                var stored = try store.translations(jobID: request.jobID, language: language, modelID: request.options.translationModel)
                for translation in try sidecar.loadTranslations(language: language, modelID: request.options.translationModel)
                    where stored[translation.transcriptID] == nil
                        && existingByChunk.values.contains(where: { $0.id == translation.transcriptID })
                {
                    try store.saveTranslation(translation, snapshot: snapshot)
                    stored[translation.transcriptID] = translation
                }
                existingTranslations[language] = stored
                if !stored.isEmpty {
                    try sidecar.saveTranslations(
                        Array(stored.values),
                        language: language,
                        modelID: request.options.translationModel,
                        transcripts: Array(existingByChunk.values)
                    )
                }
            }

            let asset = AVURLAsset(url: mediaURL)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw VideoLingoError.mediaHasNoAudio }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else { throw VideoLingoError.mediaHasNoAudio }

            let chunkDuration = max(10, request.options.chunkDuration)
            let qualityMode = request.options.qualityMode ?? .fast
            let glossary = request.options.glossary ?? []
            var detectedLanguage = request.options.sourceLanguage
                ?? existingByChunk.values.sorted(by: { $0.chunkIndex < $1.chunkIndex }).compactMap(\.language).first
            let total = max(1, Int(ceil(duration / chunkDuration)))
            snapshot.totalChunks = total
            let targetCount = request.options.targetLanguages.count
            let transcriptIDs = Set(existingByChunk.values.map(\.id))
            var completedTranslations = existingTranslations.values.reduce(into: 0) { count, translations in
                count += translations.keys.filter(transcriptIDs.contains).count
            }
            snapshot.sttProgress = stageProgress(completed: existingByChunk.count, total: total)
            snapshot.translationProgress = targetCount == 0
                ? 1
                : stageProgress(completed: completedTranslations, total: total * targetCount)
            snapshot.status = .queued
            snapshot.lastTranscriptText = existingByChunk.values.max(by: { $0.chunkIndex < $1.chunkIndex })?.text
            snapshot.lastTranslationText = existingByChunk.values
                .sorted(by: { $0.chunkIndex > $1.chunkIndex })
                .compactMap { transcript in
                    request.options.targetLanguages.lazy.compactMap { existingTranslations[$0]?[transcript.id]?.text }.first
                }
                .first
            snapshot.progress = combinedProgress(snapshot)
            snapshot.message = existingByChunk.isEmpty ? "STT 준비 중" : "저장된 작업에서 이어서 시작합니다"
            snapshot.updatedAt = .now
            try store.save(snapshot: snapshot)
            publish(snapshot)

            // STT와 번역을 동시에 실행합니다. 번역 태스크는 STT가 5% 진행된 뒤부터
            // 준비된 청크를 순서대로 번역해, STT 완료를 기다리지 않고 곧바로 시작합니다.
            let coordinator = PipelineCoordinator(
                snapshot: snapshot,
                transcripts: existingByChunk,
                translations: existingTranslations,
                completedTranslations: completedTranslations,
                detectedLanguage: detectedLanguage,
                total: total,
                targetCount: targetCount,
                translationModelID: request.options.translationModel,
                store: store,
                sidecar: sidecar,
                publish: onSnapshot
            )

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.runSTTStage(
                        coordinator: coordinator,
                        request: request,
                        mediaURL: mediaURL,
                        duration: duration,
                        chunkDuration: chunkDuration,
                        total: total,
                        chunksFolder: chunksFolder,
                        modelsURL: modelsURL,
                        glossary: glossary,
                        qualityMode: qualityMode
                    )
                }
                group.addTask {
                    try await self.runTranslationStage(
                        coordinator: coordinator,
                        request: request,
                        total: total,
                        speechFolder: speechFolder,
                        modelsURL: modelsURL,
                        glossary: glossary,
                        qualityMode: qualityMode,
                        targetCount: targetCount
                    )
                }
                try await group.waitForAll()
            }

            snapshot = await coordinator.currentSnapshot()
            existingByChunk = await coordinator.currentTranscripts()
            existingTranslations = await coordinator.currentTranslations()
            completedTranslations = await coordinator.currentCompletedTranslations()
            detectedLanguage = await coordinator.currentDetectedLanguage()

            let genericSpeakerLabels = SpeakerLabelRewriter.labels(in: Array(existingByChunk.values))
            if !genericSpeakerLabels.isEmpty {
                snapshot.status = .transcribing
                snapshot.message = "전체 문서에서 화자 이름과 역할 분석 중"
                snapshot.liveTranscriptText = "화자 문맥 분석 준비 중"
                snapshot.updatedAt = .now
                try store.save(snapshot: snapshot)
                publish(snapshot)
                do {
                    let mapping = try await translator.resolveSpeakerNames(
                        in: Array(existingByChunk.values),
                        sourceLanguage: request.options.sourceLanguage,
                        modelID: request.options.translationModel,
                        modelsURL: modelsURL,
                        onPartialText: { [onLiveTranscript] text in
                            onLiveTranscript(request.jobID, total, total, text)
                        }
                    )
                    if !mapping.isEmpty {
                        existingByChunk = existingByChunk.mapValues { SpeakerLabelRewriter.rewrite($0, using: mapping) }
                        for language in request.options.targetLanguages {
                            existingTranslations[language] = existingTranslations[language, default: [:]].mapValues {
                                SpeakerLabelRewriter.rewrite($0, using: mapping)
                            }
                        }
                        snapshot.lastTranscriptText = existingByChunk.values.max(by: { $0.chunkIndex < $1.chunkIndex })?.text
                        snapshot.lastTranslationText = existingByChunk.values
                            .sorted(by: { $0.chunkIndex > $1.chunkIndex })
                            .compactMap { transcript in
                                request.options.targetLanguages.lazy.compactMap { existingTranslations[$0]?[transcript.id]?.text }.first
                            }
                            .first
                        snapshot.liveTranscriptText = nil
                        snapshot.message = "화자 이름·역할 분석 결과 저장 완료"
                        snapshot.updatedAt = .now
                        try store.saveSpeakerResolvedResults(
                            transcripts: Array(existingByChunk.values),
                            translations: existingTranslations.values.flatMap { Array($0.values) },
                            snapshot: snapshot
                        )
                        try sidecar.saveTranscripts(Array(existingByChunk.values))
                        for language in request.options.targetLanguages {
                            try sidecar.saveTranslations(
                                Array(existingTranslations[language, default: [:]].values),
                                language: language,
                                modelID: request.options.translationModel,
                                transcripts: Array(existingByChunk.values)
                            )
                        }
                        publish(snapshot)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    snapshot.liveTranscriptText = nil
                    snapshot.message = "화자 이름 분석 실패 · 기존 화자 번호를 유지합니다"
                    snapshot.updatedAt = .now
                    try store.save(snapshot: snapshot)
                    publish(snapshot)
                }
            }

            // 번역과 번역 음성은 위 STT·번역 동시 파이프라인에서 이미 처리되었습니다.

            do {
                try await runContinuousRefinement(
                    request: request,
                    asset: asset,
                    duration: duration,
                    chunkDuration: chunkDuration,
                    total: total,
                    chunksFolder: chunksFolder,
                    speechFolder: speechFolder,
                    modelsURL: modelsURL,
                    glossary: glossary,
                    store: store,
                    sidecar: sidecar,
                    snapshot: &snapshot,
                    transcripts: &existingByChunk,
                    translations: &existingTranslations
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                snapshot.status = .refining
                snapshot.progress = 1
                snapshot.message = "기존 완료 결과 유지 · 백그라운드 품질 개선은 다음 실행에서 재개"
                snapshot.error = nil
                snapshot.updatedAt = .now
                try store.save(snapshot: snapshot)
                publish(snapshot)
            }

            if request.options.synthesizeSpeech {
                for language in request.options.targetLanguages {
                    try Task.checkCancellation()
                    snapshot.status = .synthesizing
                    snapshot.message = "\(language) 번역 음성 MP4 조합 중"
                    snapshot.updatedAt = .now
                    try store.save(snapshot: snapshot)
                    publish(snapshot)
                    let output = request.workspaceURL.appending(path: "dubbed-\(language).mp4")
                    try await DubbedVideoExporter.export(
                        sourceAsset: asset,
                        language: language,
                        speechFolder: speechFolder,
                        chunkDuration: chunkDuration,
                        totalChunks: total,
                        outputURL: output
                    )
                }
            }

            snapshot.status = .completed
            snapshot.progress = 1
            snapshot.sttProgress = 1
            snapshot.translationProgress = 1
            snapshot.currentChunk = snapshot.totalChunks
            let improved = snapshot.refinementImprovements ?? 0
            let refinementPending = (request.options.continuousImprovement ?? false)
                && snapshot.refinementProgress.map { $0 < 1 } == true
            snapshot.message = refinementPending
                ? "STT와 번역 완료 · 품질 개선은 다음 실행에서 재개"
                : (improved > 0
                    ? "STT와 번역 완료 · 백그라운드에서 \(improved)건 품질 개선"
                    : "STT와 번역 완료")
            snapshot.updatedAt = .now
            try store.save(snapshot: snapshot)
            publish(snapshot)
        } catch is CancellationError {
            if snapshot.status == .refining, snapshot.progress >= 1 {
                snapshot.status = .completed
                snapshot.message = "STT와 번역 결과 유지 · 백그라운드 품질 개선 중지"
            } else {
                snapshot.status = .cancelled
                snapshot.message = "작업이 취소되었습니다. 저장된 청크부터 다시 시작할 수 있습니다."
            }
            snapshot.updatedAt = .now
            try? JobStore(url: request.databaseURL).save(snapshot: snapshot)
            publish(snapshot)
        } catch {
            snapshot.status = .failed
            snapshot.message = "처리 실패"
            snapshot.error = error.localizedDescription
            snapshot.updatedAt = .now
            try? JobStore(url: request.databaseURL).save(snapshot: snapshot)
            publish(snapshot)
        }
    }

    private func runSTTStage(
        coordinator: PipelineCoordinator,
        request: StartJobRequest,
        mediaURL: URL,
        duration: TimeInterval,
        chunkDuration: TimeInterval,
        total: Int,
        chunksFolder: URL,
        modelsURL: URL,
        glossary: [GlossaryEntry],
        qualityMode: ProcessingQualityMode
    ) async throws {
        let asset = AVURLAsset(url: mediaURL)
        var producedTranscripts = await coordinator.currentTranscripts()
        var detectedLanguage = await coordinator.currentDetectedLanguage()
        do {
            for index in 0..<total {
                try Task.checkCancellation()
                if producedTranscripts[index] != nil { continue }

                let start = Double(index) * chunkDuration
                let end = min(duration, start + chunkDuration)

                try await coordinator.markStatus(.extracting, index: index, message: "오디오 청크 \(index + 1)/\(total) 추출 중")

                let overlap: TimeInterval = qualityMode == .fast ? 0 : (qualityMode == .maximum ? 2 : 1.25)
                let extractionStart = max(0, start - overlap)
                let extractionEnd = min(duration, end + overlap)
                let audioURL = chunksFolder.appending(path: String(format: "chunk-%@-%05d.m4a", qualityMode.rawValue, index))
                if !FileManager.default.fileExists(atPath: audioURL.path) {
                    try await exportAudio(asset: asset, start: extractionStart, duration: extractionEnd - extractionStart, to: audioURL)
                }

                try await coordinator.markStatus(.transcribing, index: index, message: "STT \(index + 1)/\(total) 처리 중")
                let sttOutput = try await stt.transcribe(
                    audioURL: audioURL,
                    model: request.options.sttModel,
                    language: detectedLanguage,
                    modelsURL: modelsURL,
                    prompt: sttPrompt(before: index, transcripts: producedTranscripts, glossary: glossary),
                    qualityMode: qualityMode,
                    onPartialText: { [onLiveTranscript] text in
                        onLiveTranscript(request.jobID, index, total, text)
                    }
                )
                let timedCues = sttOutput.cues.compactMap { cue -> TranscriptCue? in
                    let cueStart = max(start, min(end, extractionStart + cue.startTime))
                    let cueEnd = max(cueStart, min(end, extractionStart + cue.endTime))
                    guard cueEnd > cueStart, !cue.text.isEmpty else { return nil }
                    return TranscriptCue(startTime: cueStart, endTime: cueEnd, text: cue.text)
                }
                let transcript = TranscriptSegment(
                    jobID: request.jobID,
                    chunkIndex: index,
                    startTime: timedCues.first?.startTime ?? start,
                    endTime: timedCues.last?.endTime ?? end,
                    text: timedCues.isEmpty ? sttOutput.text : timedCues.map(\.text).joined(separator: "\n"),
                    language: request.options.sourceLanguage ?? sttOutput.language,
                    confidence: sttOutput.confidence,
                    cues: timedCues,
                    qualityStatus: sttOutput.qualityNotes.contains(where: { $0.contains("검토 권장") }) ? .warning : (sttOutput.retryCount > 0 ? .reviewed : .good),
                    retryCount: sttOutput.retryCount,
                    qualityNotes: sttOutput.qualityNotes
                )
                if detectedLanguage == nil, (transcript.confidence ?? 0) >= 0.35 {
                    detectedLanguage = transcript.language
                    await coordinator.setDetectedLanguage(detectedLanguage)
                }
                producedTranscripts[index] = transcript
                try await coordinator.commitTranscript(transcript)
            }
            await coordinator.markSTTFinished()
        } catch {
            // 실패·취소 시에도 완료 신호를 보내 번역 태스크가 무한 대기하지 않도록 합니다.
            await coordinator.markSTTFinished()
            throw error
        }
    }

    private func runTranslationStage(
        coordinator: PipelineCoordinator,
        request: StartJobRequest,
        total: Int,
        speechFolder: URL,
        modelsURL: URL,
        glossary: [GlossaryEntry],
        qualityMode: ProcessingQualityMode,
        targetCount: Int
    ) async throws {
        guard targetCount > 0 else { return }

        // STT가 5% 진행될 때까지 대기한 뒤 번역을 시작합니다.
        while await coordinator.sttProgressValue() < 0.05, await coordinator.isSTTFinished() == false {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        for index in 0..<total {
            try Task.checkCancellation()

            // 해당 청크의 STT 결과가 준비될 때까지 대기합니다.
            var transcript = await coordinator.transcript(at: index)
            while transcript == nil, await coordinator.isSTTFinished() == false {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 100_000_000)
                transcript = await coordinator.transcript(at: index)
            }
            guard let transcript else { continue }

            // 다음 문맥(다음 청크)이 준비될 때까지만 잠시 대기해 번역 품질을 유지합니다.
            if index + 1 < total {
                while await coordinator.transcript(at: index + 1) == nil, await coordinator.isSTTFinished() == false {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }

            for language in request.options.targetLanguages {
                try Task.checkCancellation()
                let translation: TranslationSegment
                if let existing = await coordinator.existingTranslation(language: language, transcriptID: transcript.id) {
                    translation = existing
                } else {
                    try await coordinator.markTranslating(index: index, language: language, message: "\(language) 번역 \(index + 1)/\(total)")
                    let previousContext = await coordinator.translationContextBefore(index: index)
                    let nextContext = await coordinator.translationContextAfter(index: index)
                    let translated = try await translator.translate(
                        transcript.text,
                        jobID: request.jobID,
                        sourceLanguage: transcript.language ?? request.options.sourceLanguage,
                        targetLanguage: language,
                        modelID: request.options.translationModel,
                        modelsURL: modelsURL,
                        previousContext: previousContext,
                        nextContext: nextContext,
                        glossary: glossary,
                        qualityMode: qualityMode,
                        onPartialText: { [onLiveTranslation] text in
                            onLiveTranslation(request.jobID, index, total, language, text)
                        }
                    )
                    translation = TranslationSegment(
                        transcriptID: transcript.id,
                        jobID: request.jobID,
                        targetLanguage: language,
                        modelID: request.options.translationModel,
                        text: translated.text,
                        qualityStatus: translated.qualityStatus,
                        qualityNotes: translated.qualityNotes
                    )
                    try await coordinator.commitTranslation(translation, index: index, language: language)
                }
                if request.options.synthesizeSpeech, !translation.text.isEmpty {
                    try await coordinator.markSynthesizing(index: index, language: language, message: "\(language) 번역 음성 \(index + 1)/\(total) 생성 중")
                    let speechURL = speechFolder.appending(path: String(format: "%@-%05d.m4a", language, index))
                    if !FileManager.default.fileExists(atPath: speechURL.path) {
                        try await tts.synthesize(translation.text, languageCode: language, outputURL: speechURL, modelsURL: modelsURL)
                    }
                }
            }
        }
    }

    private func runContinuousRefinement(
        request: StartJobRequest,
        asset: AVAsset,
        duration: TimeInterval,
        chunkDuration: TimeInterval,
        total: Int,
        chunksFolder: URL,
        speechFolder: URL,
        modelsURL: URL,
        glossary: [GlossaryEntry],
        store: JobStore,
        sidecar: MediaSidecarStore,
        snapshot: inout JobSnapshot,
        transcripts: inout [Int: TranscriptSegment],
        translations: inout [String: [UUID: TranslationSegment]]
    ) async throws {
        guard request.options.continuousImprovement ?? false else { return }
        let maximumPasses = min(5, max(1, request.options.maximumRefinementPasses ?? 3))
        var pass = snapshot.refinementPass ?? 0
        guard pass < maximumPasses else { return }
        var accumulatedImprovements = snapshot.refinementImprovements ?? 0

        while pass < maximumPasses {
            try Task.checkCancellation()
            let orderedIndices = transcripts.keys.sorted {
                let left = transcripts[$0]?.qualityStatus == .warning ? 0 : 1
                let right = transcripts[$1]?.qualityStatus == .warning ? 0 : 1
                return left == right ? $0 < $1 : left < right
            }
            let operationCount = max(1, orderedIndices.count * (1 + request.options.targetLanguages.count))
            var completedOperations = 0
            var passImprovements = 0

            snapshot.status = .refining
            snapshot.progress = 1
            snapshot.sttProgress = 1
            snapshot.translationProgress = 1
            snapshot.refinementPass = pass + 1
            snapshot.refinementProgress = 0
            snapshot.message = "완료 결과 유지 · 백그라운드 품질 개선 \(pass + 1)/\(maximumPasses)회차"
            snapshot.updatedAt = .now
            try store.save(snapshot: snapshot)
            publish(snapshot)

            for index in orderedIndices {
                try Task.checkCancellation()
                guard var currentTranscript = transcripts[index] else { continue }
                var transcriptChanged = false
                let shouldRetrySTT = currentTranscript.qualityStatus != .good || (currentTranscript.confidence ?? 0) < 0.82

                if shouldRetrySTT {
                    snapshot.message = "기존 STT 유지 · \(index + 1)/\(total) 개선 후보 비교 중"
                    snapshot.currentChunk = index
                    snapshot.updatedAt = .now
                    try store.save(snapshot: snapshot)
                    publish(snapshot)

                    let overlap: TimeInterval = 2
                    let start = Double(index) * chunkDuration
                    let end = min(duration, start + chunkDuration)
                    let extractionStart = max(0, start - overlap)
                    let extractionEnd = min(duration, end + overlap)
                    let audioURL = chunksFolder.appending(path: String(format: "refine-%05d.m4a", index))
                    if !FileManager.default.fileExists(atPath: audioURL.path) {
                        try await exportAudio(asset: asset, start: extractionStart, duration: extractionEnd - extractionStart, to: audioURL)
                    }
                    let output = try await stt.transcribe(
                        audioURL: audioURL,
                        model: request.options.sttModel,
                        language: currentTranscript.language ?? request.options.sourceLanguage,
                        modelsURL: modelsURL,
                        prompt: sttPrompt(before: index, transcripts: transcripts, glossary: glossary),
                        qualityMode: .maximum,
                        onPartialText: { [onLiveTranscript] text in
                            onLiveTranscript(request.jobID, index, total, "품질 개선 후보 · \(text)")
                        }
                    )
                    var candidateCues = output.cues.compactMap { cue -> TranscriptCue? in
                        let cueStart = max(start, min(end, extractionStart + cue.startTime))
                        let cueEnd = max(cueStart, min(end, extractionStart + cue.endTime))
                        guard cueEnd > cueStart, !cue.text.isEmpty else { return nil }
                        return TranscriptCue(startTime: cueStart, endTime: cueEnd, text: cue.text)
                    }
                    var candidateText = candidateCues.isEmpty ? output.text : candidateCues.map(\.text).joined(separator: "\n")
                    if let carried = carryingSpeakerLabels(from: currentTranscript.text, to: candidateText) {
                        candidateText = carried
                        if containsSpeakerLabels(currentTranscript.text) {
                            if let originalCues = currentTranscript.cues,
                               originalCues.count == candidateCues.count {
                                candidateCues = zip(originalCues, candidateCues).map { original, candidate in
                                    TranscriptCue(
                                        startTime: candidate.startTime,
                                        endTime: candidate.endTime,
                                        text: carryingSpeakerLabels(from: original.text, to: candidate.text) ?? candidate.text
                                    )
                                }
                            } else {
                                candidateText = ""
                            }
                        }
                    } else {
                        candidateText = ""
                    }
                    let candidateStatus: SegmentQualityStatus = output.qualityNotes.contains(where: { $0.contains("검토 권장") })
                        ? .warning
                        : .reviewed
                    let confidenceGain = (output.confidence ?? 0) - (currentTranscript.confidence ?? 0)
                    let statusImproved = qualityRank(candidateStatus) > qualityRank(currentTranscript.qualityStatus ?? .warning)
                    if !candidateText.isEmpty,
                       candidateText != currentTranscript.text,
                       confidenceGain >= 0.03 || (statusImproved && confidenceGain >= 0) {
                        currentTranscript = TranscriptSegment(
                            id: currentTranscript.id,
                            jobID: currentTranscript.jobID,
                            chunkIndex: currentTranscript.chunkIndex,
                            startTime: candidateCues.first?.startTime ?? currentTranscript.startTime,
                            endTime: candidateCues.last?.endTime ?? currentTranscript.endTime,
                            text: candidateText,
                            language: currentTranscript.language ?? output.language,
                            confidence: output.confidence,
                            cues: candidateCues,
                            qualityStatus: candidateStatus,
                            retryCount: (currentTranscript.retryCount ?? 0) + output.retryCount + 1,
                            qualityNotes: output.qualityNotes + ["백그라운드 품질 개선 \(pass + 1)회차 채택"]
                        )
                        transcripts[index] = currentTranscript
                        transcriptChanged = true
                        passImprovements += 1
                        accumulatedImprovements += 1
                        snapshot.refinementRevision = (snapshot.refinementRevision ?? 0) + 1
                        snapshot.refinementImprovements = accumulatedImprovements
                        snapshot.lastTranscriptText = currentTranscript.text
                        try store.saveTranscript(currentTranscript, snapshot: snapshot)
                        try sidecar.saveTranscripts(Array(transcripts.values))
                        publish(snapshot)
                    }
                }

                completedOperations += 1
                snapshot.refinementProgress = Double(completedOperations) / Double(operationCount)
                snapshot.updatedAt = .now
                try store.save(snapshot: snapshot)
                publish(snapshot)

                for language in request.options.targetLanguages {
                    try Task.checkCancellation()
                    let existing = translations[language]?[currentTranscript.id]
                    snapshot.message = "기존 번역 유지 · \(language.uppercased()) \(index + 1)/\(total) 개선 후보 비교 중"
                    snapshot.updatedAt = .now
                    try store.save(snapshot: snapshot)
                    publish(snapshot)

                    let candidate = try await translator.translate(
                        currentTranscript.text,
                        jobID: request.jobID,
                        sourceLanguage: currentTranscript.language ?? request.options.sourceLanguage,
                        targetLanguage: language,
                        modelID: request.options.translationModel,
                        modelsURL: modelsURL,
                        previousContext: translationContext(before: index, transcripts: transcripts),
                        nextContext: translationContext(after: index, transcripts: transcripts),
                        glossary: glossary,
                        qualityMode: .maximum,
                        onPartialText: { [onLiveTranslation] text in
                            onLiveTranslation(request.jobID, index, total, language, "품질 개선 후보 · \(text)")
                        }
                    )
                    let candidateImproved = existing == nil
                        || transcriptChanged
                        || qualityRank(candidate.qualityStatus) > qualityRank(existing?.qualityStatus ?? .warning)
                        || (existing?.qualityStatus == .warning && candidate.qualityNotes.count < (existing?.qualityNotes?.count ?? .max))
                    if candidateImproved,
                       !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       candidate.text != existing?.text {
                        let refined = TranslationSegment(
                            id: existing?.id ?? UUID(),
                            transcriptID: currentTranscript.id,
                            jobID: request.jobID,
                            targetLanguage: language,
                            modelID: request.options.translationModel,
                            text: candidate.text,
                            qualityStatus: candidate.qualityStatus,
                            qualityNotes: candidate.qualityNotes + ["백그라운드 품질 개선 \(pass + 1)회차 채택"]
                        )
                        translations[language, default: [:]][currentTranscript.id] = refined
                        passImprovements += 1
                        accumulatedImprovements += 1
                        snapshot.refinementRevision = (snapshot.refinementRevision ?? 0) + 1
                        snapshot.refinementImprovements = accumulatedImprovements
                        snapshot.lastTranslationText = refined.text
                        try store.saveTranslation(refined, snapshot: snapshot)
                        try sidecar.saveTranslations(
                            Array(translations[language, default: [:]].values),
                            language: language,
                            modelID: request.options.translationModel,
                            transcripts: Array(transcripts.values)
                        )
                        if request.options.synthesizeSpeech, !refined.text.isEmpty {
                            let speechURL = speechFolder.appending(path: String(format: "%@-%05d.m4a", language, index))
                            try? FileManager.default.removeItem(at: speechURL)
                            try await tts.synthesize(refined.text, languageCode: language, outputURL: speechURL, modelsURL: modelsURL)
                        }
                        publish(snapshot)
                    }
                    completedOperations += 1
                    snapshot.refinementProgress = Double(completedOperations) / Double(operationCount)
                    snapshot.liveTranslationText = nil
                    snapshot.updatedAt = .now
                    try store.save(snapshot: snapshot)
                    publish(snapshot)
                }
            }

            pass += 1
            snapshot.refinementPass = pass
            snapshot.refinementProgress = 1
            snapshot.refinementImprovements = accumulatedImprovements
            snapshot.message = passImprovements == 0
                ? "품질 개선 수렴 완료 · 기존 결과 유지"
                : "\(pass)회차에서 \(passImprovements)건 개선 · 다음 회차 확인"
            snapshot.updatedAt = .now
            try store.save(snapshot: snapshot)
            publish(snapshot)
            if passImprovements == 0 { break }
        }
    }

    private func qualityRank(_ status: SegmentQualityStatus) -> Int {
        switch status {
        case .warning: 0
        case .reviewed: 1
        case .good: 2
        }
    }

    private func carryingSpeakerLabels(from original: String, to candidate: String) -> String? {
        let originalLines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let candidateLines = candidate.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let labels = originalLines.map(speakerPrefix)
        guard labels.contains(where: { $0 != nil }) else { return candidate }
        guard originalLines.count == candidateLines.count else { return nil }
        return zip(labels, candidateLines).map { label, line in
            guard let label else { return line }
            let content = removingSpeakerPrefix(from: line)
            return content.isEmpty ? label : "\(label) \(content)"
        }.joined(separator: "\n")
    }

    private func speakerPrefix(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") else { return nil }
        let prefix = String(trimmed[...end])
        return prefix.count <= 80 ? prefix : nil
    }

    private func containsSpeakerLabels(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { speakerPrefix(String($0)) != nil }
    }

    private func removingSpeakerPrefix(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let prefix = speakerPrefix(trimmed) else { return trimmed }
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private func exportAudio(asset: AVAsset, start: TimeInterval, duration: TimeInterval, to outputURL: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw VideoLingoError.mediaHasNoAudio
        }
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        try await exporter.export(to: outputURL, as: .m4a)
    }

    private func resolveMediaURL(_ request: StartJobRequest, accessedURL: inout URL?) throws -> URL {
        guard let bookmark = request.securityScopedBookmark else { return request.mediaURL }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if url.startAccessingSecurityScopedResource() { accessedURL = url }
            return url
        } catch {
            // 비샌드박스 빌드의 XPC 서비스에서는 security-scoped bookmark가
            // 유효한 로컬 파일을 가리켜도 복원되지 않을 수 있습니다.
            // 실제 파일을 읽을 수 있을 때만 원본 URL로 안전하게 복구합니다.
            guard FileManager.default.isReadableFile(atPath: request.mediaURL.path) else {
                throw error
            }
            return request.mediaURL
        }
    }

    private func update(_ value: JobSnapshot, status: JobStatus, index: Int, total: Int, message: String) -> JobSnapshot {
        var copy = value
        copy.status = status
        copy.currentChunk = index
        copy.totalChunks = total
        copy.progress = combinedProgress(copy)
        copy.message = message
        copy.updatedAt = .now
        return copy
    }

    private func stageProgress(completed: Int, total: Int) -> Double {
        guard total > 0 else { return 1 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    private func translationContext(before index: Int, transcripts: [Int: TranscriptSegment]) -> [String] {
        transcripts.values
            .filter { $0.chunkIndex < index && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.chunkIndex < $1.chunkIndex }
            .suffix(2)
            .map(\.text)
    }

    private func translationContext(after index: Int, transcripts: [Int: TranscriptSegment]) -> [String] {
        transcripts.values
            .filter { $0.chunkIndex > index && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.chunkIndex < $1.chunkIndex }
            .prefix(1)
            .map(\.text)
    }

    private func sttPrompt(before index: Int, transcripts: [Int: TranscriptSegment], glossary: [GlossaryEntry]) -> String {
        let previous = transcripts[index - 1]?.text ?? ""
        let terms = glossary.map(\.source).joined(separator: ", ")
        return [
            previous.isEmpty ? nil : "이전 발화: \(String(previous.suffix(700)))",
            terms.isEmpty ? nil : "중요 이름과 용어: \(terms)"
        ].compactMap { $0 }.joined(separator: "\n")
    }

    private func combinedProgress(_ snapshot: JobSnapshot) -> Double {
        min(1, max(0, (snapshot.sttProgress + snapshot.translationProgress) / 2))
    }

    private func publish(_ snapshot: JobSnapshot) {
        onSnapshot(snapshot)
    }
}

/// STT와 번역 태스크가 공유하는 스냅샷·전사·번역 상태를 직렬화해 데이터 경합 없이 갱신합니다.
private actor PipelineCoordinator {
    private var snapshot: JobSnapshot
    private var transcripts: [Int: TranscriptSegment]
    private var translations: [String: [UUID: TranslationSegment]]
    private var completedTranslations: Int
    private var detectedLanguage: String?
    private var sttFinished = false
    private let total: Int
    private let targetCount: Int
    private let translationModelID: String
    private let store: JobStore
    private let sidecar: MediaSidecarStore
    private let publish: @Sendable (JobSnapshot) -> Void

    init(
        snapshot: JobSnapshot,
        transcripts: [Int: TranscriptSegment],
        translations: [String: [UUID: TranslationSegment]],
        completedTranslations: Int,
        detectedLanguage: String?,
        total: Int,
        targetCount: Int,
        translationModelID: String,
        store: JobStore,
        sidecar: MediaSidecarStore,
        publish: @escaping @Sendable (JobSnapshot) -> Void
    ) {
        self.snapshot = snapshot
        self.transcripts = transcripts
        self.translations = translations
        self.completedTranslations = completedTranslations
        self.detectedLanguage = detectedLanguage
        self.total = total
        self.targetCount = targetCount
        self.translationModelID = translationModelID
        self.store = store
        self.sidecar = sidecar
        self.publish = publish
    }

    // MARK: 읽기
    func currentSnapshot() -> JobSnapshot { snapshot }
    func currentTranscripts() -> [Int: TranscriptSegment] { transcripts }
    func currentTranslations() -> [String: [UUID: TranslationSegment]] { translations }
    func currentCompletedTranslations() -> Int { completedTranslations }
    func currentDetectedLanguage() -> String? { detectedLanguage }
    func transcript(at index: Int) -> TranscriptSegment? { transcripts[index] }
    func existingTranslation(language: String, transcriptID: UUID) -> TranslationSegment? {
        translations[language]?[transcriptID]
    }
    func sttProgressValue() -> Double { snapshot.sttProgress }
    func isSTTFinished() -> Bool { sttFinished }

    func translationContextBefore(index: Int) -> [String] {
        transcripts.values
            .filter { $0.chunkIndex < index && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.chunkIndex < $1.chunkIndex }
            .suffix(2)
            .map(\.text)
    }

    func translationContextAfter(index: Int) -> [String] {
        transcripts.values
            .filter { $0.chunkIndex > index && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.chunkIndex < $1.chunkIndex }
            .prefix(1)
            .map(\.text)
    }

    // MARK: STT 갱신
    func setDetectedLanguage(_ language: String?) { detectedLanguage = language }

    func markStatus(_ status: JobStatus, index: Int, message: String) throws {
        snapshot.status = status
        snapshot.currentChunk = index
        snapshot.totalChunks = total
        snapshot.message = message
        snapshot.progress = combinedProgress()
        snapshot.updatedAt = .now
        try store.save(snapshot: snapshot)
        publish(snapshot)
    }

    func commitTranscript(_ transcript: TranscriptSegment) throws {
        transcripts[transcript.chunkIndex] = transcript
        snapshot.sttProgress = stageProgress(completed: transcripts.count, total: total)
        snapshot.lastTranscriptText = transcript.text
        snapshot.liveTranscriptText = nil
        snapshot.status = .transcribing
        snapshot.currentChunk = transcript.chunkIndex + 1
        snapshot.message = "STT \(transcript.chunkIndex + 1)/\(total) 저장 완료"
        snapshot.progress = combinedProgress()
        snapshot.updatedAt = .now
        try store.saveTranscript(transcript, snapshot: snapshot)
        try sidecar.saveTranscripts(Array(transcripts.values))
        publish(snapshot)
    }

    func markSTTFinished() { sttFinished = true }

    // MARK: 번역 갱신
    func markTranslating(index: Int, language: String, message: String) throws {
        snapshot.liveTranslationText = nil
        snapshot.status = .translating
        snapshot.totalChunks = total
        snapshot.message = message
        snapshot.progress = combinedProgress()
        snapshot.updatedAt = .now
        try store.save(snapshot: snapshot)
        publish(snapshot)
    }

    func commitTranslation(_ translation: TranslationSegment, index: Int, language: String) throws {
        translations[language, default: [:]][translation.transcriptID] = translation
        completedTranslations += 1
        snapshot.translationProgress = targetCount == 0
            ? 1
            : stageProgress(completed: completedTranslations, total: total * targetCount)
        snapshot.lastTranslationText = translation.text
        snapshot.liveTranslationText = nil
        snapshot.status = .translating
        snapshot.message = "\(language.uppercased()) 번역 \(index + 1)/\(total) 저장 완료"
        snapshot.progress = combinedProgress()
        snapshot.updatedAt = .now
        try store.saveTranslation(translation, snapshot: snapshot)
        try sidecar.saveTranslations(
            Array(translations[language, default: [:]].values),
            language: language,
            modelID: translationModelID,
            transcripts: Array(transcripts.values)
        )
        publish(snapshot)
    }

    func markSynthesizing(index: Int, language: String, message: String) throws {
        snapshot.status = .synthesizing
        snapshot.totalChunks = total
        snapshot.message = message
        snapshot.progress = combinedProgress()
        snapshot.updatedAt = .now
        try store.save(snapshot: snapshot)
        publish(snapshot)
    }

    // MARK: 보조 계산
    private func stageProgress(completed: Int, total: Int) -> Double {
        guard total > 0 else { return 1 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    private func combinedProgress() -> Double {
        min(1, max(0, (snapshot.sttProgress + snapshot.translationProgress) / 2))
    }
}

private enum DubbedVideoExporter {
    static func export(
        sourceAsset: AVAsset,
        language: String,
        speechFolder: URL,
        chunkDuration: TimeInterval,
        totalChunks: Int,
        outputURL: URL
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let composition = AVMutableComposition()
        let duration = try await sourceAsset.load(.duration)

        if let sourceVideo = try await sourceAsset.loadTracks(withMediaType: .video).first,
           let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
            videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
        }

        var originalAudioTrack: AVMutableCompositionTrack?
        if let sourceAudio = try await sourceAsset.loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceAudio, at: .zero)
            originalAudioTrack = track
        }

        guard let voiceTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoLingoError.mediaHasNoAudio
        }
        for index in 0..<totalChunks {
            let url = speechFolder.appending(path: String(format: "%@-%05d.m4a", language, index))
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let speechAsset = AVURLAsset(url: url)
            guard let track = try await speechAsset.loadTracks(withMediaType: .audio).first else { continue }
            let speechDuration = try await speechAsset.load(.duration)
            let start = CMTime(seconds: Double(index) * chunkDuration, preferredTimescale: 600)
            try voiceTrack.insertTimeRange(CMTimeRange(start: .zero, duration: speechDuration), of: track, at: start)
            if speechDuration.seconds > chunkDuration {
                voiceTrack.scaleTimeRange(
                    CMTimeRange(start: start, duration: speechDuration),
                    toDuration: CMTime(seconds: chunkDuration, preferredTimescale: 600)
                )
            }
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoLingoError.mediaHasNoAudio
        }
        if let originalAudioTrack {
            let original = AVMutableAudioMixInputParameters(track: originalAudioTrack)
            original.setVolume(0.12, at: .zero)
            let voice = AVMutableAudioMixInputParameters(track: voiceTrack)
            voice.setVolume(1, at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [original, voice]
            exporter.audioMix = mix
        }
        try await exporter.export(to: outputURL, as: .mp4)
    }
}
