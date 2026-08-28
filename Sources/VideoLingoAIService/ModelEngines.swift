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
            retryOptions.temperature = qualityMode == .maximum ? 0.2 : 0.0
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
            if (initialText.isEmpty && !retryText.isEmpty) || transcriptionScore(retryResults) > initialScore {
                results = retryResults
                qualityNotes.append("재시도 결과 채택")
            } else {
                qualityNotes.append("최초 결과 유지")
            }
        }
        let selection = segmentSelection(results)
        let rawText = extractedText(results, selection: selection)
        let filteredText = TranscriptTextSanitizer.cleanWhisperText(rawText)
        let diarized = try await diarizedOutput(
            audioURL: audioURL,
            results: results,
            modelsURL: modelsURL
        )
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
                && segment.noSpeechProb <= 0.6
                && segment.compressionRatio <= 2.4
                && segment.avgLogprob >= -1.2
        }
        if !strict.isEmpty { return SegmentSelection(segments: strict, usedRelaxedFilter: false) }

        let relaxed = segments.filter { segment in
            let text = TranscriptTextSanitizer.cleanWhisperText(segment.text)
            return !text.isEmpty
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
        return results.map(\.text).joined(separator: " ")
    }

    private func containsPotentialSpeech(_ results: [TranscriptionResult]) -> Bool {
        if results.contains(where: { !TranscriptTextSanitizer.cleanWhisperText($0.text).isEmpty }) { return true }
        return results.flatMap(\.segments).contains { segment in
            !TranscriptTextSanitizer.cleanWhisperText(segment.text).isEmpty && segment.noSpeechProb <= 0.9
        }
    }

    private func transcriptionScore(_ results: [TranscriptionResult]) -> Double {
        let segments = results.flatMap(\.segments).filter {
            !TranscriptTextSanitizer.cleanWhisperText($0.text).isEmpty && $0.noSpeechProb <= 0.6 && $0.compressionRatio <= 2.4
        }
        guard !segments.isEmpty else { return 0 }
        return segments.map { exp(Double($0.avgLogprob)) }.reduce(0, +) / Double(segments.count)
    }

    private func diarizedOutput(
        audioURL: URL,
        results: [TranscriptionResult],
        modelsURL: URL
    ) async throws -> DiarizedOutput {
        guard results.contains(where: { !$0.segments.isEmpty }) else {
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
        let aligned = diarization.addSpeakerInfo(to: results, strategy: .subsegment)
            .flatMap { $0 }
            .filter { segment in
                guard let transcription = segment.transcription else { return false }
                return transcription.noSpeechProb <= 0.6
                    && transcription.compressionRatio <= 2.4
                    && transcription.avgLogprob >= -1.2
                    && !TranscriptTextSanitizer.cleanWhisperText(segment.text).isEmpty
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
    private var translationFailureStreak = 0

    func resolveSpeakerNames(
        in transcripts: [TranscriptSegment],
        labels overrideLabels: [String]? = nil,
        sourceLanguage: String?,
        modelID: String,
        modelsURL: URL,
        onPartialText: @escaping @Sendable (String) -> Void
    ) async throws -> [String: String] {
        // 재분석에서는 이미 이름이 적용된 라벨을 그대로 다시 판별하도록 외부에서 목록을 넘깁니다.
        let labels = overrideLabels ?? SpeakerLabelRewriter.labels(in: transcripts)
        guard !labels.isEmpty else { return [:] }
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
        if modelID == "apple-foundation-models" {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
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
        nextContext: [String],
        glossary: [GlossaryEntry],
        qualityMode: ProcessingQualityMode,
        attempt: Int = 0,
        onPartialText: @escaping @Sendable (String) -> Void
    ) async throws -> TranslationOutput {
        guard !text.isEmpty else { return TranslationOutput(text: "", qualityStatus: .good, qualityNotes: []) }
        if modelID != "apple-foundation-models" {
            let draft = try await translateWithMLX(
                text,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                modelID: modelID,
                modelsURL: modelsURL,
                previousContext: previousContext,
                nextContext: nextContext,
                glossary: glossary,
                onPartialText: onPartialText
            )
            return try await finalizeTranslation(
                source: text, draft: draft, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                modelID: modelID, modelsURL: modelsURL, glossary: glossary, qualityMode: qualityMode,
                onPartialText: onPartialText
            )
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
            이전 문장은 문맥 확인에만 사용하고 CURRENT SUBTITLE만 번역하세요.
            대괄호 안의 화자 라벨(예: [화자 1], [김민수], [진행자])은 번역하거나 제거하지 말고 각 화자의 줄 구분을 그대로 유지하세요.
            의미, 이름, 숫자, 존댓말과 말투를 보존하고 설명이나 따옴표를 추가하지 마세요.
            자연스럽고 간결한 번역문만 출력하세요.
            """)
        var translated = ""
        let prompt = translationPrompt(text: text, previousContext: previousContext, nextContext: nextContext, glossary: glossary)
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0,
            maximumResponseTokens: min(512, max(64, text.count * 2))
        )
        do {
            for try await partial in session.streamResponse(to: prompt, options: options) {
                translated = partial.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !translated.isEmpty { onPartialText(translated) }
            }
            translationFailureStreak = 0
            return try await finalizeTranslation(
                source: text, draft: translated, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                modelID: modelID, modelsURL: modelsURL, glossary: glossary, qualityMode: qualityMode,
                onPartialText: onPartialText
            )
        } catch {
            return try await recoverFromTranslationFailure(
                error,
                text: text,
                jobID: jobID,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                modelID: modelID,
                modelsURL: modelsURL,
                previousContext: previousContext,
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
        nextContext: [String],
        glossary: [GlossaryEntry],
        qualityMode: ProcessingQualityMode,
        attempt: Int,
        onPartialText: @escaping @Sendable (String) -> Void
    ) async throws -> TranslationOutput {
        if error is CancellationError { throw error }
        let hasContext = !previousContext.isEmpty || !nextContext.isEmpty

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
                nextContext: dropContext ? [] : nextContext,
                glossary: glossary,
                qualityMode: downgrade ? .fast : qualityMode,
                attempt: attempt + 1,
                onPartialText: onPartialText
            )
        }

        // 재시도해도 소용없는 의미적 실패는 원문을 남겨 두는 편이 사용자에게 유용합니다.
        func keepSource(_ note: String) -> TranslationOutput {
            translationFailureStreak = 0
            return TranslationOutput(text: text, qualityStatus: .warning, qualityNotes: [note])
        }

        guard let generation = error as? LanguageModelSession.GenerationError else {
            if attempt < 2 {
                return try await retry(dropContext: attempt >= 1, delay: .milliseconds(400), downgrade: attempt >= 1)
            }
            return try skipSegment(note: "번역 실패 · \(diagnosticDescription(error))")
        }

        switch generation {
        case .exceededContextWindowSize:
            if hasContext || attempt < 2 { return try await retry(dropContext: true, delay: nil, downgrade: true) }
            return try skipSegment(note: "문맥 한도를 넘어 이 구간을 번역하지 못했습니다.")
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
            return try skipSegment(note: "모델이 계속 응답하지 못해 이 구간을 건너뛰었습니다.")
        case .decodingFailure, .unsupportedGuide:
            if attempt < 2 { return try await retry(dropContext: true, delay: .milliseconds(200), downgrade: true) }
            return try skipSegment(note: "모델 응답을 해석하지 못해 이 구간을 건너뛰었습니다.")
        @unknown default:
            if attempt < 2 { return try await retry(dropContext: true, delay: .milliseconds(400), downgrade: true) }
            return try skipSegment(note: "번역 실패 · \(diagnosticDescription(error))")
        }
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
    private func skipSegment(note: String) throws -> TranslationOutput {
        translationFailureStreak += 1
        if translationFailureStreak >= 8 {
            translationFailureStreak = 0
            throw VideoLingoError.modelUnavailable("번역이 연속 8회 실패했습니다. \(note)")
        }
        return TranslationOutput(text: "", qualityStatus: .warning, qualityNotes: [note])
    }

    private func translateWithMLX(
        _ text: String,
        sourceLanguage: String?,
        targetLanguage: String,
        modelID: String,
        modelsURL: URL,
        previousContext: [String],
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
                Use PREVIOUS CONTEXT only to understand continuity and translate only CURRENT SUBTITLE.
                Preserve every bracketed speaker label exactly (for example [화자 1], [Kim], or [Host]) and keep each speaker on a separate line.
                Preserve meaning, names, numbers, politeness, and tone. Be natural and concise.
                Return only the translated subtitle with the original speaker labels; add no quotes, notes, or explanations.
                """,
            generateParameters: GenerateParameters(
                maxTokens: min(512, max(64, text.count * 2)),
                temperature: 0.1,
                topP: 0.9,
                repetitionPenalty: 1.05,
                repetitionContextSize: 64
            )
        )
        var response = ""
        let prompt = translationPrompt(text: text, previousContext: previousContext, nextContext: nextContext, glossary: glossary) + "\n/no_think"
        for try await token in session.streamResponse(to: prompt) {
            response += token
            let cleaned = cleanMLXResponse(response)
            if !cleaned.isEmpty { onPartialText(cleaned) }
        }
        return cleanMLXResponse(response)
    }

    private func cleanMLXResponse(_ value: String) -> String {
        var text = value
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        return text
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        onPartialText: @escaping @Sendable (String) -> Void
    ) async throws -> TranslationOutput {
        var issues = translationIssues(source: source, translation: draft, glossary: glossary)
        if qualityMode == .maximum && issues.isEmpty { issues.append("최고 품질 모드의 의미·말투 2차 검수") }
        guard qualityMode != .fast, !issues.isEmpty else {
            return TranslationOutput(text: draft, qualityStatus: issues.isEmpty ? .good : .warning, qualityNotes: issues)
        }
        let prompt = """
            Review and repair this video subtitle translation.
            Source language: \(languageName(sourceLanguage))
            Target language: \(languageName(targetLanguage))
            Detected issues: \(issues.joined(separator: "; "))
            Preserve every bracketed speaker label, number, date, unit, name, line order, and required glossary term.
            Do not add explanations. Return only the corrected target-language subtitle.

            SOURCE:
            \(source)

            DRAFT:
            \(draft)
            """
        let repaired: String
        if modelID == "apple-foundation-models" {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
                return TranslationOutput(text: draft, qualityStatus: .warning, qualityNotes: issues + ["검수 모델 사용 불가"])
            }
            let session = LanguageModelSession(model: model, instructions: "영상 자막 번역 검수기입니다. 수정된 자막만 출력하세요.")
            var value = ""
            for try await partial in session.streamResponse(
                to: prompt,
                options: GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: min(512, max(64, draft.count * 2)))
            ) {
                value = partial.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { onPartialText("2차 검수 · \(value)") }
            }
            repaired = value
        } else {
            let container = try await mlxContainer(modelID: modelID, modelsURL: modelsURL)
            let session = ChatSession(
                container,
                instructions: "Repair subtitle translation and return only the corrected subtitle.",
                generateParameters: GenerateParameters(maxTokens: min(512, max(64, draft.count * 2)), temperature: 0.05)
            )
            var value = ""
            for try await token in session.streamResponse(to: prompt + "\n/no_think") {
                value += token
                let cleaned = cleanMLXResponse(value)
                if !cleaned.isEmpty { onPartialText("2차 검수 · \(cleaned)") }
            }
            repaired = cleanMLXResponse(value)
        }
        let finalText = repaired.isEmpty ? draft : repaired
        let remaining = translationIssues(source: source, translation: finalText, glossary: glossary)
        return TranslationOutput(
            text: finalText,
            qualityStatus: remaining.isEmpty ? .reviewed : .warning,
            qualityNotes: issues + (remaining.isEmpty ? ["LLM 2차 검수 완료"] : ["검수 후에도 확인 필요: \(remaining.joined(separator: ", "))"])
        )
    }

    private func translationIssues(source: String, translation: String, glossary: [GlossaryEntry]) -> [String] {
        var issues: [String] = []
        let labels = matches(pattern: #"\[[^\]\n]+\]"#, in: source)
        if labels.contains(where: { !translation.contains($0) }) { issues.append("화자 라벨 누락") }
        let numbers = matches(pattern: #"\d+(?:[.,:]\d+)*"#, in: source)
        if numbers.contains(where: { !translation.contains($0) }) { issues.append("숫자·시간·단위 누락 가능성") }
        let missingTerms = glossary.filter {
            source.localizedCaseInsensitiveContains($0.source) && !translation.localizedCaseInsensitiveContains($0.target)
        }
        if !missingTerms.isEmpty { issues.append("필수 용어 누락: \(missingTerms.map(\.source).joined(separator: ", "))") }
        if !source.isEmpty && (translation.count < max(1, source.count / 8) || translation.count > source.count * 5) {
            issues.append("번역 길이 이상")
        }
        return issues
    }

    private func matches(pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private func translationPrompt(text: String, previousContext: [String], nextContext: [String], glossary: [GlossaryEntry]) -> String {
        let context = previousContext.isEmpty
            ? "(none)"
            : previousContext.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let following = nextContext.isEmpty ? "(none)" : nextContext.joined(separator: "\n")
        let terms = glossary.isEmpty ? "(none)" : glossary.map { "\($0.source) => \($0.target)" }.joined(separator: "\n")
        return """
            PREVIOUS CONTEXT:
            \(context)

            CURRENT SUBTITLE:
            \(text)

            NEXT CONTEXT (understand only; do not translate):
            \(following)

            REQUIRED GLOSSARY:
            \(terms)
            """
    }

    private func languageName(_ code: String?) -> String {
        switch code?.lowercased() {
        case "ko": "Korean"
        case "ja": "Japanese"
        case "zh": "Chinese"
        case "en": "English"
        case "es": "Spanish"
        case "fr": "French"
        case "de": "German"
        case "pt": "Portuguese"
        case "it": "Italian"
        case "ru": "Russian"
        case .some(let value): value
        case nil: "the automatically detected source language"
        }
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
