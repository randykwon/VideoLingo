import Foundation

public enum TranslationTokenBudgetBackend: Sendable {
    case appleFoundation
    case mlx
    case externalServer
}

public enum TranslationTextSanitizer {
    /// LLM 응답에서 사고 과정(`<think>...</think>`, 닫히지 않은 `<think>...`),
    /// 마크다운 코드 펜스, 프롬프트 헤더 에코, 불필요한 외곽 따옴표를 제거합니다.
    public static func cleanLLMOutput(_ value: String, source: String? = nil) -> String {
        var text = value

        // 닫힌 <think>...</think> 블록 전부 제거
        if let closedThink = try? NSRegularExpression(
            pattern: #"(?is)<think\b[^>]*>.*?</think>"#
        ) {
            let range = NSRange(text.startIndex..., in: text)
            text = closedThink.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }

        // 스트리밍 중이거나 토큰 한도로 닫히지 않은 <think>... 꼬리 제거
        if let openThink = text.range(of: "<think", options: .caseInsensitive) {
            text = String(text[..<openThink.lowerBound])
        }

        // 고아 </think> 태그만 남은 경우 그 뒤만 채택
        if let strayClose = text.range(of: "</think>", options: [.caseInsensitive, .backwards]) {
            text = String(text[strayClose.upperBound...])
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 외곽 마크다운 코드 블록(언어 태그 포함) 제거
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(
                of: #"^```[^\n]*\n?"#,
                with: "",
                options: .regularExpression
            )
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.replacingOccurrences(of: "```", with: "")

        // 모델이 프롬프트 섹션 헤더를 그대로 따라 출력한 경우 제거
        text = text.replacingOccurrences(
            of: #"(?im)^(?:CURRENT SUBTITLE|TRANSLATED SUBTITLE|CORRECTED SUBTITLE|TRANSLATION|번역문|번역)\s*:\s*\n?"#,
            with: "",
            options: .regularExpression
        )

        text = text
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 원문에 외곽 따옴표가 없는데 모델이 단일 줄 전체를 따옴표로 감싼 경우 제거
        if let source, !text.contains("\n"), text.count >= 2 {
            let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
            let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'")]
            for (open, close) in quotePairs {
                if text.first == open && text.last == close
                    && !(trimmedSource.first == open && trimmedSource.last == close) {
                    let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !inner.isEmpty { text = inner }
                    break
                }
            }
        }

        return text
    }
}

public enum TranslationContextBuilder {
    /// 이전 문맥은 현재 청크와 맞닿은 뒷부분(tail)만 유지해 컨텍스트 초과와 프롬프트 오염을 방지합니다.
    public static func trimPreviousContext(_ chunks: [String], maxCharacters: Int = 400) -> [String] {
        let nonEmpty = chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty, maxCharacters > 0 else { return [] }

        var collected: [String] = []
        var remaining = maxCharacters
        for chunk in nonEmpty.reversed() {
            if chunk.count <= remaining {
                collected.append(chunk)
                remaining -= chunk.count
            } else {
                let tail = tailSnippet(of: chunk, limit: remaining)
                if !tail.isEmpty { collected.append(tail) }
                break
            }
            if remaining < 40 { break }
        }
        return collected.reversed()
    }

    /// 다음 문맥은 현재 청크 바로 뒤의 앞부분(head)만 유지합니다.
    public static func trimNextContext(_ chunks: [String], maxCharacters: Int = 250) -> [String] {
        let nonEmpty = chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = nonEmpty.first, maxCharacters > 0 else { return [] }
        if first.count <= maxCharacters { return [first] }
        let head = headSnippet(of: first, limit: maxCharacters)
        return head.isEmpty ? [] : [head]
    }

    /// 용어집이 클 때 현재 청크에 실제로 등장하는 항목만 추려 모델 집중도를 높입니다.
    public static func relevantGlossary(_ glossary: [GlossaryEntry], for source: String) -> [GlossaryEntry] {
        guard glossary.count > 12 else { return glossary }
        return glossary.filter { entry in
            !entry.source.isEmpty && TranslationQualityValidator.containsTerm(entry.source, in: source)
        }
    }

    /// 60초 다화자 청크가 512 토큰 상한에 잘리지 않도록 백엔드별 출력 토큰 예산을 계산합니다.
    public static func maxResponseTokens(
        for text: String,
        referenceText: String? = nil,
        backend: TranslationTokenBudgetBackend
    ) -> Int {
        let baseLength = max(text.count, referenceText?.count ?? 0)
        switch backend {
        case .appleFoundation:
            return min(1536, max(128, Int(Double(baseLength) * 2.2)))
        case .mlx:
            return min(2048, max(128, Int(Double(baseLength) * 2.5)))
        case .externalServer:
            return min(4096, max(1024, Int(Double(baseLength) * 3.0)))
        }
    }

    public static func buildPrompt(
        text: String,
        previousContext: [String],
        previousTranslations: [String] = [],
        nextContext: [String],
        glossary: [GlossaryEntry]
    ) -> String {
        let trimmedPrev = trimPreviousContext(previousContext, maxCharacters: 400)
        let trimmedPrevTranslations = trimPreviousContext(previousTranslations, maxCharacters: 400)
        let trimmedNext = trimNextContext(nextContext, maxCharacters: 250)
        let filteredGlossary = relevantGlossary(glossary, for: text)

        var sections: [String] = []
        if !trimmedPrev.isEmpty {
            let formatted = trimmedPrev.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            sections.append("PREVIOUS CONTEXT (reference only; do not translate):\n\(formatted)")
        }
        if !trimmedPrevTranslations.isEmpty {
            let formatted = trimmedPrevTranslations.joined(separator: "\n")
            sections.append("PREVIOUS TRANSLATION (match tone, honorifics, and terminology; do not repeat):\n\(formatted)")
        }
        sections.append("CURRENT SUBTITLE (translate this only):\n\(text)")
        if !trimmedNext.isEmpty {
            sections.append("NEXT CONTEXT (reference only; do not translate):\n\(trimmedNext.joined(separator: "\n"))")
        }
        if !filteredGlossary.isEmpty {
            let terms = filteredGlossary.map { "\($0.source) => \($0.target)" }.joined(separator: "\n")
            sections.append("REQUIRED GLOSSARY:\n\(terms)")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func tailSnippet(of text: String, limit: Int) -> String {
        let lines = text.split(separator: "\n").map(String.init)
        var picked: [String] = []
        var count = 0
        for line in lines.reversed() {
            let nextCount = count + line.count + (picked.isEmpty ? 0 : 1)
            if nextCount > limit {
                if picked.isEmpty {
                    picked.append(String(line.suffix(limit)))
                }
                break
            }
            picked.append(line)
            count = nextCount
        }
        return picked.reversed().joined(separator: "\n")
    }

    private static func headSnippet(of text: String, limit: Int) -> String {
        let lines = text.split(separator: "\n").map(String.init)
        var picked: [String] = []
        var count = 0
        for line in lines {
            let nextCount = count + line.count + (picked.isEmpty ? 0 : 1)
            if nextCount > limit {
                if picked.isEmpty {
                    picked.append(String(line.prefix(limit)))
                }
                break
            }
            picked.append(line)
            count = nextCount
        }
        return picked.joined(separator: "\n")
    }
}

public enum TranslationQualityValidator {
    /// 원문 언어와 대상 언어가 실질적으로 같은지 판별합니다 (예: "ko-KR" == "ko", "zh-Hans" != "zh-Hant").
    public static func isSameLanguage(_ sourceLanguage: String?, _ targetLanguage: String) -> Bool {
        guard let source = normalizedLanguageKey(sourceLanguage),
              let target = normalizedLanguageKey(targetLanguage) else { return false }
        return source == target
    }

    /// 원문과 번역문의 줄 수가 일치할 때, 모델이 화자 라벨을 번역하거나 누락한 경우 원래 라벨을 결정론적으로 복원합니다.
    public static func repairSpeakerLabelsIfAligned(source: String, translation: String) -> String {
        let sourceLines = source.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let translationLines = translation.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !sourceLines.isEmpty, sourceLines.count == translationLines.count else { return translation }
        let sourceLabels = sourceLines.map(leadingSpeakerLabel)
        guard sourceLabels.contains(where: { $0 != nil }) else { return translation }

        let repaired = zip(sourceLabels, translationLines).map { expectedLabel, line -> String in
            guard let expectedLabel else { return line }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(expectedLabel) { return trimmed }
            let body = strippingLeadingSpeakerLabel(from: trimmed)
            return body.isEmpty ? expectedLabel : "\(expectedLabel) \(body)"
        }
        return repaired.joined(separator: "\n")
    }

    /// 번역 초안의 구조적·의미적 결함을 점검합니다.
    public static func issues(
        source: String,
        translation: String,
        sourceLanguage: String?,
        targetLanguage: String,
        glossary: [GlossaryEntry]
    ) -> [String] {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranslation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else { return [] }
        if trimmedTranslation.isEmpty { return ["번역 결과 비어 있음"] }

        var found: [String] = []

        // 1. 줄별 화자 라벨 빈도 및 누락 검사 (같은 라벨이 여러 줄에 나올 때도 정확히 검증)
        let sourceLabels = speakerLabelCounts(in: trimmedSource)
        if !sourceLabels.isEmpty {
            let translationLabels = speakerLabelCounts(in: trimmedTranslation)
            if sourceLabels.contains(where: { translationLabels[$0.key, default: 0] < $0.value }) {
                found.append("화자 라벨 누락")
            }
        }

        // 2. 숫자 보존 검사 (화자 라벨 안의 숫자는 제외하고 천단위 구분자 차이는 허용)
        let sourceBody = removingAllLeadingSpeakerLabels(from: trimmedSource)
        let translationBody = removingAllLeadingSpeakerLabels(from: trimmedTranslation)
        let sourceNumbers = normalizedNumbers(in: sourceBody)
        if !sourceNumbers.isEmpty {
            let translationNumbers = Set(normalizedNumbers(in: translationBody))
            if sourceNumbers.contains(where: { !translationNumbers.contains($0) }) {
                found.append("숫자·시간·단위 누락 가능성")
            }
        }

        // 3. 필수 용어집 검사
        let missingTerms = glossary.filter {
            !$0.source.isEmpty && !$0.target.isEmpty
                && containsTerm($0.source, in: sourceBody)
                && !containsTerm($0.target, in: translationBody)
        }
        if !missingTerms.isEmpty {
            found.append("필수 용어 누락: \(missingTerms.map(\.source).joined(separator: ", "))")
        }

        // 4. 길이 비율 이상 검사 (짧은 CJK->영어 문장 오탐을 막기 위해 최소 바닥값 적용)
        if sourceBody.count >= 12 {
            let minLength = max(2, sourceBody.count / 8)
            let maxLength = max(48, sourceBody.count * 5)
            if translationBody.count < minLength || translationBody.count > maxLength {
                found.append("번역 길이 이상")
            }
        }

        // 5. 번역 누락(원문 그대로 반환) 검사
        if let sourceLanguage,
           !isSameLanguage(sourceLanguage, targetLanguage),
           sourceBody.count >= 12,
           containsLetters(sourceBody),
           normalizedComparisonText(sourceBody) == normalizedComparisonText(translationBody) {
            found.append("원문이 번역되지 않고 그대로 남음")
        }

        return found
    }

    /// 2차 검수 결과가 초안보다 악화되지 않았을 때만 채택합니다.
    public static func prefersRepaired(
        draft: String,
        repaired: String,
        draftIssues: [String],
        repairedIssues: [String],
        qualityMode: ProcessingQualityMode
    ) -> Bool {
        let trimmedRepaired = repaired.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepaired.isEmpty else { return false }
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDraft.isEmpty { return true }
        if repairedIssues.count < draftIssues.count { return true }
        if repairedIssues.count == draftIssues.count {
            return qualityMode == .maximum || repairedIssues.isEmpty
        }
        return false
    }

    /// 영숫자 용어는 단어 경계(\b)로 매칭해 "Term1"이 "Term19"에 오탐되는 현상을 막고,
    /// 한국어·일본어·중국어처럼 공백 경계가 없는 용어는 대소문자 무시 부분 매칭을 사용합니다.
    public static func containsTerm(_ term: String, in text: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let startsASCIIWord = trimmed.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
        let endsASCIIWord = trimmed.last.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
        guard startsASCIIWord || endsASCIIWord else {
            return text.localizedCaseInsensitiveContains(trimmed)
        }
        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        let prefix = startsASCIIWord ? #"(?<![A-Za-z0-9_])"# : ""
        let suffix = endsASCIIWord ? #"(?![A-Za-z0-9_])"# : ""
        guard let regex = try? NSRegularExpression(pattern: "\(prefix)\(escaped)\(suffix)", options: [.caseInsensitive]) else {
            return text.localizedCaseInsensitiveContains(trimmed)
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func normalizedLanguageKey(_ code: String?) -> String? {
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: "_", with: "-")
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") {
            return "zh-hant"
        }
        if normalized.hasPrefix("zh-hans") || normalized.hasPrefix("zh-cn") || normalized.hasPrefix("zh-sg") {
            return "zh-hans"
        }
        return normalized.split(separator: "-").first.map(String.init)
    }

    private static func leadingSpeakerLabel(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
        let label = String(trimmed[...close])
        return label.count <= 42 ? label : nil
    }

    private static func strippingLeadingSpeakerLabel(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let label = leadingSpeakerLabel(in: trimmed) else { return trimmed }
        return String(trimmed.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func speakerLabelCounts(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let label = leadingSpeakerLabel(in: String(line)) {
                counts[label, default: 0] += 1
            }
        }
        return counts
    }

    private static func removingAllLeadingSpeakerLabels(from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { strippingLeadingSpeakerLabel(from: String($0)) }
            .joined(separator: "\n")
    }

    private static func normalizedNumbers(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:[.,:]\d+)*"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            let raw = String(text[swiftRange])
            // 천단위 쉼표("1,000" -> "1000")만 정규화하고 소수점/시간(:)은 보존
            if raw.contains(",") && !raw.contains(":") {
                let parts = raw.split(separator: ",")
                if parts.count >= 2 && parts.dropFirst().allSatisfy({ $0.count == 3 }) {
                    return parts.joined()
                }
            }
            return raw
        }
    }

    private static func containsLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func normalizedComparisonText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
    }
}
