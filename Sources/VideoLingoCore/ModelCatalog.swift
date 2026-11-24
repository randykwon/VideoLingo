import Foundation

public struct BuiltinModelDescriptor: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let note: String
    public let badge: String?

    public init(id: String, displayName: String, note: String, badge: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.note = note
        self.badge = badge
    }

    public var pickerLabel: String {
        if let badge, !badge.isEmpty {
            return "\(displayName) · \(badge)"
        }
        return displayName
    }
}

/// WhisperKit, MLX, Deepgram, OpenAI 호환 서버의 검증된 모델 카탈로그입니다.
public enum ModelCatalog {
    /// WhisperKit은 `*variant*` 패턴으로 폴더를 찾으므로 저장소에서 유일하게 매칭되는 폴더명만 제공합니다.
    public static let whisperKitModels: [BuiltinModelDescriptor] = [
        BuiltinModelDescriptor(id: "large-v3-v20240930_626MB", displayName: "Large v3 · 626MB", note: "균형 잡힌 다국어 기본 모델", badge: "기본"),
        BuiltinModelDescriptor(id: "openai_whisper-large-v3-v20240930_turbo_632MB", displayName: "Large v3 Turbo · 632MB", note: "빠른 다국어 추론 속도", badge: "빠름"),
        BuiltinModelDescriptor(id: "openai_whisper-large-v3-v20240930_547MB", displayName: "Large v3 · 547MB", note: "가벼운 양자화 Large v3"),
        BuiltinModelDescriptor(id: "openai_whisper-large-v3_947MB", displayName: "Large v3 · 947MB", note: "고정밀 다국어 · 억양/잡음 강점", badge: "고정밀"),
        BuiltinModelDescriptor(id: "openai_whisper-large-v3_turbo_954MB", displayName: "Large v3 Turbo · 954MB", note: "고정밀 + 고속 Turbo", badge: "추천"),
        BuiltinModelDescriptor(id: "openai_whisper-large-v2_949MB", displayName: "Large v2 · 949MB", note: "안정적 다국어 · 환각 적음"),
        BuiltinModelDescriptor(id: "openai_whisper-large-v2_turbo_955MB", displayName: "Large v2 Turbo · 955MB", note: "고속 Large v2"),
        BuiltinModelDescriptor(id: "distil-whisper_distil-large-v3_594MB", displayName: "Distil Large v3 · 594MB", note: "영어 특화 고속 증류 모델"),
        BuiltinModelDescriptor(id: "distil-whisper_distil-large-v3_turbo_600MB", displayName: "Distil Large v3 Turbo · 600MB", note: "영어 초고속 증류 모델"),
        BuiltinModelDescriptor(id: "openai_whisper-small_216MB", displayName: "Small · 216MB", note: "초경량 다국어 · 저메모리"),
        BuiltinModelDescriptor(id: "openai_whisper-medium.en", displayName: "Medium English", note: "영어 전용 고정밀"),
        BuiltinModelDescriptor(id: "openai_whisper-small.en_217MB", displayName: "Small English · 217MB", note: "영어 전용 초경량")
    ]

    /// Hugging Face `mlx-community`에서 검증된 Apple Silicon MLX 번역 LLM 목록입니다.
    public static let mlxTranslationModels: [BuiltinModelDescriptor] = [
        BuiltinModelDescriptor(id: "mlx-community/Qwen3-0.6B-4bit", displayName: "Qwen3 0.6B 4-bit", note: "초경량 · 최저 메모리"),
        BuiltinModelDescriptor(id: "mlx-community/Qwen3-1.7B-4bit", displayName: "Qwen3 1.7B 4-bit", note: "경량 · 빠른 다국어 번역"),
        BuiltinModelDescriptor(id: "mlx-community/Qwen3-4B-4bit", displayName: "Qwen3 4B 4-bit", note: "속도와 품질의 균형", badge: "균형"),
        BuiltinModelDescriptor(id: "mlx-community/Qwen3-8B-4bit", displayName: "Qwen3 8B 4-bit", note: "고품질 다국어 번역", badge: "기본"),
        BuiltinModelDescriptor(id: "mlx-community/Qwen3-14B-4bit", displayName: "Qwen3 14B 4-bit", note: "대형 최고 품질 · 16GB+ Mac 권장", badge: "고품질"),
        BuiltinModelDescriptor(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", displayName: "Qwen2.5 3B Instruct 4-bit", note: "안정적·빠른 한/영/일/중 번역"),
        BuiltinModelDescriptor(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", displayName: "Qwen2.5 7B Instruct 4-bit", note: "검증된 다국어 자막 번역"),
        BuiltinModelDescriptor(id: "mlx-community/Qwen2.5-14B-Instruct-4bit", displayName: "Qwen2.5 14B Instruct 4-bit", note: "고품질 대형 Qwen2.5 · 16GB+ Mac"),
        BuiltinModelDescriptor(id: "mlx-community/gemma-3-1b-it-qat-4bit", displayName: "Gemma 3 1B QAT 4-bit", note: "Google 초경량 번역"),
        BuiltinModelDescriptor(id: "mlx-community/gemma-3-4b-it-qat-4bit", displayName: "Gemma 3 4B QAT 4-bit", note: "Google Gemma 3 · 한/일/영 자연스러운 번역", badge: "추천"),
        BuiltinModelDescriptor(id: "mlx-community/gemma-3-12b-it-qat-4bit", displayName: "Gemma 3 12B QAT 4-bit", note: "Google Gemma 3 최고 품질 · 16GB+ Mac"),
        BuiltinModelDescriptor(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B Instruct 4-bit", note: "Meta Llama 3.2 · 영어·유럽어 강점"),
        BuiltinModelDescriptor(id: "mlx-community/Mistral-Small-24B-Instruct-2501-4bit", displayName: "Mistral Small 24B 4-bit", note: "초대형 다국어 · 24GB+ Mac 권장")
    ]

    public static let deepgramModels: [BuiltinModelDescriptor] = [
        BuiltinModelDescriptor(id: "nova-3", displayName: "Nova-3", note: "최신 다국어 고정밀 + 화자 구분", badge: "추천"),
        BuiltinModelDescriptor(id: "nova-3-general", displayName: "Nova-3 General", note: "범용 다국어"),
        BuiltinModelDescriptor(id: "nova-2", displayName: "Nova-2", note: "안정적 다국어 모델"),
        BuiltinModelDescriptor(id: "nova-2-meeting", displayName: "Nova-2 Meeting", note: "회의·다화자 대화 특화"),
        BuiltinModelDescriptor(id: "whisper-large", displayName: "Deepgram Whisper Large", note: "클라우드 Whisper Large")
    ]

    public static func whisperKitDescriptor(for id: String) -> BuiltinModelDescriptor? {
        whisperKitModels.first { $0.id == id }
    }

    public static func mlxDescriptor(for id: String) -> BuiltinModelDescriptor? {
        mlxTranslationModels.first { $0.id == id }
    }

    public static func deepgramDescriptor(for id: String) -> BuiltinModelDescriptor? {
        deepgramModels.first { $0.id == id }
    }
}
