import Foundation

/// Picks one visible file per complete filename while preserving input order.
/// Accents remain meaningful; canonical Unicode spellings and case variants are equivalent.
public enum MediaFilenameDeduplicator {
    public static func representativeIndices(for urls: [URL], preferredURL: URL? = nil) -> [Int] {
        var positions: [String: Int] = [:]
        var indices: [Int] = []
        let preferred = preferredURL?.standardizedFileURL
        for (index, url) in urls.enumerated() {
            let key = url.lastPathComponent.precomposedStringWithCanonicalMapping
                .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            if let position = positions[key] {
                if url.standardizedFileURL == preferred { indices[position] = index }
            } else {
                positions[key] = indices.count
                indices.append(index)
            }
        }
        return indices
    }
}
