import Foundation

public enum TranscriptTextSanitizer {
    public static func cleanWhisperText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"<\|.*?\|>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
