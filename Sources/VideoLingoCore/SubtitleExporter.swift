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
