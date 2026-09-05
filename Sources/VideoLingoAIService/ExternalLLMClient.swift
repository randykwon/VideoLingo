import Foundation
import VideoLingoCore

/// OpenAI 호환 채팅 API를 쓰는 외부 LLM 서버 클라이언트입니다.
/// Ollama·LM Studio·llama.cpp server·vLLM·LocalAI처럼 API 키 없이 도는 로컬/사내 서버를 상정하며,
/// 키가 필요한 서버를 위해 인증 헤더는 값이 있을 때만 붙입니다.
struct ExternalLLMClient: Sendable {
    struct Configuration: Sendable, Equatable {
        let endpoint: URL
        let model: String
        let apiKey: String?

        /// 사용자가 넣은 주소를 관대하게 받아들입니다.
        /// `http://localhost:11434`, `.../v1`, `.../v1/chat/completions` 모두 같은 곳을 가리키게 만듭니다.
        init?(endpoint: String, model: String, apiKey: String?) {
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

    let configuration: Configuration
    var timeout: TimeInterval = 180

    /// 시스템 지시와 사용자 프롬프트를 보내고 응답 본문만 돌려줍니다.
    func complete(instructions: String, prompt: String, maximumTokens: Int) async throws -> String {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = configuration.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0,
            "stream": false,
            "max_tokens": maximumTokens,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw VideoLingoError.modelUnavailable(
                "외부 LLM 서버에 연결하지 못했습니다(\(configuration.endpoint.absoluteString)): \(error.localizedDescription)"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw VideoLingoError.modelUnavailable("외부 LLM 서버 응답을 해석할 수 없습니다.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw VideoLingoError.modelUnavailable("외부 LLM 서버 오류 \(http.statusCode): \(detail)")
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw VideoLingoError.modelUnavailable("외부 LLM 서버가 예상과 다른 형식으로 응답했습니다.")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 설정 화면의 연결 테스트용입니다. 성공하면 모델이 돌려준 짧은 응답을 반환합니다.
    func probe() async throws -> String {
        try await complete(
            instructions: "You are a connection test. Reply with the single word OK.",
            prompt: "Reply with OK.",
            maximumTokens: 16
        )
    }
}
