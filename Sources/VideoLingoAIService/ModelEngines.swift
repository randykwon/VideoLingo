import Foundation
import FoundationModels
import Hub
import MLXLLM
import MLXLMCommon
import SpeakerKit
import TTSKit
import WhisperKit
import VideoLingoCore

final class WhisperSTTEngine: @unchecked Sendable {
    struct Output: Sendable {
        let text: String
        let language: String?
        let confidence: Double?
        let cues: [TranscriptCue]
        let retryCount: Int
        let qualityNotes: [String]
    }

    private struct DiarizedOutput {
        let text: String
        let cues: [TranscriptCue]
    }

    private struct SegmentSelection {
        let segments: [TranscriptionSegment]
        let usedRelaxedFilter: Bool
    }

    private var pipe: WhisperKit?
    private var loadedModel: String?
    private var speakerKit: SpeakerKit?

    func transcribe(
        audioURL: URL,
        model: String,
        language: String?,
        modelsURL: URL,
        qualityMode: ProcessingQualityMode,
        onPartialText: @escaping @Sendable (String) -> Void
    ) async throws -> Output {
        if pipe == nil || loadedModel != model {
            pipe = try await WhisperKit(model: model, downloadBase: modelsURL)
            loadedModel = model
            if let folder = pipe?.modelFolder {
                ModelManifestWriter.save(kind: .stt, modelID: model, folder: folder, modelsURL: modelsURL)
            }
        }
        guard let pipe else { throw VideoLingoError.modelUnavailable("WhisperKit 초기화 실패") }
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            temperatureFallbackCount: qualityMode == .fast ? 2 : (qualityMode == .maximum ? 6 : 4),
            skipSpecialTokens: true,
            wordTimestamps: true,
            concurrentWorkerCount: 1,
            chunkingStrategy: .vad
        )
        var results = try await pipe.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options,
            callback: { progress in
                let text = TranscriptTextSanitizer.cleanWhisperText(progress.text)
                if !text.isEmpty { onPartialText(text) }
                return true
            }
        )
        var retryCount = 0
        var qualityNotes: [String] = []
        let initialScore = transcriptionScore(results)
        let initialSelection = segmentSelection(results)
        let initialText = extractedText(results, selection: initialSelection)
        var possibleSpeechDetected = containsPotentialSpeech(results)
        // VAD가 완전히 놓치면 음성 징후 자체가 결과에 남지 않습니다. 따라서 음성 징후 유무와 관계없이
        // 빈 VAD 결과는 반드시 non-VAD 디코딩으로 다시 확인한 뒤에만 무음으로 확정합니다.
        let needsCoverageRetry = TranscriptCoverage.requiresNonVADVerification(vadText: initialText)
        if needsCoverageRetry || (qualityMode != .fast && initialScore < 0.42) {
            retryCount = 1
            qualityNotes.append(needsCoverageRetry
                ? "빈 STT 누락 방지를 위한 비-VAD 재검증"
                : "낮은 STT 신뢰도로 자동 재시도")
            var retryOptions = options
            if needsCoverageRetry {
                retryOptions.chunkingStrategy = ChunkingStrategy.none
                retryOptions.promptTokens = nil
                qualityNotes.append(TranscriptCoverage.promptFreeVerificationNote)
            }
            // 처음부터 높은 temperature를 강제하면 무작위 오인식이 늘어나므로 0.0에서 시작해 단계적 폴백합니다.
            retryOptions.temperature = 0.0
            retryOptions.temperatureFallbackCount = qualityMode == .maximum ? 8 : 6
            retryOptions.logProbThreshold = -1.2
            let retryResults = try await pipe.transcribe(
                audioPath: audioURL.path,
                decodeOptions: retryOptions,
                callback: { progress in
                    let text = TranscriptTextSanitizer.cleanWhisperText(progress.text)
                    if !text.isEmpty { onPartialText("재검증 · \(text)") }
                    return true
                }
            )
            let retrySelection = segmentSelection(retryResults)
            let retryText = extractedText(retryResults, selection: retrySelection)
            possibleSpeechDetected = possibleSpeechDetected || containsPotentialSpeech(retryResults)
            if !retryText.isEmpty && (initialText.isEmpty || transcriptionScore(retryResults) > initialScore) {
                results = retryResults
                qualityNotes.append("재시도 결과 채택")
            } else {
                qualityNotes.append("최초 결과 유지")
            }
        }
        let selection = segmentSelection(results)
        let rawText = extractedText(results, selection: selection)
        let filteredText = TranscriptTextSanitizer.cleanWhisperText(rawText)
        let diarized: DiarizedOutput
        do {
            diarized = try await diarizedOutput(
                audioURL: audioURL,
                results: results,
                selection: selection,
                modelsURL: modelsURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 화자 분리 모델 오류로 이미 완료된 Whisper STT 결과를 버리지 않도록 안전하게 폴백합니다.
            diarized = DiarizedOutput(text: "", cues: [])
            qualityNotes.append("화자 분리 생략(Whisper 자막 유지)")
        }
        let fallbackCues = selection.segments.map { segment in
            TranscriptCue(
                startTime: Double(segment.start),
                endTime: Double(segment.end),
                text: TranscriptTextSanitizer.cleanWhisperText(segment.text)
            )
        }.filter { !$0.text.isEmpty && $0.endTime > $0.startTime }
        let text = diarized.text.isEmpty ? filteredText : diarized.text
        let cues = diarized.cues.isEmpty ? fallbackCues : diarized.cues
        let confidence: Double? = selection.segments.isEmpty
            ? nil
            : selection.segments.map { exp(Double($0.avgLogprob)) }.reduce(0, +) / Double(selection.segments.count)
        if selection.usedRelaxedFilter {
            qualityNotes.append("엄격 필터 탈락 문장을 완화 기준으로 복구")
        }
        if text.isEmpty {
            qualityNotes.append(possibleSpeechDetected
                ? "검토 권장: 음성 가능성이 있으나 STT 문장을 확정하지 못함"
                : TranscriptCoverage.verifiedSilenceNote)
        }
        if confidence.map({ $0 < 0.45 }) == true { qualityNotes.append("검토 권장: 낮은 음성 인식 신뢰도") }
        return Output(text: text, language: results.first?.language, confidence: confidence, cues: cues, retryCount: retryCount, qualityNotes: qualityNotes)
    }

    private func segmentSelection(_ results: [TranscriptionResult]) -> SegmentSelection {
        let segments = results.flatMap(\.segments)
        let strict = segments.filter { segment in
            let text = TranscriptTextSanitizer.cleanWhisperText(segment.text)
            return !text.isEmpty
                && !TranscriptTextSanitizer.isLikelyHallucination(
                    text,
                    noSpeechProb: Double(segment.noSpeechProb),
                    avgLogprob: Double(segment.avgLogprob)
                )
                && segment.noSpeechProb <= 0.6
                && segment.compressionRatio <= 2.4
                && segment.avgLogprob >= -1.2
        }
        if !strict.isEmpty { return SegmentSelection(segments: strict, usedRelaxedFilter: false) }

        let relaxed = segments.filter { segment in
            let text = TranscriptTextSanitizer.cleanWhisperText(segment.text)
            return !text.isEmpty
                && !TranscriptTextSanitizer.isLikelyHallucination(
                    text,
                    noSpeechProb: Double(segment.noSpeechProb),
                    avgLogprob: Double(segment.avgLogprob)
                )
                && segment.noSpeechProb <= 0.85
                && segment.compressionRatio <= 3.0
                && segment.avgLogprob >= -1.8
        }
        return SegmentSelection(segments: relaxed, usedRelaxedFilter: !relaxed.isEmpty)
    }

    private func extractedText(_ results: [TranscriptionResult], selection: SegmentSelection) -> String {
        if !selection.segments.isEmpty {
            return selection.segments.map(\.text).joined(separator: " ")
        }
        guard results.allSatisfy({ $0.segments.isEmpty }) else { return "" }
        let fallback = results.map(\.text).joined(separator: " ")
        return TranscriptTextSanitizer.isLikelyHallucination(fallback, noSpeechProb: 0.5, avgLogprob: -0.8) ? "" : fallback
    }

    private func containsPotentialSpeech(_ results: [TranscriptionResult]) -> Bool {
        if results.contains(where: {
            let text = TranscriptTextSanitizer.cleanWhisperText($0.text)
            return !text.isEmpty && !TranscriptTextSanitizer.isLikelyHallucination(text, noSpeechProb: 0.5, avgLogprob: -0.8)
        }) { return true }
        return results.flatMap(\.segments).contains { segment in
            let text = TranscriptTextSanitizer.cleanWhisperText(segment.text)
            return !text.isEmpty
                && !TranscriptTextSanitizer.isLikelyHallucination(
                    text,
                    noSpeechProb: Double(segment.noSpeechProb),
                    avgLogprob: Double(segment.avgLogprob)
                )
                && segment.noSpeechProb <= 0.9
        }
    }

    private func transcriptionScore(_ results: [TranscriptionResult]) -> Double {
        let segments = results.flatMap(\.segments).filter { segment in
            let text = TranscriptTextSanitizer.cleanWhisperText(segment.text)
            return !text.isEmpty
                && !TranscriptTextSanitizer.isLikelyHallucination(
                    text,
                    noSpeechProb: Double(segment.noSpeechProb),
                    avgLogprob: Double(segment.avgLogprob)
                )
                && segment.noSpeechProb <= 0.6
                && segment.compressionRatio <= 2.4
        }
        guard !segments.isEmpty else { return 0 }
        return segments.map { exp(Double($0.avgLogprob)) }.reduce(0, +) / Double(segments.count)
    }

    private func diarizedOutput(
        audioURL: URL,
        results: [TranscriptionResult],
        selection: SegmentSelection,
        modelsURL: URL
    ) async throws -> DiarizedOutput {
        // 유효한 음성 세그먼트가 없는 무음/환각 청크에서는 화자 분리 모델 실행을 생략합니다.
        guard !selection.segments.isEmpty else {
            return DiarizedOutput(text: "", cues: [])
        }
        let kit: SpeakerKit
        if let speakerKit {
            kit = speakerKit
        } else {
            let created = try await SpeakerKit(PyannoteConfig(
                downloadBase: modelsURL.path,
                download: true,
                load: true,
                verbose: false
            ))
            speakerKit = created
            kit = created
        }
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
        let diarization = try await kit.diarize(audioArray: audio)
        let maxNoSpeech: Float = selection.usedRelaxedFilter ? 0.85 : 0.6
        let maxCompression: Float = selection.usedRelaxedFilter ? 3.0 : 2.4
        let minLogprob: Float = selection.usedRelaxedFilter ? -1.8 : -1.2
        let aligned = diarization.addSpeakerInfo(to: results, strategy: .subsegment)
            .flatMap { $0 }
            .filter { segment in
                guard let transcription = segment.transcription else { return false }
                let text = TranscriptTextSanitizer.cleanWhisperText(segment.text)
                return !text.isEmpty
                    && !TranscriptTextSanitizer.isLikelyHallucination(
                        text,
                        noSpeechProb: Double(transcription.noSpeechProb),
                        avgLogprob: Double(transcription.avgLogprob)
                    )
                    && transcription.noSpeechProb <= maxNoSpeech
                    && transcription.compressionRatio <= maxCompression
                    && transcription.avgLogprob >= minLogprob
            }

        var turns: [(speaker: String, start: TimeInterval, end: TimeInterval, text: String)] = []
        for segment in aligned {
            let speaker = segment.speaker.speakerId.map { "화자 \($0 + 1)" } ?? "화자 미확인"
            let text = TranscriptTextSanitizer.cleanWhisperText(segment.text)
            let start = Double(segment.speakerWords.first?.wordTiming.start ?? segment.startTime)
            let end = Double(segment.speakerWords.last?.wordTiming.end ?? segment.endTime)
            let canMerge = turns.last.map {
                $0.speaker == speaker && start - $0.end <= 0.45 && $0.text.count + text.count <= 84
            } ?? false
            if canMerge {
                turns[turns.count - 1].end = max(turns[turns.count - 1].end, end)
                turns[turns.count - 1].text += text.hasPrefix(" ") ? text : " \(text)"
            } else {
                turns.append((speaker, start, end, text))
            }
        }
        let cues = turns.compactMap { turn -> TranscriptCue? in
            guard turn.end > turn.start else { return nil }
            return TranscriptCue(
                startTime: turn.start,
                endTime: turn.end,
                text: "[\(turn.speaker)] \(turn.text)"
            )
        }
        return DiarizedOutput(text: cues.map(\.text).joined(separator: "\n"), cues: cues)
    }
}

actor FoundationTranslationEngine {
    /// 여러 작업이 동시에 실행돼도 Apple Foundation Models 호출은 하나씩 처리합니다.
    /// 작업마다 별도 인스턴스를 만들면 동시 세션이 늘어 모델이 리소스 오류를 반환합니다.
    /// 온디바이스 모델은 이미 연산 자원을 포화시키므로 동시 호출로 처리량이 늘지도 않습니다.
    static let shared = FoundationTranslationEngine()

    struct TranslationOutput: Sendable {
        let text: String
        let qualityStatus: SegmentQualityStatus
        let qualityNotes: [String]
    }
    private struct SpeakerResolutionResponse: Codable {
        let speakers: [ResolvedSpeaker]
    }

    private struct ResolvedSpeaker: Codable {
        let label: String
        let name: String
        let basis: String?
    }

    private var mlxContainers: [String: ModelContainer] = [:]
    private var translationFailureStreaks: [UUID: Int] = [:]

    func resolveSpeakerNames(
        in transcripts: [TranscriptSegment],
        labels overrideLabels: [String]? = nil,
        sourceLanguage: String?,
        modelID: String,
        modelsURL: URL,
        externalServer: ExternalLLMClient.Configuration? = nil,
        translationEngine: TranslationEngineKind? = nil,
        managedTranslationURL: String? = nil,
        managedTranslationAPIKey: String? = nil,
        onPartialText: @escaping @Sendable (String) -> Void
    ) async throws -> [String: String] {
        // 재분석에서는 이미 이름이 적용된 라벨을 그대로 다시 판별하도록 외부에서 목록을 넘깁니다.
        let labels = overrideLabels ?? SpeakerLabelRewriter.labels(in: transcripts)
        guard !labels.isEmpty else { return [:] }
        let resolvedEngine = translationEngine ?? inferredEngine(for: modelID)
        let document = speakerEvidence(from: transcripts, labels: labels)
        let prompt = """
            Analyze the complete speaker-attributed video transcript below and identify each speaker.

            Rules:
            - Use an actual person's name ONLY when the transcript contains evidence such as a self-introduction, direct address, or another explicit identification.
            - Never invent a personal name.
            - If an actual name cannot be established, infer a short role from the speaker's utterances and conversation structure, such as Host, Interviewer, Guest, Lecturer, Student, Customer, or Participant.
            - Return inferred roles as plain role names. Never add words or markers such as "추정", "(추정)", "inferred", or "estimated".
            - Every label in LABELS must appear exactly once.
            - Names must be concise and must not contain square brackets.
            - Return JSON only, with no Markdown or explanation.

            Schema:
            {"speakers":[{"label":"화자 1","name":"홍길동","basis":"explicit"},{"label":"화자 2","name":"진행자","basis":"inferred"}]}

            SOURCE LANGUAGE: \(languageName(sourceLanguage))
            LABELS: \(labels.joined(separator: ", "))

            TRANSCRIPT EVIDENCE:
            \(document)
            """

        let response: String
        if resolvedEngine == .managedLlama,
           let url = managedTranslationURL,
           let managedConfig = ExternalLLMClient.Configuration(endpoint: url, model: "local", apiKey: managedTranslationAPIKey) {
            onPartialText("화자 이름 분석 중 · 자체 llama.cpp 서버 요청")
            response = try await ExternalLLMClient(configuration: managedConfig).complete(
                instructions: "문서의 화자를 식별하는 분석기입니다. 반드시 요청된 JSON만 출력하세요.",
                prompt: prompt,
                maximumTokens: min(1024, max(256, labels.count * 96))
            )
        } else if resolvedEngine == .externalOpenAI {
            guard let externalServer else {
                throw VideoLingoError.modelUnavailable("외부 LLM 서버 주소와 모델 이름을 설정에서 입력하세요.")
            }
            onPartialText("화자 이름 분석 중 · 외부 서버 요청")
            response = try await ExternalLLMClient(configuration: externalServer).complete(
                instructions: "문서의 화자를 식별하는 분석기입니다. 반드시 요청된 JSON만 출력하세요.",
                prompt: prompt,
                maximumTokens: min(1024, max(256, labels.count * 96))
            )
        } else if resolvedEngine == .appleFoundation || resolvedEngine == .appleTranslation || resolvedEngine == .azure || resolvedEngine == .localAPI {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
                // 비-LLM 번역 엔진(Apple 전용 번역/Azure/로컬 API) 사용 중 Apple Intelligence가 꺼져 있으면 화자 번호를 유지합니다.
                if resolvedEngine != .appleFoundation { return [:] }
                throw VideoLingoError.modelUnavailable("Apple Intelligence 언어 모델이 현재 사용 불가합니다.")
            }
            let session = LanguageModelSession(model: model, instructions: "문서의 화자를 식별하는 분석기입니다. 반드시 요청된 JSON만 출력하세요.")
            var value = ""
            let options = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: min(1024, max(256, labels.count * 96)))
            for try await partial in session.streamResponse(to: prompt, options: options) {
                value = partial.content
                onPartialText("화자 이름 분석 중 · \(value.count)자 응답")
            }
            response = value
        } else {
            let container = try await mlxContainer(modelID: modelID, modelsURL: modelsURL)
            let session = ChatSession(
                container,
                instructions: "Identify speakers from transcript evidence. Output valid JSON only.",
                generateParameters: GenerateParameters(
                    maxTokens: min(1024, max(256, labels.count * 96)),
                    temperature: 0.1,
                    topP: 0.9,
                    repetitionPenalty: 1.05,
                    repetitionContextSize: 64
                )
            )
            var value = ""
            for try await token in session.streamResponse(to: prompt + "\n/no_think") {
                value += token
                onPartialText("화자 이름 분석 중 · \(value.count)자 응답")
            }
            response = cleanMLXResponse(value)
        }
        return speakerMapping(from: response, labels: labels, transcripts: transcripts)
    }

    func translate(
        _ text: String,
        jobID: UUID,
        sourceLanguage: String?,
        targetLanguage: String,
        modelID: String,
        modelsURL: URL,
        previousContext: [String],
        previousTranslations: [String] = [],
        nextContext: [String],
        glossary: [GlossaryEntry],
        qualityMode: ProcessingQualityMode,
        externalServer: ExternalLLMClient.Configuration? = nil,
        options: ProcessingOptions? = nil,
        attempt: Int = 0,
        onPartialText: @escaping @Sendable (String) -> Void
    ) async throws -> TranslationOutput {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return TranslationOutput(text: "", qualityStatus: .good, qualityNotes: []) }
        if TranslationQualityValidator.isSameLanguage(sourceLanguage, targetLanguage) {
            translationFailureStreaks[jobID] = 0
            return TranslationOutput(
                text: trimmedText,
                qualityStatus: .good,
                qualityNotes: ["원문과 대상 언어가 같아 원문을 유지함"]
            )
        }

        let engine = options?.effectiveTranslationEngine ?? inferredEngine(for: modelID)
        switch engine {
        case .appleTranslation:
            let translated = try await AppleNativeTranslationEngine.shared.translate(
                trimmedText,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                onPartialText: onPartialText
            )
            translationFailureStreaks[jobID] = 0
            let aligned = TranslationQualityValidator.repairSpeakerLabelsIfAligned(source: trimmedText, translation: translated)
            let issues = TranslationQualityValidator.issues(
                source: trimmedText,
                translation: aligned,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                glossary: glossary
            )
            return TranslationOutput(
                text: aligned,
                qualityStatus: issues.isEmpty ? .good : .warning,
                qualityNotes: issues.isEmpty ? ["Apple 전용 번역(NMT)"] : issues
            )

        case .azure:
            let client = AzureTranslatorClient(
                apiKey: options?.azureAPIKey ?? "",
                region: options?.azureRegion ?? ""
            )
            let translated = try await client.translate(trimmedText, targetLanguage: targetLanguage)
            if !translated.isEmpty { onPartialText(translated) }
            translationFailureStreaks[jobID] = 0
            let aligned = TranslationQualityValidator.repairSpeakerLabelsIfAligned(source: trimmedText, translation: translated)
            let issues = TranslationQualityValidator.issues(
                source: trimmedText,
                translation: aligned,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                glossary: glossary
            )
            return TranslationOutput(
                text: aligned,
                qualityStatus: issues.isEmpty ? .good : .warning,
                qualityNotes: issues.isEmpty ? ["Azure Translator"] : issues
            )

        case .localAPI:
            let apiSettings = options?.localTranslationAPI ?? LocalTranslationAPISettings()
            let client = CustomLocalTranslatorClient(
                settings: apiSettings,
                apiKey: options?.localTranslationAPIKey ?? ""
            )
            let sourceCode = VideoLingoLanguageCatalog.whisperParameter(for: sourceLanguage)
            let translated = try await client.translate(trimmedText, source: sourceCode, target: targetLanguage)
            if !translated.isEmpty { onPartialText(translated) }
            translationFailureStreaks[jobID] = 0
            let aligned = TranslationQualityValidator.repairSpeakerLabelsIfAligned(source: trimmedText, translation: translated)
            let issues = TranslationQualityValidator.issues(
                source: trimmedText,
                translation: aligned,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                glossary: glossary
            )
            return TranslationOutput(
                text: aligned,
                qualityStatus: issues.isEmpty ? .good : .warning,
                qualityNotes: issues.isEmpty ? ["로컬 커스텀 번역 API"] : issues
            )

        case .managedLlama:
            let endpoint = options?.managedTranslationURL ?? ManagedRuntimeRole.translation.baseURL.appendingPathComponent("v1/chat/completions").absoluteString
            guard let managedConfig = ExternalLLMClient.Configuration(
                endpoint: endpoint,
                model: "local",
                apiKey: options?.managedTranslationAPIKey
            ) else {
                throw VideoLingoError.modelUnavailable("자체 llama.cpp 번역 서버 주소가 올바르지 않습니다.")
            }
            do {
                let draft = try await translateWithExternalServer(
                    trimmedText,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    externalServer: managedConfig,
                    previousContext: previousContext,
                    previousTranslations: previousTranslations,
                    nextContext: nextContext,
                    glossary: glossary,
                    onPartialText: onPartialText
                )
                translationFailureStreaks[jobID] = 0
                return try await finalizeTranslation(
                    source: trimmedText, draft: draft, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                    modelID: ProcessingOptions.externalServerModelID, modelsURL: modelsURL, glossary: glossary,
                    qualityMode: qualityMode, externalServer: managedConfig, onPartialText: onPartialText
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt == 0 && (!previousContext.isEmpty || !previousTranslations.isEmpty || !nextContext.isEmpty) {
                    return try await translate(
                        trimmedText,
                        jobID: jobID,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        modelID: modelID,
                        modelsURL: modelsURL,
                        previousContext: [],
                        previousTranslations: [],
                        nextContext: [],
                        glossary: glossary,
                        qualityMode: .fast,
                        externalServer: managedConfig,
                        options: options,
                        attempt: attempt + 1,
                        onPartialText: onPartialText
                    )
                }
                throw error
            }

        case .externalOpenAI:
            do {
                let draft = try await translateWithExternalServer(
                    trimmedText,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    externalServer: externalServer,
                    previousContext: previousContext,
                    previousTranslations: previousTranslations,
                    nextContext: nextContext,
                    glossary: glossary,
                    onPartialText: onPartialText
                )
                translationFailureStreaks[jobID] = 0
                return try await finalizeTranslation(
                    source: trimmedText, draft: draft, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                    modelID: modelID, modelsURL: modelsURL, glossary: glossary, qualityMode: qualityMode,
                    externalServer: externalServer, onPartialText: onPartialText
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt == 0 && (!previousContext.isEmpty || !previousTranslations.isEmpty || !nextContext.isEmpty) {
                    return try await translate(
                        trimmedText,
                        jobID: jobID,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        modelID: modelID,
                        modelsURL: modelsURL,
                        previousContext: [],
                        previousTranslations: [],
                        nextContext: [],
                        glossary: glossary,
                        qualityMode: .fast,
                        externalServer: externalServer,
                        options: options,
                        attempt: attempt + 1,
                        onPartialText: onPartialText
                    )
                }
                throw error
            }

        case .mlx:
            do {
                var draft = try await translateWithMLX(
                    trimmedText,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    modelID: modelID,
                    modelsURL: modelsURL,
                    previousContext: previousContext,
                    previousTranslations: previousTranslations,
                    nextContext: nextContext,
                    glossary: glossary,
                    onPartialText: onPartialText
                )
                if draft.isEmpty && attempt == 0 {
                    draft = try await translateWithMLX(
                        trimmedText,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        modelID: modelID,
                        modelsURL: modelsURL,
                        previousContext: [],
                        previousTranslations: [],
                        nextContext: [],
                        glossary: glossary,
                        onPartialText: onPartialText
                    )
                }
                guard !draft.isEmpty else {
                    return try skipSegment(jobID: jobID, note: "로컬 MLX 모델이 빈 번역을 반환해 이 구간을 건너뛰었습니다.")
                }
                translationFailureStreaks[jobID] = 0
                return try await finalizeTranslation(
                    source: trimmedText, draft: draft, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                    modelID: modelID, modelsURL: modelsURL, glossary: glossary, qualityMode: qualityMode,
                    externalServer: externalServer, onPartialText: onPartialText
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as VideoLingoError {
                throw error
            } catch {
                if attempt < 1 {
                    try await Task.sleep(for: .milliseconds(400))
                    return try await translate(
                        trimmedText,
                        jobID: jobID,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        modelID: modelID,
                        modelsURL: modelsURL,
                        previousContext: [],
                        previousTranslations: [],
                        nextContext: [],
                        glossary: glossary,
                        qualityMode: .fast,
                        externalServer: externalServer,
                        options: options,
                        attempt: attempt + 1,
                        onPartialText: onPartialText
                    )
                }
                return try skipSegment(jobID: jobID, note: "MLX 번역 실패 · \(error.localizedDescription)")
            }

        case .appleFoundation:
            break
        }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw VideoLingoError.modelUnavailable("Apple Intelligence 언어 모델이 현재 사용 불가합니다.")
        }
        // LanguageModelSession은 이전 요청의 문맥을 보존합니다. 긴 배치에서 세션을
        // 재사용하면 자막이 누적되어 모델 컨텍스트 한도를 넘으므로 청크마다 분리합니다.
        let source = languageName(sourceLanguage)
        let session = LanguageModelSession(model: model, instructions: """
            영상 자막을 \(source)에서 \(languageName(targetLanguage))로 번역하세요.
            PREVIOUS CONTEXT·PREVIOUS TRANSLATION·NEXT CONTEXT는 문맥·말투·용어 일관성 확인에만 사용하고 CURRENT SUBTITLE만 번역하세요.
            대괄호 안의 화자 라벨(예: [화자 1], [김민수], [진행자])은 번역하거나 제거하지 말고 각 화자의 줄 구분을 그대로 유지하세요.
            의미, 이름, 숫자, 존댓말과 말투를 보존하고 설명이나 따옴표를 추가하지 마세요.
            자연스럽고 간결한 번역문만 출력하세요.
            """)
        var translated = ""
        let prompt = TranslationContextBuilder.buildPrompt(
            text: trimmedText,
            previousContext: previousContext,
            previousTranslations: previousTranslations,
            nextContext: nextContext,
            glossary: glossary
        )
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0,
            maximumResponseTokens: TranslationContextBuilder.maxResponseTokens(for: trimmedText, backend: .appleFoundation)
        )
        do {
            for try await partial in session.streamResponse(to: prompt, options: options) {
                translated = TranslationTextSanitizer.cleanLLMOutput(partial.content, source: trimmedText)
                if !translated.isEmpty { onPartialText(translated) }
            }
            translationFailureStreaks[jobID] = 0
            return try await finalizeTranslation(
                source: trimmedText, draft: translated, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                modelID: modelID, modelsURL: modelsURL, glossary: glossary, qualityMode: qualityMode,
                onPartialText: onPartialText
            )
        } catch {
            return try await recoverFromTranslationFailure(
                error,
                text: trimmedText,
                jobID: jobID,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                modelID: modelID,
                modelsURL: modelsURL,
                previousContext: previousContext,
                previousTranslations: previousTranslations,
                nextContext: nextContext,
                glossary: glossary,
                qualityMode: qualityMode,
                attempt: attempt,
                onPartialText: onPartialText
            )
        }
    }

    /// Apple Foundation Models 실패를 **오류 타입으로** 분류해 복구합니다.
    /// 이전에는 localizedDescription을 영어 문자열로 매칭했는데, 시스템 언어가 한국어면
    /// 오류 설명도 한국어라 어떤 분기에도 걸리지 않고 그대로 throw되어 청크 하나의 실패가
    /// 작업 전체를 중단시켰습니다. 문자열은 로케일에 따라 달라지므로 타입으로만 판별합니다.
    private func recoverFromTranslationFailure(
        _ error: Error,
        text: String,
        jobID: UUID,
        sourceLanguage: String?,
        targetLanguage: String,
        modelID: String,
        modelsURL: URL,
        previousContext: [String],
        previousTranslations: [String],
        nextContext: [String],
        glossary: [GlossaryEntry],
        qualityMode: ProcessingQualityMode,
        attempt: Int,
        onPartialText: @escaping @Sendable (String) -> Void
    ) async throws -> TranslationOutput {
        if error is CancellationError { throw error }
        // 모델 자산을 못 쓰는 상태면 몇 번을 다시 시도해도 같은 실패가 반복됩니다.
        // 청크마다 8번씩 재시도하며 시간을 버리지 않고 바로 원인을 알립니다.
        if isModelAssetFailure(error) {
            translationFailureStreaks[jobID] = 0
            throw VideoLingoError.modelUnavailable(
                "Apple Intelligence 모델을 사용할 수 없습니다. 디스크 여유 공간을 확보한 뒤 시스템 설정에서 Apple Intelligence를 확인하거나, 설정에서 번역 모델을 Qwen으로 바꾸세요."
            )
        }
        let hasContext = !previousContext.isEmpty || !previousTranslations.isEmpty || !nextContext.isEmpty

        func retry(dropContext: Bool, delay: Duration?, downgrade: Bool) async throws -> TranslationOutput {
            if let delay { try await Task.sleep(for: delay) }
            return try await translate(
                text,
                jobID: jobID,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                modelID: modelID,
                modelsURL: modelsURL,
                previousContext: dropContext ? [] : previousContext,
                previousTranslations: dropContext ? [] : previousTranslations,
                nextContext: dropContext ? [] : nextContext,
                glossary: glossary,
                qualityMode: downgrade ? .fast : qualityMode,
                attempt: attempt + 1,
                onPartialText: onPartialText
            )
        }

        // 재시도해도 소용없는 의미적 실패는 원문을 남겨 두는 편이 사용자에게 유용합니다.
        func keepSource(_ note: String) -> TranslationOutput {
            translationFailureStreaks[jobID] = 0
            return TranslationOutput(text: text, qualityStatus: .warning, qualityNotes: [note])
        }

        guard let generation = error as? LanguageModelSession.GenerationError else {
            if attempt < 2 {
                return try await retry(dropContext: attempt >= 1, delay: .milliseconds(400), downgrade: attempt >= 1)
            }
            return try skipSegment(jobID: jobID, note: "번역 실패 · \(diagnosticDescription(error))")
        }

        switch generation {
        case .exceededContextWindowSize:
            if hasContext || attempt < 2 { return try await retry(dropContext: true, delay: nil, downgrade: true) }
            return try skipSegment(jobID: jobID, note: "문맥 한도를 넘어 이 구간을 번역하지 못했습니다.")
        case .unsupportedLanguageOrLocale:
            if hasContext { return try await retry(dropContext: true, delay: nil, downgrade: true) }
            return keepSource("Apple 언어 모델이 이 구간의 언어를 지원하지 않아 원문을 보존했습니다.")
        case .guardrailViolation, .refusal:
            return keepSource("Apple 안전 필터로 자동 번역하지 못해 원문을 보존했습니다.")
        case .rateLimited, .concurrentRequests, .assetsUnavailable:
            // 일시적 실패이므로 지수 백오프로 기다렸다가 같은 청크를 다시 시도합니다.
            if attempt < 4 {
                return try await retry(dropContext: false, delay: .milliseconds(500 * (1 << attempt)), downgrade: false)
            }
            return try skipSegment(jobID: jobID, note: "모델이 계속 응답하지 못해 이 구간을 건너뛰었습니다.")
        case .decodingFailure, .unsupportedGuide:
            if attempt < 2 { return try await retry(dropContext: true, delay: .milliseconds(200), downgrade: true) }
            return try skipSegment(jobID: jobID, note: "모델 응답을 해석하지 못해 이 구간을 건너뛰었습니다.")
        @unknown default:
            if attempt < 2 { return try await retry(dropContext: true, delay: .milliseconds(400), downgrade: true) }
            return try skipSegment(jobID: jobID, note: "번역 실패 · \(diagnosticDescription(error))")
        }
    }

    /// Apple Intelligence 모델 자산 자체를 쓸 수 없는 상태인지 판별합니다.
    /// GenerationError가 NSError로 브리징돼 오는 경우가 있어(실측 확인) 타입 캐스팅만으로는 분류할 수 없고,
    /// 하위 오류(ModelManagerError)까지 훑어야 원인을 알 수 있습니다. 이 경우 재시도는 의미가 없습니다.
    private func isModelAssetFailure(_ error: Error) -> Bool {
        var queue: [NSError] = [error as NSError]
        var inspected = 0
        while !queue.isEmpty, inspected < 12 {
            let current = queue.removeFirst()
            inspected += 1
            if current.domain.localizedCaseInsensitiveContains("ModelManager") { return true }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                queue.append(underlying)
            }
            if let multiple = current.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                queue.append(contentsOf: multiple)
            }
        }
        return false
    }

    /// 실패 원인을 특정할 수 있도록 오류의 실제 타입과 케이스를 남깁니다.
    /// localizedDescription만으로는 어떤 GenerationError인지 알 수 없어 진단이 불가능했습니다.
    private func diagnosticDescription(_ error: Error) -> String {
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return "\(type(of: error)) · \(error.localizedDescription)"
        }
        let name: String
        switch generation {
        case .exceededContextWindowSize: name = "exceededContextWindowSize"
        case .assetsUnavailable: name = "assetsUnavailable"
        case .guardrailViolation: name = "guardrailViolation"
        case .unsupportedGuide: name = "unsupportedGuide"
        case .unsupportedLanguageOrLocale: name = "unsupportedLanguageOrLocale"
        case .decodingFailure: name = "decodingFailure"
        case .rateLimited: name = "rateLimited"
        case .concurrentRequests: name = "concurrentRequests"
        case .refusal: name = "refusal"
        @unknown default: name = "unknown"
        }
        return "GenerationError.\(name) · \(generation.localizedDescription)"
    }

    /// 회복하지 못한 구간은 비워 두어 '번역 대기 중'으로 남깁니다. 기존 미번역 재시도 기능이
    /// 나중에 이어서 처리할 수 있고, 작업 전체가 죽지 않습니다.
    /// 다만 연속 실패가 임계치를 넘으면 시스템 문제이므로 조용히 빈 결과를 쌓지 않고 실패시킵니다.
    private func skipSegment(jobID: UUID, note: String) throws -> TranslationOutput {
        let streak = (translationFailureStreaks[jobID] ?? 0) + 1
        translationFailureStreaks[jobID] = streak
        if streak >= 8 {
            translationFailureStreaks[jobID] = 0
            throw VideoLingoError.modelUnavailable("번역이 연속 8회 실패했습니다. \(note)")
        }
        return TranslationOutput(text: "", qualityStatus: .warning, qualityNotes: [note])
    }

    /// OpenAI 호환 외부 서버로 한 청크를 번역합니다.
    private func translateWithExternalServer(
        _ text: String,
        sourceLanguage: String?,
        targetLanguage: String,
        externalServer: ExternalLLMClient.Configuration?,
        previousContext: [String],
        previousTranslations: [String],
        nextContext: [String],
        glossary: [GlossaryEntry],
        onPartialText: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let externalServer else {
            throw VideoLingoError.modelUnavailable("외부 LLM 서버 주소와 모델 이름을 설정에서 입력하세요.")
        }
        let client = ExternalLLMClient(configuration: externalServer)
        let instructions = """
            영상 자막을 \(languageName(sourceLanguage))에서 \(languageName(targetLanguage))로 번역하세요.
            PREVIOUS CONTEXT·PREVIOUS TRANSLATION·NEXT CONTEXT는 문맥·말투·용어 일관성 확인에만 사용하고 CURRENT SUBTITLE만 번역하세요.
            대괄호 안의 화자 라벨(예: [화자 1], [김민수])은 번역하거나 제거하지 말고 각 화자의 줄 구분을 그대로 유지하세요.
            의미, 이름, 숫자, 존댓말과 말투를 보존하고 설명이나 따옴표를 추가하지 마세요.
            자연스럽고 간결한 번역문만 출력하세요.
            """
        let prompt = TranslationContextBuilder.buildPrompt(
            text: text,
            previousContext: previousContext,
            previousTranslations: previousTranslations,
            nextContext: nextContext,
            glossary: glossary
        )
        let value = try await client.complete(
            instructions: instructions,
            prompt: prompt,
            maximumTokens: TranslationContextBuilder.maxResponseTokens(for: text, backend: .externalServer)
        )
        let cleaned = TranslationTextSanitizer.cleanLLMOutput(value, source: text)
        if !cleaned.isEmpty { onPartialText(cleaned) }
        return cleaned
    }

    private func translateWithMLX(
        _ text: String,
        sourceLanguage: String?,
        targetLanguage: String,
        modelID: String,
        modelsURL: URL,
        previousContext: [String],
        previousTranslations: [String],
        nextContext: [String],
        glossary: [GlossaryEntry],
        onPartialText: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let container = try await mlxContainer(modelID: modelID, modelsURL: modelsURL)
        let source = languageName(sourceLanguage)
        let session = ChatSession(
            container,
            instructions: """
                Translate video subtitles from \(source) to \(languageName(targetLanguage)).
                Use PREVIOUS CONTEXT, PREVIOUS TRANSLATION, and NEXT CONTEXT only to maintain continuity, tone, honorifics, and terminology; translate only CURRENT SUBTITLE.
                Preserve every bracketed speaker label exactly (for example [화자 1], [Kim], or [Host]) and keep each speaker on a separate line.
                Preserve meaning, names, numbers, politeness, and tone. Be natural and concise.
                Return only the translated subtitle with the original speaker labels; add no quotes, notes, or explanations.
                """,
            generateParameters: GenerateParameters(
                maxTokens: TranslationContextBuilder.maxResponseTokens(for: text, backend: .mlx),
                temperature: 0.1,
                topP: 0.9,
                repetitionPenalty: 1.05,
                repetitionContextSize: 64
            )
        )
        var response = ""
        let prompt = TranslationContextBuilder.buildPrompt(
            text: text,
            previousContext: previousContext,
            previousTranslations: previousTranslations,
            nextContext: nextContext,
            glossary: glossary
        ) + "\n/no_think"
        for try await token in session.streamResponse(to: prompt) {
            response += token
            let cleaned = TranslationTextSanitizer.cleanLLMOutput(response, source: text)
            if !cleaned.isEmpty { onPartialText(cleaned) }
        }
        return TranslationTextSanitizer.cleanLLMOutput(response, source: text)
    }

    private func cleanMLXResponse(_ value: String) -> String {
        TranslationTextSanitizer.cleanLLMOutput(value)
    }

    private func mlxContainer(modelID: String, modelsURL: URL) async throws -> ModelContainer {
        if let loaded = mlxContainers[modelID] { return loaded }
        let hub = HubApi(downloadBase: modelsURL)
        let configuration = ModelConfiguration(id: modelID)
        let loaded = try await LLMModelFactory.shared.loadContainer(hub: hub, configuration: configuration)
        mlxContainers[modelID] = loaded
        let folder = configuration.modelDirectory(hub: hub)
        ModelManifestWriter.save(kind: .translation, modelID: modelID, folder: folder, modelsURL: modelsURL)
        return loaded
    }

    private func speakerEvidence(from transcripts: [TranscriptSegment], labels: [String]) -> String {
        let ordered = transcripts.sorted { $0.chunkIndex < $1.chunkIndex }
        var samples: [String: [String]] = Dictionary(uniqueKeysWithValues: labels.map { ($0, []) })
        for segment in ordered {
            for line in segment.text.split(separator: "\n").map(String.init) {
                guard let label = labels.first(where: { line.contains("[\($0)]") }),
                      samples[label, default: []].joined().count < 2_400 else { continue }
                samples[label, default: []].append(line)
            }
        }
        let perSpeaker = labels.map { label in
            "--- \(label) 발화 ---\n" + samples[label, default: []].joined(separator: "\n")
        }.joined(separator: "\n")
        let chronology = ordered.map(\.text).joined(separator: "\n")
        return perSpeaker + "\n--- 대화 순서 표본 ---\n" + String(chronology.prefix(8_000))
    }

    private func speakerMapping(
        from response: String,
        labels: [String],
        transcripts: [TranscriptSegment]
    ) -> [String: String] {
        let json = jsonObject(in: response)
        let decoded = json.flatMap { try? JSONDecoder().decode(SpeakerResolutionResponse.self, from: Data($0.utf8)) }
        var mapping: [String: String] = [:]
        var usedNames = Set<String>()
        for speaker in decoded?.speakers ?? [] where labels.contains(speaker.label) {
            var name = SpeakerLabelRewriter.sanitizedSpeakerName(speaker.name)
            guard !name.isEmpty else { continue }
            if usedNames.contains(name) { name = "\(name) \(mapping.count + 1)" }
            mapping[speaker.label] = name
            usedNames.insert(name)
        }
        for label in labels where mapping[label] == nil {
            let fallback = inferredFallback(for: label, transcripts: transcripts, isFirst: mapping.isEmpty)
            mapping[label] = usedNames.contains(fallback) ? "\(fallback) \(mapping.count + 1)" : fallback
            usedNames.insert(mapping[label]!)
        }
        return mapping
    }

    private func inferredFallback(for label: String, transcripts: [TranscriptSegment], isFirst: Bool) -> String {
        let utterances = transcripts.flatMap { $0.text.split(separator: "\n").map(String.init) }
            .filter { $0.contains("[\(label)]") }
        let questionCount = utterances.filter { $0.contains("?") || $0.contains("까요") || $0.contains("습니까") }.count
        if questionCount >= max(2, utterances.count / 3) { return "질문자" }
        if isFirst { return "주요 화자" }
        return "참여자 \(label.split(separator: " ").last ?? "")"
    }

    private func jsonObject(in response: String) -> String? {
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start <= end else { return nil }
        return String(response[start...end])
    }

    private func finalizeTranslation(
        source: String,
        draft: String,
        sourceLanguage: String?,
        targetLanguage: String,
        modelID: String,
        modelsURL: URL,
        glossary: [GlossaryEntry],
        qualityMode: ProcessingQualityMode,
        externalServer: ExternalLLMClient.Configuration? = nil,
        onPartialText: @escaping @Sendable (String) -> Void
    ) async throws -> TranslationOutput {
        // 줄 수가 맞으면 화자 라벨 누락·오번역을 추가 LLM 호출 없이 즉시 복원합니다.
        let alignedDraft = TranslationQualityValidator.repairSpeakerLabelsIfAligned(source: source, translation: draft)
        let draftIssues = TranslationQualityValidator.issues(
            source: source,
            translation: alignedDraft,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            glossary: glossary
        )
        var reviewReasons = draftIssues
        if qualityMode == .maximum && reviewReasons.isEmpty {
            reviewReasons.append("최고 품질 모드의 의미·말투 2차 검수")
        }
        guard qualityMode != .fast, !reviewReasons.isEmpty else {
            return TranslationOutput(
                text: alignedDraft,
                qualityStatus: draftIssues.isEmpty ? .good : .warning,
                qualityNotes: draftIssues
            )
        }
        let filteredGlossary = TranslationContextBuilder.relevantGlossary(glossary, for: source)
        let glossarySection = filteredGlossary.isEmpty
            ? ""
            : "\n\nREQUIRED GLOSSARY:\n" + filteredGlossary.map { "\($0.source) => \($0.target)" }.joined(separator: "\n")
        let prompt = """
            Review and repair this video subtitle translation.
            Source language: \(languageName(sourceLanguage))
            Target language: \(languageName(targetLanguage))
            Detected issues: \(reviewReasons.joined(separator: "; "))
            Preserve every bracketed speaker label, number, date, unit, name, line order, and required glossary term.
            Do not add explanations. Return only the corrected target-language subtitle.

            SOURCE:
            \(source)

            DRAFT:
            \(alignedDraft)\(glossarySection)
            """
        let repairedRaw: String
        do {
            if modelID == "apple-foundation-models" {
                let model = SystemLanguageModel.default
                guard case .available = model.availability else {
                    return TranslationOutput(text: alignedDraft, qualityStatus: draftIssues.isEmpty ? .good : .warning, qualityNotes: draftIssues + ["검수 모델 사용 불가"])
                }
                let session = LanguageModelSession(model: model, instructions: "영상 자막 번역 검수기입니다. 수정된 자막만 출력하세요.")
                var value = ""
                for try await partial in session.streamResponse(
                    to: prompt,
                    options: GenerationOptions(
                        sampling: .greedy,
                        temperature: 0,
                        maximumResponseTokens: TranslationContextBuilder.maxResponseTokens(
                            for: source,
                            referenceText: alignedDraft,
                            backend: .appleFoundation
                        )
                    )
                ) {
                    value = TranslationTextSanitizer.cleanLLMOutput(partial.content, source: source)
                    if !value.isEmpty { onPartialText("2차 검수 · \(value)") }
                }
                repairedRaw = value
            } else if modelID == ProcessingOptions.externalServerModelID {
                guard let externalServer else {
                    return TranslationOutput(text: alignedDraft, qualityStatus: draftIssues.isEmpty ? .good : .warning, qualityNotes: draftIssues + ["검수 서버 설정 없음"])
                }
                let client = ExternalLLMClient(configuration: externalServer)
                let value = try await client.complete(
                    instructions: "You review video subtitle translations. Return only the corrected subtitle.",
                    prompt: prompt,
                    maximumTokens: TranslationContextBuilder.maxResponseTokens(
                        for: source,
                        referenceText: alignedDraft,
                        backend: .externalServer
                    )
                )
                let cleaned = TranslationTextSanitizer.cleanLLMOutput(value, source: source)
                if !cleaned.isEmpty { onPartialText("2차 검수 · \(cleaned)") }
                repairedRaw = cleaned
            } else {
                let container = try await mlxContainer(modelID: modelID, modelsURL: modelsURL)
                let session = ChatSession(
                    container,
                    instructions: "Repair subtitle translation and return only the corrected subtitle.",
                    generateParameters: GenerateParameters(
                        maxTokens: TranslationContextBuilder.maxResponseTokens(
                            for: source,
                            referenceText: alignedDraft,
                            backend: .mlx
                        ),
                        temperature: 0.05
                    )
                )
                var value = ""
                for try await token in session.streamResponse(to: prompt + "\n/no_think") {
                    value += token
                    let cleaned = TranslationTextSanitizer.cleanLLMOutput(value, source: source)
                    if !cleaned.isEmpty { onPartialText("2차 검수 · \(cleaned)") }
                }
                repairedRaw = TranslationTextSanitizer.cleanLLMOutput(value, source: source)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 2차 검수 실패로 이미 생성된 초안을 잃지 않도록 안전하게 초안을 유지합니다.
            return TranslationOutput(
                text: alignedDraft,
                qualityStatus: draftIssues.isEmpty ? .good : .warning,
                qualityNotes: draftIssues + ["2차 검수 생략(초안 유지)"]
            )
        }
        let repaired = TranslationQualityValidator.repairSpeakerLabelsIfAligned(source: source, translation: repairedRaw)
        let repairedIssues = TranslationQualityValidator.issues(
            source: source,
            translation: repaired,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            glossary: glossary
        )
        let adoptRepaired = TranslationQualityValidator.prefersRepaired(
            draft: alignedDraft,
            repaired: repaired,
            draftIssues: draftIssues,
            repairedIssues: repairedIssues,
            qualityMode: qualityMode
        )
        let finalText = adoptRepaired ? repaired : alignedDraft
        let remaining = adoptRepaired ? repairedIssues : draftIssues
        let outcomeNote: String
        if adoptRepaired {
            outcomeNote = remaining.isEmpty
                ? "LLM 2차 검수 완료"
                : "검수 후에도 확인 필요: \(remaining.joined(separator: ", "))"
        } else {
            outcomeNote = "2차 검수 결과가 개선되지 않아 초안 유지"
        }
        return TranslationOutput(
            text: finalText,
            qualityStatus: remaining.isEmpty ? .reviewed : .warning,
            qualityNotes: reviewReasons + [outcomeNote]
        )
    }

    private func inferredEngine(for modelID: String) -> TranslationEngineKind {
        if modelID == "apple-foundation-models" { return .appleFoundation }
        if modelID == ProcessingOptions.externalServerModelID { return .externalOpenAI }
        if modelID == ProcessingOptions.appleTranslationModelID { return .appleTranslation }
        if modelID == ProcessingOptions.azureTranslationModelID { return .azure }
        if modelID == ProcessingOptions.localAPITranslationModelID { return .localAPI }
        if modelID.hasPrefix(ProcessingOptions.managedLlamaModelPrefix) { return .managedLlama }
        return .mlx
    }

    private func languageName(_ code: String?) -> String {
        VideoLingoLanguageCatalog.englishName(for: code)
    }
}

final class LocalTTSEngine: @unchecked Sendable {
    private var kit: TTSKit?

    func synthesize(_ text: String, languageCode: String, outputURL: URL, modelsURL: URL) async throws {
        if kit == nil {
            kit = try await TTSKit(downloadBase: modelsURL)
            if let folder = kit?.modelFolder {
                ModelManifestWriter.save(kind: .tts, modelID: "qwen3-tts-0.6b", folder: folder, modelsURL: modelsURL)
            }
        }
        guard let kit else { throw VideoLingoError.modelUnavailable("TTSKit 초기화 실패") }
        let result = try await kit.generate(
            text: text,
            voice: voice(for: languageCode),
            language: languageName(for: languageCode)
        )
        _ = try await AudioOutput.saveAudio(
            result.audio,
            toFolder: outputURL.deletingLastPathComponent(),
            filename: outputURL.lastPathComponent,
            sampleRate: result.sampleRate,
            format: .m4a
        )
    }

    private func languageName(for code: String) -> String {
        switch code {
        case "ko": "korean"
        case "ja": "japanese"
        case "zh": "chinese"
        case "de": "german"
        case "fr": "french"
        case "ru": "russian"
        case "pt": "portuguese"
        case "es": "spanish"
        case "it": "italian"
        default: "english"
        }
    }

    private func voice(for code: String) -> String {
        switch code {
        case "ko": "sohee"
        case "ja": "ono-anna"
        case "zh": "vivian"
        default: "ryan"
        }
    }
}

private enum ModelManifestWriter {
    static func save(kind: ManagedModelKind, modelID: String, folder: URL, modelsURL: URL) {
        let record = ManagedModelRecord(
            kind: kind,
            modelID: modelID,
            state: .downloaded,
            progress: 1,
            localURL: folder,
            sizeInBytes: folderSize(folder)
        )
        let key = "\(kind.rawValue)-\(modelID)".replacingOccurrences(of: "/", with: "-")
        let directory = modelsURL.appending(path: "Manifests", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try WireCodec.encode(record).write(to: directory.appending(path: "\(key).json"), options: .atomic)
        } catch {
            // 모델 자체는 정상적으로 사용할 수 있으므로 관리용 메타데이터 기록 실패는 무시합니다.
        }
    }

    private static func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}
