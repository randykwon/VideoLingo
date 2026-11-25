import Foundation
import NaturalLanguage

/// STT 원문과 번역을 한 문장 단위로 묶어 표시하기 위한 정렬 항목입니다.
public struct AlignedSentenceItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let segmentID: UUID
    public let chunkIndex: Int
    public let sentenceNumber: Int
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let speaker: String?
    public let originalText: String
    public let translatedText: String?
    public let sttQualityStatus: SegmentQualityStatus?
    public let sttQualityNotes: [String]
    public let translationQualityStatus: SegmentQualityStatus?
    public let translationQualityNotes: [String]

    public init(
        id: String,
        segmentID: UUID,
        chunkIndex: Int,
        sentenceNumber: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speaker: String? = nil,
        originalText: String,
        translatedText: String?,
        sttQualityStatus: SegmentQualityStatus? = nil,
        sttQualityNotes: [String] = [],
        translationQualityStatus: SegmentQualityStatus? = nil,
        translationQualityNotes: [String] = []
    ) {
        self.id = id
        self.segmentID = segmentID
        self.chunkIndex = chunkIndex
        self.sentenceNumber = sentenceNumber
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
        self.originalText = originalText
        self.translatedText = translatedText
        self.sttQualityStatus = sttQualityStatus
        self.sttQualityNotes = sttQualityNotes
        self.translationQualityStatus = translationQualityStatus
        self.translationQualityNotes = translationQualityNotes
    }
}

/// 60초 단위 청크(TranscriptSegment + TranslationSegment)의 큐/줄을
/// 한 문장 단위의 (원문, 번역, 타임스탬프) 쌍으로 정리합니다.
public enum SentenceAlignmentGrouper {
    private struct RawPair {
        var startTime: TimeInterval
        var endTime: TimeInterval
        var speaker: String?
        var originalBody: String
        var translatedBody: String?
        var mergedCount: Int = 1
    }

    /// 전체 전사·번역 결과를 한 문장 단위 목록으로 변환합니다.
    public static func group(
        transcript: [TranscriptSegment],
        translations: [UUID: TranslationSegment]
    ) -> [AlignedSentenceItem] {
        var result: [AlignedSentenceItem] = []
        var globalIndex = 1

        for segment in transcript {
            let translation = translations[segment.id]
            let rawPairs = extractPairs(segment: segment, translation: translation)
            let merged = mergeSentenceFragments(rawPairs)

            for (localIndex, pair) in merged.enumerated() {
                let originalFull = formatWithSpeaker(pair.speaker, body: pair.originalBody)
                let translatedFull = pair.translatedBody.flatMap { body -> String? in
                    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    return formatWithSpeaker(pair.speaker, body: trimmed)
                }
                result.append(AlignedSentenceItem(
                    id: "\(segment.id.uuidString):\(localIndex)",
                    segmentID: segment.id,
                    chunkIndex: segment.chunkIndex,
                    sentenceNumber: globalIndex,
                    startTime: pair.startTime,
                    endTime: max(pair.startTime, pair.endTime),
                    speaker: pair.speaker,
                    originalText: originalFull,
                    translatedText: translatedFull,
                    sttQualityStatus: segment.qualityStatus,
                    sttQualityNotes: segment.qualityNotes ?? [],
                    translationQualityStatus: translation?.qualityStatus,
                    translationQualityNotes: translation?.qualityNotes ?? []
                ))
                globalIndex += 1
            }
        }
        return result
    }

    /// 현재 재생 시각에 해당하는 문장 인덱스를 빠르게 찾습니다.
    public static func activeIndex(in items: [AlignedSentenceItem], at currentTime: TimeInterval) -> Int? {
        guard !items.isEmpty, currentTime.isFinite else { return nil }
        // 이진 탐색으로 startTime <= currentTime인 마지막 후보 주변을 확인합니다.
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].startTime <= currentTime {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let candidate = low - 1
        if candidate >= 0 {
            let item = items[candidate]
            if currentTime >= item.startTime && currentTime <= item.endTime {
                return candidate
            }
            // 직전 문장이 살짝 겹치거나 짧은 간격인 경우
            if candidate > 0 {
                let prev = items[candidate - 1]
                if currentTime >= prev.startTime && currentTime <= prev.endTime {
                    return candidate - 1
                }
            }
        }
        return nil
    }

    // MARK: - 내부 분해 · 병합 로직

    private static func extractPairs(
        segment: TranscriptSegment,
        translation: TranslationSegment?
    ) -> [RawPair] {
        let translatedRaw = translation?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let translatedLines = nonEmptyLines(translatedRaw)
        let timedCues = (segment.cues ?? []).filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if !timedCues.isEmpty {
            if translatedLines.isEmpty {
                return timedCues.flatMap { cue in
                    expandCueIfNeeded(
                        startTime: cue.startTime,
                        endTime: cue.endTime,
                        originalText: cue.text,
                        translatedText: nil
                    )
                }
            }

            if translatedLines.count == timedCues.count {
                return zip(timedCues, translatedLines).flatMap { cue, trLine in
                    expandCueIfNeeded(
                        startTime: cue.startTime,
                        endTime: cue.endTime,
                        originalText: cue.text,
                        translatedText: trLine
                    )
                }
            }

            // 줄 수가 어긋난 경우: 문장 단위 분할 수가 일치하면 문장 단위로 1:1 정렬합니다.
            let originalSentences = splitIntoSentences(segment.text)
            let translatedSentences = splitIntoSentences(translatedRaw)
            if !originalSentences.isEmpty && originalSentences.count == translatedSentences.count {
                return interpolatePairs(
                    originals: originalSentences,
                    translations: translatedSentences,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
            }

            // 그 외에는 큐 목록을 번역 줄 수에 비례 배분해 어떤 내용도 유실되지 않게 합니다.
            return alignMismatchedCounts(cues: timedCues, translatedLines: translatedLines)
        }

        // cues가 없는 레거시/단일 블록 세그먼트 처리
        let originalLines = nonEmptyLines(segment.text)
        if originalLines.count > 1 && originalLines.count == translatedLines.count {
            return interpolatePairs(
                originals: originalLines,
                translations: translatedLines,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
        }

        let originalSentences = splitIntoSentences(segment.text)
        if translatedRaw.isEmpty {
            if originalSentences.count > 1 {
                return interpolatePairs(
                    originals: originalSentences,
                    translations: Array(repeating: nil, count: originalSentences.count),
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
            }
            let parsed = splitSpeaker(segment.text)
            return [RawPair(
                startTime: segment.startTime,
                endTime: segment.endTime,
                speaker: parsed.speaker,
                originalBody: parsed.body,
                translatedBody: nil
            )]
        }

        let translatedSentences = splitIntoSentences(translatedRaw)
        if originalSentences.count > 1 && originalSentences.count == translatedSentences.count {
            return interpolatePairs(
                originals: originalSentences,
                translations: translatedSentences,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
        }

        let srcParsed = splitSpeaker(segment.text)
        let trParsed = splitSpeaker(translatedRaw)
        return [RawPair(
            startTime: segment.startTime,
            endTime: segment.endTime,
            speaker: srcParsed.speaker ?? trParsed.speaker,
            originalBody: srcParsed.body,
            translatedBody: trParsed.body
        )]
    }

    /// 단일 큐에 여러 완전한 문장이 들어 있고 번역도 같은 문장 수로 나뉘면 1문장씩 분리합니다.
    private static func expandCueIfNeeded(
        startTime: TimeInterval,
        endTime: TimeInterval,
        originalText: String,
        translatedText: String?
    ) -> [RawPair] {
        let srcParsed = splitSpeaker(originalText)
        let trParsed = translatedText.map(splitSpeaker)
        let speaker = srcParsed.speaker ?? trParsed?.speaker

        let srcSentences = splitIntoSentences(srcParsed.body)
        if let trBody = trParsed?.body {
            let trSentences = splitIntoSentences(trBody)
            if srcSentences.count > 1 && srcSentences.count == trSentences.count {
                return interpolatePairs(
                    originals: srcSentences.map { formatWithSpeaker(speaker, body: $0) },
                    translations: trSentences.map { formatWithSpeaker(speaker, body: $0) },
                    startTime: startTime,
                    endTime: endTime
                )
            }
        } else if srcSentences.count > 1 {
            return interpolatePairs(
                originals: srcSentences.map { formatWithSpeaker(speaker, body: $0) },
                translations: Array(repeating: nil, count: srcSentences.count),
                startTime: startTime,
                endTime: endTime
            )
        }

        return [RawPair(
            startTime: startTime,
            endTime: endTime,
            speaker: speaker,
            originalBody: srcParsed.body,
            translatedBody: trParsed?.body
        )]
    }

    private static func alignMismatchedCounts(
        cues: [TranscriptCue],
        translatedLines: [String]
    ) -> [RawPair] {
        guard !cues.isEmpty else { return [] }
        if translatedLines.count < cues.count {
            // 큐가 번역 줄보다 많으면 인접 큐를 균등 그룹으로 묶어 각 번역 줄에 대응합니다.
            let targetCount = translatedLines.count
            var pairs: [RawPair] = []
            for groupIdx in 0..<targetCount {
                let startIdx = groupIdx * cues.count / targetCount
                let endIdx = max(startIdx + 1, (groupIdx + 1) * cues.count / targetCount)
                let slice = cues[startIdx..<min(endIdx, cues.count)]
                guard let first = slice.first, let last = slice.last else { continue }
                let firstParsed = splitSpeaker(first.text)
                let trParsed = splitSpeaker(translatedLines[groupIdx])
                let combinedSrc = slice.map { splitSpeaker($0.text).body }
                    .reduce("") { smartJoin($0, $1) }
                pairs.append(RawPair(
                    startTime: first.startTime,
                    endTime: last.endTime,
                    speaker: firstParsed.speaker ?? trParsed.speaker,
                    originalBody: combinedSrc,
                    translatedBody: trParsed.body
                ))
            }
            return pairs
        } else {
            // 번역 줄이 큐보다 많으면 각 큐에 번역 줄을 비례 분배합니다.
            let targetCount = cues.count
            var pairs: [RawPair] = []
            for idx in 0..<targetCount {
                let startTr = idx * translatedLines.count / targetCount
                let endTr = max(startTr + 1, (idx + 1) * translatedLines.count / targetCount)
                let trSlice = translatedLines[startTr..<min(endTr, translatedLines.count)]
                let cue = cues[idx]
                let srcParsed = splitSpeaker(cue.text)
                let combinedTr = trSlice.map { splitSpeaker($0).body }
                    .reduce("") { smartJoin($0, $1) }
                pairs.append(RawPair(
                    startTime: cue.startTime,
                    endTime: cue.endTime,
                    speaker: srcParsed.speaker,
                    originalBody: srcParsed.body,
                    translatedBody: combinedTr
                ))
            }
            return pairs
        }
    }

    private static func interpolatePairs(
        originals: [String],
        translations: [String?],
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [RawPair] {
        let duration = max(0, endTime - startTime)
        let weights = originals.map { max(1, Double($0.count)) }
        let totalWeight = max(1, weights.reduce(0, +))
        var cursor = startTime
        var pairs: [RawPair] = []

        for (index, original) in originals.enumerated() {
            let share = duration * (weights[index] / totalWeight)
            let itemEnd = (index == originals.count - 1) ? endTime : min(endTime, cursor + share)
            let srcParsed = splitSpeaker(original)
            let trParsed = (index < translations.count ? translations[index] : nil).map(splitSpeaker)
            pairs.append(RawPair(
                startTime: cursor,
                endTime: max(cursor, itemEnd),
                speaker: srcParsed.speaker ?? trParsed?.speaker,
                originalBody: srcParsed.body,
                translatedBody: trParsed?.body
            ))
            cursor = itemEnd
        }
        return pairs
    }

    /// 문장 끝 부호 없이 끊긴 짧은 인접 조각을 한 문장으로 합칩니다.
    private static func mergeSentenceFragments(_ input: [RawPair]) -> [RawPair] {
        guard !input.isEmpty else { return [] }
        var merged: [RawPair] = []

        for item in input {
            let trimmedOriginal = item.originalBody.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedOriginal.isEmpty else { continue }
            var current = item
            current.originalBody = trimmedOriginal
            current.translatedBody = item.translatedBody?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard var last = merged.last else {
                merged.append(current)
                continue
            }

            if shouldMerge(previous: last, next: current) {
                last.endTime = max(last.endTime, current.endTime)
                last.originalBody = smartJoin(last.originalBody, current.originalBody)
                switch (last.translatedBody, current.translatedBody) {
                case (let lhs?, let rhs?) where !lhs.isEmpty && !rhs.isEmpty:
                    last.translatedBody = smartJoin(lhs, rhs)
                case (nil, let rhs?):
                    last.translatedBody = rhs
                case (let lhs?, nil):
                    last.translatedBody = lhs
                default:
                    break
                }
                last.mergedCount += 1
                merged[merged.count - 1] = last
            } else {
                merged.append(current)
            }
        }
        return merged
    }

    private static func shouldMerge(previous: RawPair, next: RawPair) -> Bool {
        // 화자가 바뀌면 무조건 새 문장
        if previous.speaker != next.speaker { return false }
        // 침묵 간격이 1.8초 이상이면 새 문장
        if next.startTime - previous.endTime > 1.8 { return false }
        // 이미 문장이 종결 부호로 끝났으면 새 문장
        if endsWithSentenceBoundary(previous.originalBody) { return false }
        // 번역문이 종결 부호로 끝났고 원문도 충분히 길면(구두점 없는 자막 대비) 분리 유지
        if let tr = previous.translatedBody, endsWithSentenceBoundary(tr), previous.originalBody.count >= 36 {
            return false
        }
        // 너무 길어지지 않도록 병합 상한 적용
        if previous.mergedCount >= 4 { return false }
        if previous.originalBody.count + next.originalBody.count > 200 { return false }
        return true
    }

    public static func splitIntoSentences(_ text: String) -> [String] {
        let cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = cleaned
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: cleaned.startIndex..<cleaned.endIndex) { range, _ in
            let token = cleaned[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                sentences.append(token)
            }
            return true
        }
        return sentences.isEmpty ? [cleaned] : sentences
    }

    private static func endsWithSentenceBoundary(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // 닫는 따옴표/괄호는 건너뛰고 직전 문장 부호를 확인합니다.
        let closingWrappers = CharacterSet(charactersIn: "\"'”’」』)]）】")
        var idx = trimmed.endIndex
        while idx > trimmed.startIndex {
            let prev = trimmed.index(before: idx)
            let ch = trimmed[prev]
            if ch.unicodeScalars.allSatisfy({ closingWrappers.contains($0) }) {
                idx = prev
                continue
            }
            return ".!?。！？…".contains(ch)
        }
        return false
    }

    private static func nonEmptyLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func splitSpeaker(_ text: String) -> (speaker: String?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else {
            return (nil, trimmed)
        }
        let tag = String(trimmed[trimmed.startIndex...close])
        let rest = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard tag.count <= 42, !rest.isEmpty else {
            return (nil, trimmed)
        }
        return (tag, rest)
    }

    private static func formatWithSpeaker(_ speaker: String?, body: String) -> String {
        guard let speaker, !speaker.isEmpty else { return body }
        if body.hasPrefix(speaker) { return body }
        return "\(speaker) \(body)"
    }

    private static func smartJoin(_ lhs: String, _ rhs: String) -> String {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        // 일본어/중국어처럼 띄어쓰기 없이 이어지는 문자 사이는 공백 없이 연결하고, 한국어/영어 등은 공백 추가
        if let lastScalar = a.unicodeScalars.last, let firstScalar = b.unicodeScalars.first,
           isNoSpaceCJK(lastScalar) && isNoSpaceCJK(firstScalar) {
            return a + b
        }
        return "\(a) \(b)"
    }

    private static func isNoSpaceCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana / Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF: // CJK Unified Ideographs
            return true
        default:
            return false
        }
    }
}
