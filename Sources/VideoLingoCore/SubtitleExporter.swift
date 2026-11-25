import Foundation

public enum SubtitleExporter {
    public static func srt(transcript: [TranscriptSegment], translations: [UUID: TranslationSegment] = [:]) -> String {
        displayCues(transcript: transcript, translations: translations).enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.startTime, separator: ",")) --> \(timestamp(cue.endTime, separator: ","))\n\(cue.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    public static func webVTT(transcript: [TranscriptSegment], translations: [UUID: TranslationSegment] = [:]) -> String {
        let cues = displayCues(transcript: transcript, translations: translations).enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.startTime, separator: ".")) --> \(timestamp(cue.endTime, separator: "."))\n\(cue.text)"
        }.joined(separator: "\n\n")
        return "WEBVTT\n\n\(cues)\n"
    }

    private static func displayCues(
        transcript: [TranscriptSegment],
        translations: [UUID: TranslationSegment]
    ) -> [TranscriptCue] {
        transcript.flatMap { segment in
            let timedCues = segment.cues ?? []
            guard !timedCues.isEmpty else {
                return [TranscriptCue(
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    text: translations[segment.id]?.text ?? segment.text
                )]
            }
            guard let translated = translations[segment.id]?.text else { return timedCues }
            let translatedLines = translated
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard translatedLines.count == timedCues.count else {
                return [TranscriptCue(startTime: segment.startTime, endTime: segment.endTime, text: translated)]
            }
            return zip(timedCues, translatedLines).map { cue, text in
                TranscriptCue(startTime: cue.startTime, endTime: cue.endTime, text: text)
            }
        }
    }

    private static func timestamp(_ value: TimeInterval, separator: Character) -> String {
        let milliseconds = max(0, Int((value * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let seconds = milliseconds / 1_000 % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, String(separator), remainder)
    }
}

/// 외부 SRT / WebVTT 자막 파일을 타임스탬프 큐([TranscriptCue])로 파싱합니다.
public enum SubtitleParser {
    public static func parse(_ content: String) -> [TranscriptCue] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [TranscriptCue] = []
        cues.reserveCapacity(blocks.count)

        for rawBlock in blocks {
            let lines = rawBlock
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            if lines.first?.uppercased().hasPrefix("WEBVTT") == true { continue }

            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timeParts = lines[timeLineIndex].components(separatedBy: "-->")
            guard timeParts.count >= 2,
                  let start = parseTimestamp(timeParts[0]),
                  let end = parseTimestamp(timeParts[1].split(separator: " ").first.map(String.init) ?? timeParts[1]),
                  end > start else { continue }

            let textLines = lines[(timeLineIndex + 1)...]
                .map { stripTags($0) }
                .filter { !$0.isEmpty }
            guard !textLines.isEmpty else { continue }
            cues.append(TranscriptCue(startTime: start, endTime: end, text: textLines.joined(separator: "\n")))
        }
        return cues.sorted { $0.startTime < $1.startTime }
    }

    public static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return max(0, h * 3_600 + m * 60 + s)
        } else {
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return max(0, m * 60 + s)
        }
    }

    private static func stripTags(_ line: String) -> String {
        line.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
