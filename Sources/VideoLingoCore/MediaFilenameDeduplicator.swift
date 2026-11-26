import CryptoKit
import Foundation

public enum MediaDuplicateReason: String, Sendable, Equatable, CaseIterable, Identifiable {
    case sameFilename
    case identicalContent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sameFilename: "같은 파일명"
        case .identicalContent: "동일 내용 (크기·해시)"
        }
    }
}

public struct MediaDuplicateGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let reason: MediaDuplicateReason
    public let title: String
    public let byteCount: Int64
    public let urls: [URL]

    public init(id: String, reason: MediaDuplicateReason, title: String, byteCount: Int64, urls: [URL]) {
        self.id = id
        self.reason = reason
        self.title = title
        self.byteCount = byteCount
        self.urls = urls
    }

    public var reclaimableBytes: Int64 {
        guard urls.count > 1 else { return 0 }
        return max(0, byteCount) * Int64(urls.count - 1)
    }
}

/// Picks one visible file per complete filename while preserving input order,
/// and finds duplicate filename / identical content groups across media libraries and Multi-View.
/// Accents remain meaningful; canonical Unicode spellings and case variants are equivalent.
public enum MediaFilenameDeduplicator {
    public static func canonicalFilenameKey(for url: URL) -> String {
        url.lastPathComponent.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func representativeIndices(for urls: [URL], preferredURL: URL? = nil) -> [Int] {
        var positions: [String: Int] = [:]
        var indices: [Int] = []
        let preferred = preferredURL?.standardizedFileURL
        for (index, url) in urls.enumerated() {
            let key = canonicalFilenameKey(for: url)
            if let position = positions[key] {
                if url.standardizedFileURL == preferred { indices[position] = index }
            } else {
                positions[key] = indices.count
                indices.append(index)
            }
        }
        return indices
    }

    /// 같은 파일명(대소문자·유니코드 정규화 무시)을 가진 서로 다른 경로의 파일 묶음을 반환합니다.
    public static func filenameDuplicateGroups(for urls: [URL], sizesByPath: [String: Int64] = [:]) -> [MediaDuplicateGroup] {
        var uniqueByPath: [String: URL] = [:]
        for url in urls {
            let std = url.standardizedFileURL
            uniqueByPath[std.path(percentEncoded: false)] = std
        }
        let grouped = Dictionary(grouping: uniqueByPath.values) { canonicalFilenameKey(for: $0) }
        return grouped.compactMap { key, members -> MediaDuplicateGroup? in
            guard members.count > 1 else { return nil }
            let sorted = members.sorted {
                $0.path(percentEncoded: false).localizedStandardCompare($1.path(percentEncoded: false)) == .orderedAscending
            }
            let firstSize = sizesByPath[sorted[0].path(percentEncoded: false)]
                ?? ((try? sorted[0].resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
            return MediaDuplicateGroup(
                id: "name:\(key)",
                reason: .sameFilename,
                title: sorted[0].lastPathComponent,
                byteCount: firstSize,
                urls: sorted
            )
        }
        .sorted { lhs, rhs in
            if lhs.urls.count != rhs.urls.count { return lhs.urls.count > rhs.urls.count }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    /// 파일 크기 + 앞/중간/뒤 샘플 SHA-256 해시로 파일명이 달라도 내용이 완전히 같은 중복 영상 묶음을 찾습니다.
    public static func contentDuplicateGroups(
        for urls: [URL],
        sampleLength: Int = 4 * 1024 * 1024
    ) throws -> [MediaDuplicateGroup] {
        var uniqueByPath: [String: URL] = [:]
        for url in urls {
            let std = url.standardizedFileURL
            uniqueByPath[std.path(percentEncoded: false)] = std
        }

        // 1단계: 파일 크기로 후보를 좁힙니다. 크기가 다르면 내용이 다릅니다.
        var candidatesBySize: [Int64: [URL]] = [:]
        for url in uniqueByPath.values {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0 else { continue }
            candidatesBySize[Int64(size), default: []].append(url)
        }

        let safeSample = max(4096, sampleLength)
        var groups: [MediaDuplicateGroup] = []

        for (size, sameSizeURLs) in candidatesBySize where sameSizeURLs.count > 1 {
            var byDigest: [String: [URL]] = [:]
            for url in sameSizeURLs {
                try Task.checkCancellation()
                guard let digest = contentFingerprint(for: url, fileSize: size, sampleLength: safeSample) else { continue }
                byDigest[digest, default: []].append(url)
            }
            for (digest, members) in byDigest where members.count > 1 {
                let sorted = members.sorted {
                    $0.path(percentEncoded: false).localizedStandardCompare($1.path(percentEncoded: false)) == .orderedAscending
                }
                groups.append(MediaDuplicateGroup(
                    id: "content:\(size):\(digest)",
                    reason: .identicalContent,
                    title: sorted[0].lastPathComponent,
                    byteCount: size,
                    urls: sorted
                ))
            }
        }

        return groups.sorted { lhs, rhs in
            if lhs.reclaimableBytes != rhs.reclaimableBytes { return lhs.reclaimableBytes > rhs.reclaimableBytes }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func contentFingerprint(for url: URL, fileSize: Int64, sampleLength: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        var sizeLE = fileSize.littleEndian
        withUnsafeBytes(of: &sizeLE) { hasher.update(bufferPointer: $0) }

        if fileSize <= Int64(sampleLength) * 3 {
            // 작은 파일은 전체 바이트를 해시합니다.
            while let chunk = try? handle.read(upToCount: sampleLength), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } else {
            // 대용량 영상은 앞 + 중간 + 뒤 샘플을 해시해 빠르게 동일 내용을 판별합니다.
            if let head = try? handle.read(upToCount: sampleLength) {
                hasher.update(data: head)
            }
            let midOffset = UInt64(max(0, (fileSize - Int64(sampleLength)) / 2))
            try? handle.seek(toOffset: midOffset)
            if let mid = try? handle.read(upToCount: sampleLength) {
                hasher.update(data: mid)
            }
            let tailOffset = UInt64(max(0, fileSize - Int64(sampleLength)))
            try? handle.seek(toOffset: tailOffset)
            if let tail = try? handle.read(upToCount: sampleLength) {
                hasher.update(data: tail)
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
