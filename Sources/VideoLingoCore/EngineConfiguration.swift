import Foundation
import NaturalLanguage
import Security

/// STT 엔진 선택지입니다. 기존 WhisperKit을 기본값으로 유지하면서
/// SpikDoum 방식의 자체 whisper.cpp 서버, Apple 온디바이스 음성 인식, Deepgram Nova-3를 지원합니다.
public enum STTEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case whisperKit
    case managedWhisper
    case appleSpeech
    case deepgram

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .whisperKit: "WhisperKit · 내장"
        case .managedWhisper: "자체 모델 · whisper.cpp 서버 (Metal GPU)"
        case .appleSpeech: "Apple 음성 인식 · 기기 내"
        case .deepgram: "Deepgram Nova-3 · 클라우드 · 화자 구분"
        }
    }
}

/// 번역 엔진 선택지입니다. 기존 MLX·Apple Intelligence·외부 OpenAI 호환 서버를 유지하면서
/// SpikDoum 방식의 Apple 전용 번역(Translation), 자체 llama.cpp 서버, Azure Translator, 로컬 커스텀 번역 API를 지원합니다.
public enum TranslationEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case mlx
    case appleTranslation
    case managedLlama
    case appleFoundation
    case azure
    case localAPI
    case externalOpenAI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mlx: "MLX 로컬 LLM · 내장"
        case .appleTranslation: "Apple 전용 번역 · 기기 내 NMT"
        case .managedLlama: "자체 모델 · llama.cpp 서버 (Metal GPU)"
        case .appleFoundation: "Apple Intelligence · Foundation Models"
        case .azure: "Azure Translator · 언어 자동 감지"
        case .localAPI: "로컬 LLM · 커스텀 번역 API"
        case .externalOpenAI: "외부 OpenAI 호환 서버 (Ollama · LM Studio · vLLM)"
        }
    }
}

/// SpikDoum의 LocalTranslationSettings와 동일한 사용자 정의 HTTP POST 번역 API 설정입니다.
public struct LocalTranslationAPISettings: Codable, Equatable, Sendable {
    public var endpoint: String
    public var timeout: Double
    public var requestJSON: String
    public var responsePath: String

    public init(
        endpoint: String = "http://127.0.0.1:8848/v1/translate",
        timeout: Double = 30,
        requestJSON: String = #"{"text":"{{text}}","source_lang":"{{source}}","target_lang":"{{target}}"}"#,
        responsePath: String = ""
    ) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.requestJSON = requestJSON
        self.responsePath = responsePath
    }
}

/// macOS 키체인에 외부 STT·번역 API 키를 안전하게 저장·조회합니다.
public enum APIKeyStore {
    public static let service = "com.vvv.VideoLingo.api"

    public enum Account: String, CaseIterable, Sendable {
        case deepgram = "deepgram"
        case azure = "azure"
        case localTranslation = "translation-local"
        case externalOpenAI = "external-openai"
    }

    public static func read(_ account: Account) -> String {
        read(rawAccount: account.rawValue)
    }

    public static func read(rawAccount: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: rawAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        return ""
    }

    public static func write(_ value: String, account: Account) throws {
        try write(value, rawAccount: account.rawValue)
    }

    public static func write(_ value: String, rawAccount: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: rawAccount
        ]
        let status: OSStatus
        if trimmed.isEmpty {
            status = SecItemDelete(query as CFDictionary)
        } else {
            let bytes = Data(trimmed.utf8)
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
            if update == errSecItemNotFound {
                var insert = query
                insert[kSecValueData as String] = bytes
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(insert as CFDictionary, nil)
            } else {
                status = update
            }
        }
        guard status == errSecSuccess || (trimmed.isEmpty && status == errSecItemNotFound) else {
            throw VideoLingoError.modelUnavailable("키체인 API 키 저장 실패 (OSStatus \(status))")
        }
    }
}

/// SpikDoum의 LanguageCatalog와 호환되는 다국어 메타데이터 카탈로그입니다.
public struct SupportedLanguageSpec: Identifiable, Equatable, Hashable, Sendable {
    public let code: String             // e.g. "ko", "en", "zh-Hans", "zh-Hant"
    public let bcp47: String            // e.g. "ko-KR", "en-US", "zh-CN", "zh-TW"
    public let whisperCode: String      // ISO 639-1 for Whisper/Deepgram e.g. "ko", "zh"
    public let azureCode: String        // Azure Translator code e.g. "zh-Hans", "zh-Hant"
    public let appleTranslationCode: String // Apple Translation Locale.Language identifier
    public let englishName: String
    public let koreanName: String

    public var id: String { code }

    public init(
        code: String,
        bcp47: String,
        whisperCode: String,
        azureCode: String,
        appleTranslationCode: String,
        englishName: String,
        koreanName: String
    ) {
        self.code = code
        self.bcp47 = bcp47
        self.whisperCode = whisperCode
        self.azureCode = azureCode
        self.appleTranslationCode = appleTranslationCode
        self.englishName = englishName
        self.koreanName = koreanName
    }
}

public enum VideoLingoLanguageCatalog {
    public static let all: [SupportedLanguageSpec] = [
        SupportedLanguageSpec(code: "ko", bcp47: "ko-KR", whisperCode: "ko", azureCode: "ko", appleTranslationCode: "ko", englishName: "Korean", koreanName: "한국어"),
        SupportedLanguageSpec(code: "en", bcp47: "en-US", whisperCode: "en", azureCode: "en", appleTranslationCode: "en", englishName: "English", koreanName: "영어"),
        SupportedLanguageSpec(code: "ja", bcp47: "ja-JP", whisperCode: "ja", azureCode: "ja", appleTranslationCode: "ja", englishName: "Japanese", koreanName: "일본어"),
        SupportedLanguageSpec(code: "zh-Hans", bcp47: "zh-CN", whisperCode: "zh", azureCode: "zh-Hans", appleTranslationCode: "zh-Hans", englishName: "Chinese (Simplified)", koreanName: "중국어(간체)"),
        SupportedLanguageSpec(code: "zh-Hant", bcp47: "zh-TW", whisperCode: "zh", azureCode: "zh-Hant", appleTranslationCode: "zh-Hant", englishName: "Chinese (Traditional)", koreanName: "중국어(번체)"),
        SupportedLanguageSpec(code: "es", bcp47: "es-ES", whisperCode: "es", azureCode: "es", appleTranslationCode: "es", englishName: "Spanish", koreanName: "스페인어"),
        SupportedLanguageSpec(code: "fr", bcp47: "fr-FR", whisperCode: "fr", azureCode: "fr", appleTranslationCode: "fr", englishName: "French", koreanName: "프랑스어"),
        SupportedLanguageSpec(code: "de", bcp47: "de-DE", whisperCode: "de", azureCode: "de", appleTranslationCode: "de", englishName: "German", koreanName: "독일어"),
        SupportedLanguageSpec(code: "pt", bcp47: "pt-BR", whisperCode: "pt", azureCode: "pt", appleTranslationCode: "pt", englishName: "Portuguese", koreanName: "포르투갈어"),
        SupportedLanguageSpec(code: "it", bcp47: "it-IT", whisperCode: "it", azureCode: "it", appleTranslationCode: "it", englishName: "Italian", koreanName: "이탈리아어"),
        SupportedLanguageSpec(code: "ru", bcp47: "ru-RU", whisperCode: "ru", azureCode: "ru", appleTranslationCode: "ru", englishName: "Russian", koreanName: "러시아어"),
        SupportedLanguageSpec(code: "vi", bcp47: "vi-VN", whisperCode: "vi", azureCode: "vi", appleTranslationCode: "vi", englishName: "Vietnamese", koreanName: "베트남어")
    ]

    public static func spec(for code: String?) -> SupportedLanguageSpec? {
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lower = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        if lower == "zh" { return all.first { $0.code == "zh-Hans" } }
        return all.first {
            $0.code.lowercased() == lower
                || $0.bcp47.lowercased() == lower
                || $0.azureCode.lowercased() == lower
                || $0.whisperCode.lowercased() == lower
        }
    }

    public static func whisperParameter(for code: String?) -> String {
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw.lowercased() != "auto" else {
            return "auto"
        }
        return spec(for: raw)?.whisperCode ?? String(raw.prefix(2)).lowercased()
    }

    public static func appleTranslationCode(for code: String?) -> String {
        spec(for: code)?.appleTranslationCode ?? (code ?? "en")
    }

    public static func azureCode(for code: String) -> String {
        spec(for: code)?.azureCode ?? code
    }

    public static func englishName(for code: String?) -> String {
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "the automatically detected source language"
        }
        return spec(for: raw)?.englishName ?? raw
    }

    /// 화자 라벨(`[화자 1]` 등)을 제외한 본문에서 언어를 감지합니다.
    public static func detectLanguage(for text: String) -> SupportedLanguageSpec? {
        let stripped = text
            .components(separatedBy: .newlines)
            .map { line -> String in
                var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                while trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                    trimmed = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
                }
                return trimmed
            }
            .filter { !$0.isEmpty }
            .suffix(4)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.count >= 4 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(stripped)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let code: String?
        switch dominant {
        case .korean: code = "ko"
        case .english: code = "en"
        case .japanese: code = "ja"
        case .simplifiedChinese: code = "zh-Hans"
        case .traditionalChinese: code = "zh-Hant"
        case .spanish: code = "es"
        case .french: code = "fr"
        case .german: code = "de"
        case .portuguese: code = "pt"
        case .italian: code = "it"
        case .russian: code = "ru"
        case .vietnamese: code = "vi"
        default: code = nil
        }
        return code.flatMap { spec(for: $0) }
    }
}
