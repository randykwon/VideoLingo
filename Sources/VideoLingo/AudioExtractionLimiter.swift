import VideoLingoCore
import Foundation

/// 오디오 추출 동시 실행 수를 제한합니다.
/// 추출은 로컬 CPU 작업이라, 원격 서버 자리 수만큼 늘리면 Mac이 과부하가 됩니다.
/// 원격 전사와는 별개 카운터로 관리해 서버가 유휴로 남지 않게 합니다.
actor AudioExtractionLimiter {
    static let shared = AudioExtractionLimiter()

    /// 성능 코어를 모두 추출에 내주면 STT·UI가 함께 느려지므로 한 자리를 남깁니다.
    private let limit: Int = {
        let performanceCores = Int(sysctlInt("hw.perflevel0.physicalcpu") ?? 4)
        return max(2, min(3, performanceCores - 1))
    }()

    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var maximumConcurrent: Int { limit }

    func withSlot<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
        active += 1
    }

    private func release() {
        active -= 1
        guard !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        next.resume()
    }
}

private func sysctlInt(_ name: String) -> Int64? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}

/// 중단된 작업이 남긴 오디오 추출 파일을 정리합니다.
/// 앱이 강제 종료되면 defer가 실행되지 않아 수백 MB가 그대로 남습니다.
enum RemoteAudioWorkspaceCleaner {
    @discardableResult
    static func removeOrphans() -> Int64 {
        guard let paths = try? AppPaths() else { return 0 }
        let fileManager = FileManager.default
        guard let jobs = try? fileManager.contentsOfDirectory(at: paths.jobs, includingPropertiesForKeys: nil) else {
            return 0
        }
        var reclaimed: Int64 = 0
        for job in jobs {
            let folder = job.appending(path: "RemoteAudio", directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: folder.path) else { continue }
            if let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) {
                for file in files {
                    reclaimed += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            try? fileManager.removeItem(at: folder)
        }
        return reclaimed
    }
}
