import Foundation

public enum SegmentQualityComparator {
    public static func prefersCandidate(_ candidate: TranscriptSegment, over existing: TranscriptSegment) -> Bool {
        let candidateText = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingText = existing.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateText.isEmpty else { return false }
        if existingText.isEmpty { return true }

        let candidateRank = qualityRank(candidate.qualityStatus)
        let existingRank = qualityRank(existing.qualityStatus)
        if candidateRank != existingRank { return candidateRank > existingRank }

        switch (candidate.confidence, existing.confidence) {
        case let (candidateConfidence?, existingConfidence?):
            return candidateConfidence >= existingConfidence + 0.03
        case (_?, nil):
            return true
        default:
            return false
        }
    }

    public static func prefersCandidate(_ candidate: TranslationSegment, over existing: TranslationSegment) -> Bool {
        let candidateText = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingText = existing.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateText.isEmpty else { return false }
        if existingText.isEmpty { return true }

        let candidateRank = qualityRank(candidate.qualityStatus)
        let existingRank = qualityRank(existing.qualityStatus)
        if candidateRank != existingRank { return candidateRank > existingRank }

        return existing.qualityStatus == .warning
            && (candidate.qualityNotes?.count ?? 0) < (existing.qualityNotes?.count ?? 0)
    }

    private static func qualityRank(_ status: SegmentQualityStatus?) -> Int {
        switch status {
        case .good: 2
        case .reviewed: 1
        case .warning, nil: 0
        }
    }
}
