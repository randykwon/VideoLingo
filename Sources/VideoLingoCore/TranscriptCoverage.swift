import Foundation

public enum TranscriptCoverage {
    /// STT가 두 가지 디코딩 경로를 확인한 뒤 실제 무음으로 판정한 청크에 기록합니다.
    public static let verifiedSilenceNote = "음성 없음 확인"

    /// VAD가 아무 문장도 찾지 못한 결과는 무음으로 확정하기 전에 비-VAD 방식으로 검증해야 합니다.
    public static func requiresNonVADVerification(vadText: String) -> Bool {
        vadText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func hasCompleteCheckpoint(_ segment: TranscriptSegment) -> Bool {
        !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (segment.qualityNotes?.contains(verifiedSilenceNote) ?? false)
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
