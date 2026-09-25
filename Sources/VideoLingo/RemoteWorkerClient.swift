import Foundation
import VideoLingoCore

enum RemoteWorkerClientError: LocalizedError {
    case invalidResponse
    case rejected(String)
    case failed(String)
    /// 서버가 표준 형식으로 돌려준 오류입니다. 분기는 code 로 합니다.
    case server(status: Int, code: String?, message: String, retryAfter: Double?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "STTLMMServer 응답 형식이 올바르지 않습니다."
        case let .rejected(message), let .failed(message): message
        case let .server(status, code, message, _):
            code.map { "STTLMMServer \(status) [\($0)]: \(message)" } ?? "STTLMMServer \(status): \(message)"
        }
    }

    var serverCode: String? {
        if case let .server(_, code, _, _) = self { return code }
        return nil
    }
}

/// https://github.com/randykwon/STTLMMServer 의 공개 API를 사용하는 클라이언트입니다.
struct RemoteWorkerClient: Sendable {
    struct STTSegment: Decodable, Sendable {
        let start: Double
        let end: Double
        let text: String
        let avgLogprob: Double?

        enum CodingKeys: String, CodingKey {
            case start, end, text
            case avgLogprob = "avg_logprob"
        }
    }

    struct STTResponse: Decodable, Sendable {
        let language: String?
        let segments: [STTSegment]?
    }

    private struct TranslateItem: Decodable, Sendable { let text: String }
    private struct TranslateResponse: Decodable, Sendable { let translations: [TranslateItem] }

    let worker: RemoteWorkerConfiguration

    func run(
        mediaURL: URL,
        manifest: RemoteJobManifest,
        onProgress: @escaping @Sendable (RemoteJobProgress) async -> Void
    ) async throws -> RemoteJobResult {
        await onProgress(RemoteJobProgress(
            jobID: manifest.jobID, status: .transcribing,
            sttProgress: 0.05, translationProgress: 0,
            message: "STTLMMServer에 영상을 전송하고 있습니다."
        ))
        let stt = try await transcribe(mediaURL: mediaURL, options: manifest.options)
        let sourceSegments = stt.segments ?? []
        guard !sourceSegments.isEmpty else {
            throw RemoteWorkerClientError.failed("STTLMMServer가 자막 세그먼트를 반환하지 않았습니다.")
        }
        let transcripts = sourceSegments.enumerated().map { index, segment in
            TranscriptSegment(
                jobID: manifest.jobID,
                chunkIndex: index,
                startTime: segment.start,
                endTime: segment.end,
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                language: stt.language,
                confidence: segment.avgLogprob.map { min(1, max(0, exp($0))) },
                cues: [TranscriptCue(startTime: segment.start, endTime: segment.end, text: segment.text)],
                qualityStatus: .good,
                retryCount: 0,
                qualityNotes: []
            )
        }
        await onProgress(RemoteJobProgress(
            jobID: manifest.jobID, status: .translating,
            sttProgress: 1, translationProgress: 0,
            message: "STT 완료 · LLM 번역을 시작합니다."
        ))

        var translations: [TranslationSegment] = []
        let targets = manifest.options.targetLanguages
        for (languageIndex, language) in targets.enumerated() {
            try Task.checkCancellation()
            let translatedTexts = try await translate(
                texts: transcripts.map(\.text),
                sourceLanguage: manifest.options.sourceLanguage ?? stt.language,
                targetLanguage: language,
                options: manifest.options
            )
            guard translatedTexts.count == transcripts.count else {
                throw RemoteWorkerClientError.invalidResponse
            }
            translations += zip(transcripts, translatedTexts).map { transcript, text in
                TranslationSegment(
                    transcriptID: transcript.id,
                    jobID: manifest.jobID,
                    targetLanguage: language,
                    modelID: manifest.options.translationModel,
                    text: text,
                    qualityStatus: .good,
                    qualityNotes: []
                )
            }
            await onProgress(RemoteJobProgress(
                jobID: manifest.jobID, status: .translating,
                sttProgress: 1,
                translationProgress: Double(languageIndex + 1) / Double(max(1, targets.count)),
                message: "\(language.uppercased()) 번역 완료"
            ))
        }
        return RemoteJobResult(transcripts: transcripts, translations: translations)
    }

    func cancel(jobID: UUID) async throws {
        // STTLMMServer는 별도 job DELETE API가 없어서 URLSession 작업 취소로 연결을 닫습니다.
    }

    private func transcribe(mediaURL: URL, options: ProcessingOptions) async throws -> STTResponse {
        var fields = ["response_format": "verbose_json", "timestamp_granularities": "segment"]
        if let language = options.sourceLanguage, !language.isEmpty { fields["language"] = language }
        let (bodyURL, boundary) = try multipartBody(fileURL: mediaURL, fields: fields)
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        var request = authenticatedRequest(path: "/v1/audio/transcriptions")
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
        try validate(response, data: data)
        return try JSONDecoder().decode(STTResponse.self, from: data)
    }

    /// 오디오 트랙 전체를 한 번에 인식합니다.
    /// 서버가 파일 하나를 통으로 처리하는 편이 훨씬 빠르므로(실측 65배속) 구간을 쪼개 보내지 않습니다.
    /// 단일 요청 한도(기본 200MB)를 넘으면 자동으로 청크 업로드 세션으로 넘어갑니다.
    func transcribeAudio(
        audioURL: URL,
        language: String?,
        onProgress: @Sendable (String) -> Void = { _ in }
    ) async throws -> STTResponse {
        let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)??.intValue ?? 0
        if size > Self.singleRequestLimit {
            return try await transcribeViaUploadSession(audioURL: audioURL, size: size, language: language, onProgress: onProgress)
        }
        return try await withRetry {
            var fields = ["response_format": "verbose_json", "timestamp_granularities": "segment"]
            if let language, !language.isEmpty { fields["language"] = language }
            let (bodyURL, boundary) = try multipartBody(fileURL: audioURL, fields: fields)
            defer { try? FileManager.default.removeItem(at: bodyURL) }
            var request = authenticatedRequest(path: "/v1/audio/transcriptions")
            request.httpMethod = "POST"
            request.timeoutInterval = 1800
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
            try validate(response, data: data)
            return try JSONDecoder().decode(STTResponse.self, from: data)
        }
    }

    /// 단일 요청 한도를 넘는 오디오용 경로입니다.
    /// 세션을 열고 서버가 정해 준 크기로 잘라 올린 뒤, 작업 id로 결과를 폴링합니다.
    private func transcribeViaUploadSession(
        audioURL: URL,
        size: Int,
        language: String?,
        onProgress: @Sendable (String) -> Void
    ) async throws -> STTResponse {
        var body: [String: Any] = [
            "filename": audioURL.lastPathComponent,
            "size": size,
            "response_format": "verbose_json",
            "timestamp_granularities": "segment"
        ]
        if let language, !language.isEmpty { body["language"] = language }
        let session = try await postJSON(path: "/v1/audio/uploads", body: body)
        guard let uploadID = session["upload_id"] as? String else { throw RemoteWorkerClientError.invalidResponse }
        // 청크 크기는 서버가 정합니다. 값을 코드에 박아 두면 서버 설정 변경과 어긋납니다.
        let chunkSize = (session["chunk_size"] as? NSNumber)?.intValue ?? 100 * 1024 * 1024

        let handle = try FileHandle(forReadingFrom: audioURL)
        defer { try? handle.close() }
        var offset = (session["next_offset"] as? NSNumber)?.intValue ?? 0
        while offset < size {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            let state = try await uploadChunk(uploadID: uploadID, offset: offset, data: data)
            offset = (state["next_offset"] as? NSNumber)?.intValue ?? (offset + data.count)
            let progress = (state["progress"] as? NSNumber)?.doubleValue ?? 0
            onProgress(String(localized: "업로드 \(Int(progress * 100))%"))
        }

        let job = try await postJSON(path: "/v1/audio/uploads/\(uploadID)/transcribe", body: nil)
        guard let jobID = job["job_id"] as? String else { throw RemoteWorkerClientError.invalidResponse }

        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(5))
            var request = authenticatedRequest(path: "/v1/audio/jobs/\(jobID)")
            request.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response, data: data)
            guard let status = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = status["state"] as? String else { throw RemoteWorkerClientError.invalidResponse }
            switch state {
            case "completed":
                guard let result = status["result"],
                      let resultData = try? JSONSerialization.data(withJSONObject: result) else {
                    throw RemoteWorkerClientError.invalidResponse
                }
                return try JSONDecoder().decode(STTResponse.self, from: resultData)
            case "failed", "cancelled":
                throw RemoteWorkerClientError.failed(
                    (status["error"] as? String) ?? String(localized: "원격 전사가 실패했습니다.")
                )
            default:
                let elapsed = (status["elapsed_seconds"] as? NSNumber)?.doubleValue ?? 0
                onProgress(String(localized: "원격 전사 중 \(Int(elapsed))초"))
            }
        }
    }

    private func postJSON(path: String, body: [String: Any]?) async throws -> [String: Any] {
        try await withRetry {
            var request = authenticatedRequest(path: path)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response, data: data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RemoteWorkerClientError.invalidResponse
            }
            return object
        }
    }

    private func uploadChunk(uploadID: String, offset: Int, data: Data) async throws -> [String: Any] {
        try await withRetry {
            let boundary = "videolingo-\(UUID().uuidString)"
            var payload = Data()
            func append(_ text: String) { payload.append(Data(text.utf8)) }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"offset\"\r\n\r\n\(offset)\r\n")
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"chunk\"; filename=\"part\"\r\n")
            append("Content-Type: application/octet-stream\r\n\r\n")
            payload.append(data)
            append("\r\n--\(boundary)--\r\n")
            var request = authenticatedRequest(path: "/v1/audio/uploads/\(uploadID)/chunk")
            request.httpMethod = "POST"
            request.timeoutInterval = 1800
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (responseData, response) = try await URLSession.shared.upload(for: request, from: payload)
            try validate(response, data: responseData)
            guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                throw RemoteWorkerClientError.invalidResponse
            }
            return object
        }
    }

    /// 단일 요청 업로드 한도입니다. 서버 기본값과 같은 200MB에 여유를 둡니다.
    private static let singleRequestLimit = 190 * 1024 * 1024

    /// 이미 만들어 둔 STT 결과만 원격 서버에서 번역합니다.
    /// 영상 원본을 올리지 않으므로 서버의 업로드 용량 한도와 무관합니다.
    func translateOnly(
        texts: [String], sourceLanguage: String?, targetLanguage: String, options: ProcessingOptions
    ) async throws -> [String] {
        // 서버의 번역 모델이 `[화자 2]` 같은 라벨을 번역해 버립니다(실측).
        // 보내기 전에 치환해 보호하고 받은 뒤 되돌립니다.
        var labels: [String: String] = [:]
        let masked = texts.map { Self.maskSpeakerLabels(in: $0, into: &labels) }
        let translated = try await translate(
            texts: masked,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            options: options
        )
        return translated.map { Self.restoreSpeakerLabels(in: $0, using: labels) }
    }

    /// 화자 라벨을 번역되지 않는 자리표시자로 바꿉니다.
    private static func maskSpeakerLabels(in text: String, into labels: inout [String: String]) -> String {
        let pattern = #"\[([^\[\]\n]{1,40})\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var output = ""
        var cursor = text.startIndex
        for match in matches {
            guard let full = Range(match.range, in: text),
                  let inner = Range(match.range(at: 1), in: text) else { continue }
            output += text[cursor..<full.lowerBound]
            let original = String(text[inner])
            let token = labels.first(where: { $0.value == original })?.key ?? "⟦S\(labels.count)⟧"
            labels[token] = original
            output += token
            cursor = full.upperBound
        }
        output += text[cursor...]
        return output
    }

    private static func restoreSpeakerLabels(in text: String, using labels: [String: String]) -> String {
        labels.reduce(text) { partial, entry in
            partial.replacingOccurrences(of: entry.key, with: "[\(entry.value)]")
        }
    }

    private func translate(
        texts: [String], sourceLanguage: String?, targetLanguage: String, options: ProcessingOptions
    ) async throws -> [String] {
        var results: [String] = []
        for batchStart in stride(from: 0, to: texts.count, by: 200) {
            let batch = Array(texts[batchStart..<min(texts.count, batchStart + 200)])
            let glossary = Dictionary(uniqueKeysWithValues: (options.glossary ?? []).map { ($0.source, $0.target) })
            var body: [String: Any] = [
                "text": batch,
                "target_lang": targetLanguage,
                "glossary": glossary,
                "preserve_formatting": true,
                "use_context": true,
                "enforce_glossary": !glossary.isEmpty
            ]
            if let sourceLanguage, !sourceLanguage.isEmpty { body["source_lang"] = sourceLanguage }
            var request = authenticatedRequest(path: "/v1/translate")
            request.httpMethod = "POST"
            request.timeoutInterval = 60 * 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response, data: data)
            results += try JSONDecoder().decode(TranslateResponse.self, from: data).translations.map(\.text)
        }
        return results
    }

    private func authenticatedRequest(path: String) -> URLRequest {
        var request = URLRequest(url: worker.baseURL.appending(path: path))
        if !worker.authenticationToken.isEmpty {
            request.setValue("Bearer \(worker.authenticationToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw RemoteWorkerClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            let error = detail?["error"] as? [String: Any]
            let message = detail?["message"] as? String
                ?? error?["message"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            // 서버 가이드: 메시지가 아니라 code 로 분기하고, 503/502만 Retry-After 만큼 기다려 재시도합니다.
            let code = error?["code"] as? String
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
            throw RemoteWorkerClientError.server(
                status: http.statusCode,
                code: code,
                message: message,
                retryAfter: retryAfter
            )
        }
    }

    /// 재시도할 가치가 있는 오류만 지정한 지연만큼 기다렸다가 다시 시도합니다.
    /// 4xx는 요청 자체가 잘못된 것이라 재시도하지 않습니다(가이드 권장).
    private func withRetry<T: Sendable>(
        attempts: Int = 3,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                return try await operation()
            } catch let error as RemoteWorkerClientError {
                guard case let .server(status, code, _, retryAfter) = error else { throw error }
                let retryable = status == 503 || status == 502 || code == "model_busy"
                guard retryable, attempt < attempts - 1 else { throw error }
                let delay = retryAfter ?? min(30, pow(2, Double(attempt)))
                lastError = error
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw lastError ?? RemoteWorkerClientError.invalidResponse
    }

    private func multipartBody(fileURL: URL, fields: [String: String]) throws -> (URL, String) {
        let boundary = "VideoLingo-\(UUID().uuidString)"
        let outputURL = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).upload")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        for (name, value) in fields {
            output.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        output.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { output.write(chunk) }
        output.write(Data("\r\n--\(boundary)--\r\n".utf8))
        return (outputURL, boundary)
    }
}
