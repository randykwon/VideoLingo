import Foundation

public enum TranscriptCoverage {
    /// STT가 두 가지 디코딩 경로를 확인한 뒤 실제 무음으로 판정한 청크에 기록합니다.
    public static let verifiedSilenceNote = "음성 없음 확인"
    /// 직전 STT 문장을 디코더 프롬프트로 주입하지 않은 상태에서 재확인했음을 나타냅니다.
    public static let promptFreeVerificationNote = "문맥 프롬프트 없이 재검증"

    /// VAD가 아무 문장도 찾지 못한 결과는 무음으로 확정하기 전에 비-VAD 방식으로 검증해야 합니다.
    public static func requiresNonVADVerification(vadText: String) -> Bool {
        vadText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func hasCompleteCheckpoint(_ segment: TranscriptSegment) -> Bool {
        if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let notes = segment.qualityNotes ?? []
        return notes.contains(verifiedSilenceNote) && notes.contains(promptFreeVerificationNote)
    }

    public static func missingChunkIndices(
        transcripts: some Sequence<TranscriptSegment>,
        totalChunks: Int
    ) -> [Int] {
        guard totalChunks > 0 else { return [] }
        let completed = Set(transcripts.lazy.filter(hasCompleteCheckpoint).map(\.chunkIndex))
        return (0..<totalChunks).filter { !completed.contains($0) }
    }

    public static func completedChunkCount(
        transcripts: some Sequence<TranscriptSegment>,
        totalChunks: Int
    ) -> Int {
        totalChunks - missingChunkIndices(transcripts: transcripts, totalChunks: totalChunks).count
    }
}

/// Immutable interval index for playback. Preserves source order for overlapping cues.
/// Prefix end times let gaps and arbitrary seeks skip unrelated subtitles.
public struct PlaybackSubtitleIndex: Sendable {
    private struct Entry: Sendable {
        let start: Double
        let end: Double
        let segment: Int
    }
    private let entries: [Entry]
    private let maximumEnds: [Double]

    public init(_ transcript: [TranscriptSegment]) {
        var intervals: [Entry] = []
        for (index, segment) in transcript.enumerated() {
            let cues = segment.cues ?? []
            if cues.isEmpty {
                intervals.append(Entry(start: segment.startTime, end: segment.endTime, segment: index))
            } else {
                intervals.append(contentsOf: cues.map { Entry(start: $0.startTime, end: $0.endTime, segment: index) })
            }
        }
        entries = intervals.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var maximum = -Double.infinity
        maximumEnds = entries.map { maximum = max(maximum, $0.end); return maximum }
    }

    public func segmentIndex(at time: Double) -> Int? {
        guard time.isFinite else { return nil }
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        var cursor = low - 1
        var result: Int?
        while cursor >= 0, maximumEnds[cursor] > time {
            let entry = entries[cursor]
            if time < entry.end { result = min(result ?? entry.segment, entry.segment) }
            cursor -= 1
        }
        return result
    }
}
