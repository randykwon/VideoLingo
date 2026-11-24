import AVFoundation
import Foundation
import Speech
import Translation
import VideoLingoCore

/// AVFoundation을 이용해 m4a 등 오디오 청크를 whisper-server가 바로 인식할 수 있는 16kHz 모노 16-bit PCM WAV로 변환합니다.
enum AudioWAVConverter {
    static func wavData(from audioURL: URL) async throws -> Data {
        let asset = AVURLAsset(url: audioURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw VideoLingoError.mediaHasNoAudio }
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VideoLingoError.modelUnavailable("오디오 PCM 변환 리더를 구성하지 못했습니다.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? VideoLingoError.modelUnavailable("오디오 파일을 읽지 못했습니다.")
        }

        var pcm = Data()
        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            )
            if status == kCMBlockBufferNoErr, let pointer, length > 0 {
                pcm.append(UnsafeBufferPointer(start: pointer, count: length))
            }
        }
        if reader.status == .failed {
            throw reader.error ?? VideoLingoError.modelUnavailable("오디오 PCM 변환에 실패했습니다.")
        }
        return ManagedWhisperClient.wavData(pcm16Mono: pcm, sampleRate: 16_000)
    }
}

/// Apple 온디바이스 SFSpeechRecognizer를 이용한 파일 기반 STT 엔진입니다.
enum AppleSpeechFileSTTEngine {
    static func transcribe(
        audioURL: URL,
        language: String?,
        onPartialText: @escaping @Sendable (String) -> Void
    ) async throws -> WhisperSTTEngine.Output {
        let spec = VideoLingoLanguageCatalog.spec(for: language)
        let localeIdentifier = spec?.bcp47 ?? Locale.current.identifier
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw VideoLingoError.modelUnavailable("Apple 음성 인식(\(localeIdentifier))을 현재 사용할 수 없습니다. 시스템 설정에서 음성 인식 권한과 언어 모델을 확인하세요.")
        }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let transcription: SFTranscription? = try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var finished = false
            var recognitionTask: SFSpeechRecognitionTask?
            func finish(_ result: Result<SFTranscription?, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                recognitionTask = nil
                continuation.resume(with: result)
            }
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    let partial = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !partial.isEmpty { onPartialText(partial) }
                    if result.isFinal {
                        finish(.success(result.bestTranscription))
                        return
                    }
                }
                if let error {
                    let nsError = error as NSError
                    // 무음 구간(1110: No speech detected)은 오류가 아니라 빈 전사로 처리합니다.
                    if nsError.code == 1110 || nsError.localizedDescription.lowercased().contains("no speech") {
                        finish(.success(nil))
                    } else {
                        finish(.failure(error))
                    }
                }
            }
            _ = recognitionTask
        }

        guard let transcription else {
            return WhisperSTTEngine.Output(
                text: "",
                language: spec?.whisperCode,
                confidence: nil,
                cues: [],
                retryCount: 0,
                qualityNotes: [TranscriptCoverage.verifiedSilenceNote, TranscriptCoverage.promptFreeVerificationNote]
            )
        }

        let cues = buildCues(from: transcription.segments)
        let text = cues.isEmpty
            ? TranscriptTextSanitizer.cleanWhisperText(transcription.formattedString)
            : cues.map(\.text).joined(separator: "\n")
        let confidences = transcription.segments.map { Double($0.confidence) }.filter { $0 > 0 }
        let avgConfidence = confidences.isEmpty ? (text.isEmpty ? nil : 0.75) : confidences.reduce(0, +) / Double(confidences.count)
        let notes: [String] = text.isEmpty
            ? [TranscriptCoverage.verifiedSilenceNote, TranscriptCoverage.promptFreeVerificationNote]
            : ["Apple 온디바이스 음성 인식"]
        return WhisperSTTEngine.Output(
            text: text,
            language: spec?.whisperCode ?? VideoLingoLanguageCatalog.detectLanguage(for: text)?.whisperCode,
            confidence: avgConfidence,
            cues: cues,
            retryCount: 0,
            qualityNotes: notes
        )
    }

    private static func buildCues(from segments: [SFTranscriptionSegment]) -> [TranscriptCue] {
        guard !segments.isEmpty else { return [] }
        var cues: [TranscriptCue] = []
        var bufferWords: [String] = []
        var cueStart: TimeInterval = segments[0].timestamp
        var cueEnd: TimeInterval = segments[0].timestamp + max(0.1, segments[0].duration)

        func flush() {
            let joined = TranscriptTextSanitizer.cleanWhisperText(bufferWords.joined(separator: " "))
            if !joined.isEmpty, cueEnd > cueStart {
                cues.append(TranscriptCue(startTime: cueStart, endTime: cueEnd, text: joined))
            }
            bufferWords = []
        }

        let sentenceEnders = CharacterSet(charactersIn: ".!?。！？")
        for segment in segments {
            let start = segment.timestamp
            let end = start + max(0.05, segment.duration)
            if !bufferWords.isEmpty && (start - cueEnd >= 0.75 || bufferWords.count >= 18) {
                flush()
                cueStart = start
            }
            if bufferWords.isEmpty { cueStart = start }
            bufferWords.append(segment.substring)
            cueEnd = max(cueEnd, end)
            if let lastScalar = segment.substring.unicodeScalars.last, sentenceEnders.contains(lastScalar) {
                flush()
            }
        }
        flush()
        return cues
    }
}

/// SpikDoum과 동일한 Apple 전용 Translation 프레임워크(.lowLatency NMT 우선 + 기본 세션 자동 폴백) 엔진입니다.
actor AppleNativeTranslationEngine {
    static let shared = AppleNativeTranslationEngine()

    private var sessions: [String: TranslationSession] = [:]

    func invalidateSessions() {
        sessions.removeAll()
    }

    func translate(
        _ text: String,
        sourceLanguage: String?,
        targetLanguage: String,
        onPartialText: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let detected = sourceLanguage.flatMap { VideoLingoLanguageCatalog.spec(for: $0) }
            ?? VideoLingoLanguageCatalog.detectLanguage(for: text)
        let sourceCode = detected?.appleTranslationCode ?? VideoLingoLanguageCatalog.appleTranslationCode(for: sourceLanguage ?? "en")
        let targetCode = VideoLingoLanguageCatalog.appleTranslationCode(for: targetLanguage)
        if sourceCode == targetCode {
            return text
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var translatedLines: [String] = []
        translatedLines.reserveCapacity(lines.count)
        for line in lines {
            try Task.checkCancellation()
            let (prefix, body) = splitSpeakerPrefix(line)
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBody.isEmpty {
                translatedLines.append(prefix ?? "")
                continue
            }
            let translatedBody = try await translateParagraph(trimmedBody, sourceCode: sourceCode, targetCode: targetCode)
            let assembled = prefix.map { "\($0) \(translatedBody)" } ?? translatedBody
            translatedLines.append(assembled)
            onPartialText(translatedLines.joined(separator: "\n"))
        }
        return translatedLines.joined(separator: "\n")
    }

    private func translateParagraph(_ text: String, sourceCode: String, targetCode: String) async throws -> String {
        let sourceLang = Locale.Language(identifier: sourceCode)
        let targetLang = Locale.Language(identifier: targetCode)
        do {
            if #available(macOS 26.4, *) {
                // SpikDoum 방식: 메모리 압박 시 ModelManagerError 1013을 피하기 위해 경량 NMT(.lowLatency) 우선 사용
                let fastKey = "\(sourceCode)->\(targetCode):low"
                let fastSession: TranslationSession
                if let existing = sessions[fastKey] {
                    fastSession = existing
                } else {
                    fastSession = TranslationSession(installedSource: sourceLang, target: targetLang, preferredStrategy: .lowLatency)
                    sessions[fastKey] = fastSession
                }
                do {
                    return try await fastSession.translate(text).targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    sessions.removeValue(forKey: fastKey)
                    let fallbackKey = "\(sourceCode)->\(targetCode):default"
                    let fallbackSession: TranslationSession
                    if let existing = sessions[fallbackKey] {
                        fallbackSession = existing
                    } else {
                        fallbackSession = TranslationSession(installedSource: sourceLang, target: targetLang)
                        sessions[fallbackKey] = fallbackSession
                    }
                    return try await fallbackSession.translate(text).targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                let key = "\(sourceCode)->\(targetCode)"
                let session: TranslationSession
                if let existing = sessions[key] {
                    session = existing
                } else {
                    session = TranslationSession(installedSource: sourceLang, target: targetLang)
                    sessions[key] = session
                }
                return try await session.translate(text).targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TranslationError {
            sessions.removeAll()
            switch error {
            case .notInstalled:
                throw VideoLingoError.modelUnavailable("Apple 전용 번역 언어(\(sourceCode) → \(targetCode))가 기기에 설치되지 않았습니다. 설정 → 엔진 설정에서 ‘번역 언어 준비’를 눌러 다운로드하거나 다른 번역 엔진을 선택하세요.")
            default:
                throw VideoLingoError.modelUnavailable("Apple 전용 번역 실패: \(error.localizedDescription)")
            }
        }
    }

    private func splitSpeakerPrefix(_ line: String) -> (prefix: String?, body: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else {
            return (nil, trimmed)
        }
        let prefix = String(trimmed[...close])
        guard prefix.count <= 42 else { return (nil, trimmed) }
        let body = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        return (prefix, body)
    }
}
