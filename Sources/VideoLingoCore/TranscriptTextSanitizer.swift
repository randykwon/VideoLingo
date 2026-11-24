import Foundation

public enum TranscriptTextSanitizer {
    /// Whisper 특수 토큰, 제어 문자, 비정상 반복 루프를 정리합니다.
    public static func cleanWhisperText(_ value: String) -> String {
        let stripped = value
            .replacingOccurrences(of: #"<\|.*?\|>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\u{200B}\u{FEFF}]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return "" }
        return collapseRepetitionLoops(in: stripped)
    }

    /// Whisper가 무음·배경음악 구간에서 만들어 내는 대표적인 환각 문구인지 판별합니다.
    /// 실제 발화(예: 영상 끝인사)를 지우지 않도록, 문구 패턴 매칭은 무음 확률이 높거나 로그 확률이 낮을 때만 작동합니다.
    public static func isLikelyHallucination(
        _ text: String,
        noSpeechProb: Double,
        avgLogprob: Double
    ) -> Bool {
        let cleaned = cleanWhisperText(text)
        guard !cleaned.isEmpty else { return true }

        // 음악·박수·무음 표시 태그나 구두점·기호만으로 구성된 경우
        let withoutBracketNoise = cleaned.replacingOccurrences(
            of: #"(?i)[\[\(（【]\s*(?:music|음악|배경음악|bgm|applause|박수|laughter|웃음|silence|무음|소음|noise|blank_audio)\s*[\]\)）】]"#,
            with: "",
            options: .regularExpression
        )
        let strippedSymbols = withoutBracketNoise.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
        if strippedSymbols.isEmpty { return true }

        // 낮은 신뢰도 또는 높은 무음 확률일 때만 알려진 Whisper 환각 상투구를 차단합니다.
        guard noSpeechProb >= 0.35 || avgLogprob < -0.65 else { return false }
        let normalized = cleaned
            .lowercased()
            .replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
        return knownHallucinationPatterns.contains { normalized == $0 || (normalized.count <= $0.count + 8 && normalized.contains($0)) }
    }

    /// 겹침(overlap)이 있는 오디오 청크의 자막 큐를 절대 타임스탬프로 변환하고,
    /// 각 큐의 중심 시각(midpoint)을 기준으로 정확히 한 청크에만 귀속시켜 경계 중복 자막을 제거합니다.
    public static func assignChunkCues(
        _ cues: [TranscriptCue],
        extractionStart: TimeInterval,
        chunkStart: TimeInterval,
        chunkEnd: TimeInterval,
        isLastChunk: Bool
    ) -> [TranscriptCue] {
        guard chunkEnd > chunkStart else { return [] }
        return cues.compactMap { cue -> TranscriptCue? in
            let cleanedText = cleanWhisperText(cue.text)
            guard !cleanedText.isEmpty, cue.endTime > cue.startTime else { return nil }
            let absStart = extractionStart + cue.startTime
            let absEnd = extractionStart + cue.endTime
            let midpoint = (absStart + absEnd) / 2
            let ownedByStart = chunkStart == 0 ? true : midpoint >= chunkStart
            let ownedByEnd = isLastChunk ? midpoint <= chunkEnd : midpoint < chunkEnd
            guard ownedByStart && ownedByEnd else { return nil }
            let clampedStart = max(chunkStart, min(chunkEnd, absStart))
            let clampedEnd = max(clampedStart, min(chunkEnd, absEnd))
            guard clampedEnd > clampedStart else { return nil }
            return TranscriptCue(startTime: clampedStart, endTime: clampedEnd, text: cleanedText)
        }
    }

    /// 자동 감지된 언어를 전체 작업의 기준 언어로 고정해도 안전한지 판별합니다.
    /// 짧은 감탄사·배경음 위주의 첫 청크 때문에 잘못된 언어로 고정되는 문제를 막습니다.
    public static func shouldLockDetectedLanguage(
        candidate: String?,
        text: String,
        confidence: Double?,
        recentDetections: [String]
    ) -> String? {
        guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty,
              let confidence else { return nil }
        let body = text
            .replacingOccurrences(of: #"(?m)^\s*\[[^\]\n]{1,40}\]\s*"#, with: "", options: .regularExpression)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
        // 한·중·일 문자는 라틴 문자보다 글자당 정보 밀도가 높으므로 가중 길이(CJK=2)로 판정합니다.
        let weightedLength = body.unicodeScalars.reduce(into: 0) { total, scalar in
            total += isCJK(scalar) ? 2 : 1
        }
        guard weightedLength >= 6 else { return nil }
        if weightedLength >= 15 && confidence >= 0.55 {
            return raw
        }
        if confidence >= 0.35 && recentDetections.contains(raw) {
            return raw
        }
        return nil
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana & Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xAC00...0xD7AF: // Hangul Syllables
            return true
        default:
            return false
        }
    }

    private static let knownHallucinationPatterns: [String] = [
        "시청해주셔서감사합니다",
        "시청해줘서감사합니다",
        "구독과좋아요",
        "좋아요와구독",
        "mbc뉴스이덕영입니다",
        "mbc뉴스",
        "sbs뉴스",
        "kbs뉴스",
        "한글자막",
        "자막제공",
        "다음영상에서만나요",
        "고맙습니다시청해주셔서",
        "ご視聴ありがとうございました",
        "ご視聴ありがとうございます",
        "チャンネル登録お願いします",
        "チャンネル登録よろしくお願いします",
        "字幕制作",
        "thanksforwatching",
        "thankyouforwatching",
        "pleasesubscribe",
        "likeandsubscribe",
        "subtitlesby",
        "amaraorg",
        "transcribedby",
        "captionedby"
    ]

    /// 동일 단어나 짧은 구절이 5회 이상 연속 반복되는 Whisper 루프를 축약합니다.
    private static func collapseRepetitionLoops(in text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var result = String(line)
            // 공백 구분 단어 반복 (예: "네 네 네 네 네 네" -> "네")
            if let wordRegex = try? NSRegularExpression(pattern: #"(?i)(\S{1,20})(?:[\s,、]+(?:\1)){4,}"#) {
                let range = NSRange(result.startIndex..., in: result)
                result = wordRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
            }
            // 공백 없는 짧은 구절 반복 (CJK 포함, 예: "ああああああ" / "はい。はい。はい。はい。はい。")
            if let phraseRegex = try? NSRegularExpression(pattern: #"(.{2,16}?)(?:\1){4,}"#) {
                let range = NSRange(result.startIndex..., in: result)
                result = phraseRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
            }
            return result.trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
