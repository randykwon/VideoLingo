import Foundation

/// OpenAI 호환 채팅 API를 쓰는 외부 LLM 서버 클라이언트입니다.
/// Ollama·LM Studio·llama.cpp server·vLLM·LocalAI처럼 API 키 없이 도는 로컬/사내 서버를 상정하며,
/// 키가 필요한 서버를 위해 인증 헤더는 값이 있을 때만 붙입니다.
public struct ExternalLLMClient: Sendable {
    public struct Configuration: Sendable, Equatable {
        public let endpoint: URL
        public let model: String
        public let apiKey: String?

        /// 사용자가 넣은 주소를 관대하게 받아들입니다.
        /// `http://localhost:11434`, `.../v1`, `.../v1/chat/completions` 모두 같은 곳을 가리키게 만듭니다.
        public init?(endpoint: String, model: String, apiKey: String?) {
            let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !modelName.isEmpty else { return nil }
            let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
            var normalized = withScheme
            while normalized.hasSuffix("/") { normalized.removeLast() }
            if !normalized.hasSuffix("/chat/completions") {
                if !normalized.hasSuffix("/v1") { normalized += "/v1" }
                normalized += "/chat/completions"
            }
            guard let url = URL(string: normalized) else { return nil }
            self.endpoint = url
            self.model = modelName
            let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.apiKey = (key?.isEmpty ?? true) ? nil : key
        }
    }

    public let configuration: Configuration
    public var timeout: TimeInterval
    public var maxAttempts: Int
    private let session: URLSession

    public init(
        configuration: Configuration,
        timeout: TimeInterval = 180,
        maxAttempts: Int = 3,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.timeout = timeout
        self.maxAttempts = max(1, maxAttempts)
        self.session = session
    }

    /// 시스템 지시와 사용자 프롬프트를 보내고 응답 본문만 돌려줍니다.
    /// 일시적 네트워크 오류나 429/5xx 응답은 지수 백오프로 재시도하며, 작업 취소는 즉시 전파합니다.
    public func complete(instructions: String, prompt: String, maximumTokens: Int) async throws -> String {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = configuration.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // 추론(thinking) 모델은 사고 과정에 토큰을 먼저 씁니다. 여유가 부족하면 응답이 빈 채로 돌아오므로
        // 실측 기준으로 넉넉한 하한을 둡니다. (think:false·chat_template_kwargs는 Ollama에서 효과가 없었습니다.)
        let tokenBudget = max(1024, min(4096, maximumTokens))
        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0,
            "stream": false,
            "max_tokens": tokenBudget,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error?
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            } catch {
                let wrapped = VideoLingoError.modelUnavailable(
                    "외부 LLM 서버에 연결하지 못했습니다(\(configuration.endpoint.absoluteString)): \(error.localizedDescription)"
                )
                lastError = wrapped
                if attempt + 1 < maxAttempts && Self.isRetryableNetworkError(error) {
                    try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
                    continue
                }
                throw wrapped
            }

            guard let http = response as? HTTPURLResponse else {
                throw VideoLingoError.modelUnavailable("외부 LLM 서버 응답을 해석할 수 없습니다.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                let wrapped = VideoLingoError.modelUnavailable("외부 LLM 서버 오류 \(http.statusCode): \(detail)")
                lastError = wrapped
                if attempt + 1 < maxAttempts && Self.isRetryableStatusCode(http.statusCode) {
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    let delayMs = retryAfter.map { Int(min(15, max(0.5, $0)) * 1000) } ?? (600 * (1 << attempt))
                    try await Task.sleep(for: .milliseconds(delayMs))
                    continue
                }
                throw wrapped
            }

            guard
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = object["choices"] as? [[String: Any]],
                let first = choices.first,
                let message = first["message"] as? [String: Any],
                let content = message["content"] as? String
            else {
                throw VideoLingoError.modelUnavailable("외부 LLM 서버가 예상과 다른 형식으로 응답했습니다.")
            }
            let cleaned = TranslationTextSanitizer.cleanLLMOutput(content)
            guard !cleaned.isEmpty else {
                // 추론 모델이 사고 과정만으로 토큰을 다 쓰면 실제로 이런 응답이 옵니다.
                if first["finish_reason"] as? String == "length" {
                    throw VideoLingoError.modelUnavailable(
                        "외부 LLM 서버가 길이 제한에 걸려 빈 응답을 반환했습니다(\(configuration.model)). 사고 과정이 없는 모델을 쓰거나 더 작은 청크 길이를 사용하세요."
                    )
                }
                let emptyError = VideoLingoError.modelUnavailable("외부 LLM 서버가 빈 응답을 반환했습니다(\(configuration.model)).")
                lastError = emptyError
                if attempt + 1 < maxAttempts {
                    try await Task.sleep(for: .milliseconds(400 * (1 << attempt)))
                    continue
                }
                throw emptyError
            }
            return cleaned
        }
        throw lastError ?? VideoLingoError.modelUnavailable("외부 LLM 서버 요청에 실패했습니다.")
    }

    private static func isRetryableStatusCode(_ code: Int) -> Bool {
        code == 408 || code == 429 || (500...504).contains(code)
    }

    private static func isRetryableNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// 설정 화면의 연결 테스트용입니다. 성공하면 모델이 돌려준 짧은 응답을 반환합니다.
    public func probe() async throws -> String {
        try await complete(
            instructions: "You are a connection test. Reply with the single word OK.",
            prompt: "Reply with OK.",
            maximumTokens: 16
        )
    }
}
