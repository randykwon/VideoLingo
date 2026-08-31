import Foundation
import VideoLingoCore

enum RemoteWorkerClientError: LocalizedError {
    case invalidResponse
    case rejected(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "STTLMMServer 응답 형식이 올바르지 않습니다."
        case let .rejected(message), let .failed(message): message
        }
    }
}

/// https://github.com/randykwon/STTLMMServer 의 공개 API를 사용하는 클라이언트입니다.
struct RemoteWorkerClient: Sendable {
    private struct STTSegment: Decodable, Sendable {
        let start: Double
        let end: Double
        let text: String
        let avgLogprob: Double?

        enum CodingKeys: String, CodingKey {
            case start, end, text
            case avgLogprob = "avg_logprob"
        }
    }

    private struct STTResponse: Decodable, Sendable {
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
            let message = detail?["message"] as? String
                ?? (detail?["error"] as? [String: Any])?["message"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw RemoteWorkerClientError.rejected("STTLMMServer \(http.statusCode): \(message)")
        }
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
