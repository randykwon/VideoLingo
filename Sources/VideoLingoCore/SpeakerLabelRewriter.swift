import Foundation

public enum SpeakerLabelRewriter {
    public static func labels(in transcripts: [TranscriptSegment]) -> [String] {
        var found = Set<String>()
        for segment in transcripts {
            for value in labels(in: segment.text) { found.insert(value) }
            for cue in segment.cues ?? [] {
                for value in labels(in: cue.text) { found.insert(value) }
            }
        }
        return found.sorted(by: speakerLabelOrder)
    }

    public static func rewrite(_ segment: TranscriptSegment, using mapping: [String: String]) -> TranscriptSegment {
        TranscriptSegment(
            id: segment.id,
            jobID: segment.jobID,
            chunkIndex: segment.chunkIndex,
            startTime: segment.startTime,
            endTime: segment.endTime,
            text: rewrite(segment.text, using: mapping),
            language: segment.language,
            confidence: segment.confidence,
            cues: (segment.cues ?? []).map {
                TranscriptCue(startTime: $0.startTime, endTime: $0.endTime, text: rewrite($0.text, using: mapping))
            },
            qualityStatus: segment.qualityStatus,
            retryCount: segment.retryCount,
            qualityNotes: segment.qualityNotes
        )
    }

    public static func rewrite(_ translation: TranslationSegment, using mapping: [String: String]) -> TranslationSegment {
        TranslationSegment(
            id: translation.id,
            transcriptID: translation.transcriptID,
            jobID: translation.jobID,
            targetLanguage: translation.targetLanguage,
            modelID: translation.modelID,
            text: rewrite(translation.text, using: mapping),
            qualityStatus: translation.qualityStatus,
            qualityNotes: translation.qualityNotes
        )
    }

    public static func rewrite(_ text: String, using mapping: [String: String]) -> String {
        let rewritten = mapping.reduce(text) { result, entry in
            result.replacingOccurrences(
                of: "[\(entry.key)]",
                with: "[\(sanitizedSpeakerName(entry.value))]"
            )
        }
        return removingInferenceMarkers(from: rewritten)
    }

    public static func removingInferenceMarkers(from text: String) -> String {
        let patterns = [
            #"\s*[\(（\[]\s*(?:추정|inferred|estimated)\s*[\)）\]]"#,
            #"\s+추정(?=\])"#
        ]
        return patterns.reduce(text) { result, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return result
            }
            let range = NSRange(result.startIndex..., in: result)
            return expression.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
    }

    public static func sanitizedSpeakerName(_ value: String) -> String {
        removingInferenceMarkers(from: value)
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func labels(in text: String) -> [String] {
        let pattern = #"\[(화자\s+(?:\d+|미확인))\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[valueRange])
        }
    }

    private static func speakerLabelOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = Int(lhs.split(separator: " ").last ?? "") ?? .max
        let right = Int(rhs.split(separator: " ").last ?? "") ?? .max
        return left == right ? lhs < rhs : left < right
    }
}
