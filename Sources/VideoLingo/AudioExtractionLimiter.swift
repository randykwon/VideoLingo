import AVFoundation
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

/// 원격 전사용 오디오를 16kHz 모노 AAC로 정규화해 내보냅니다.
///
/// `AVAssetExportPresetAppleM4A`는 원본 채널·샘플레이트를 그대로 옮기는데, 손상된 AAC 프레임이
/// 섞여 있으면 서버 ffmpeg가 `audio_decode_failed (channel element 0.0 duplicate)`로 거부합니다(실측).
/// 여기서는 PCM으로 완전히 디코딩한 뒤 다시 인코딩하므로 깨진 프레임이 결과에 남지 않고,
/// 서버가 어차피 16kHz 모노로 정규화하므로 전송량도 약 8분의 1로 줄어듭니다.
enum NormalizedAudioExporter {
    static func export(
        asset: AVURLAsset,
        start: TimeInterval = 0,
        duration: TimeInterval? = nil,
        to outputURL: URL
    ) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw VideoLingoError.mediaHasNoAudio
        }
        try? FileManager.default.removeItem(at: outputURL)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderAudioMixOutput(
            audioTracks: [track],
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        guard reader.canAdd(readerOutput) else { throw VideoLingoError.mediaHasNoAudio }
        reader.add(readerOutput)

        let sourceDuration = try await asset.load(.duration).seconds
        let boundedStart = max(0, min(start, sourceDuration))
        let boundedDuration = max(0, min(duration ?? (sourceDuration - boundedStart), sourceDuration - boundedStart))
        guard boundedDuration > 0 else { throw VideoLingoError.mediaHasNoAudio }
        let range = CMTimeRange(
            start: CMTime(seconds: boundedStart, preferredTimescale: 600),
            duration: CMTime(seconds: boundedDuration, preferredTimescale: 600)
        )
        reader.timeRange = range

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw VideoLingoError.mediaHasNoAudio }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? VideoLingoError.mediaHasNoAudio
        }
        guard writer.startWriting() else {
            throw writer.error ?? VideoLingoError.mediaHasNoAudio
        }
        // 두 번째 절반처럼 원본 중간부터 읽더라도 출력 파일의 시간축은 0부터 시작합니다.
        writer.startSession(atSourceTime: range.start)

        let queue = DispatchQueue(label: "com.vvv.VideoLingo.audio-normalize")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard let buffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        if reader.status == .failed {
                            writer.cancelWriting()
                            continuation.resume(throwing: reader.error ?? VideoLingoError.mediaHasNoAudio)
                        } else {
                            writer.finishWriting {
                                if writer.status == .completed {
                                    continuation.resume()
                                } else {
                                    continuation.resume(throwing: writer.error ?? VideoLingoError.mediaHasNoAudio)
                                }
                            }
                        }
                        return
                    }
                    if !writerInput.append(buffer) {
                        writerInput.markAsFinished()
                        writer.cancelWriting()
                        continuation.resume(throwing: writer.error ?? VideoLingoError.mediaHasNoAudio)
                        return
                    }
                }
            }
        }
    }
}

/// 외장 디스크에서 읽는 스트림을 제한하고, 나머지 파일은 내장 SSD로 옮겨 처리합니다.
///
/// 실측: USB ExFAT 외장에서 순차 읽기는 113MB/s인데, 디코딩은 랜덤 액세스가 섞여
/// 5.4GB 파일 추출에 3~5분이 걸립니다(CPU는 6%만 사용 — I/O 대기). 같은 볼륨에서
/// 여러 개를 동시에 추출하면 버스를 나눠 쓰며 전부 느려집니다.
/// 그래서 직접 추출은 한 번에 하나만 허용하고, 나머지는 순차 복사(빠름)로 SSD에 옮겨
/// 거기서 병렬 추출합니다.
actor ExternalMediaStager {
    static let shared = ExternalMediaStager()

    struct Prepared: Sendable {
        /// 실제로 읽을 위치입니다. 복사했다면 SSD 경로입니다.
        let url: URL
        let stagedCopy: URL?
        let holdsDirectSlot: Bool
        var didCopy: Bool { stagedCopy != nil }
    }

    private var directSlotBusy = false
    private var copyBusy = false
    private var copyWaiters: [CheckedContinuation<Void, Never>] = []

    /// 외장 볼륨 파일인지 판단합니다. 내장 SSD 파일은 제한 없이 그대로 처리합니다.
    private func isOnExternalVolume(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey]) else { return false }
        return values.volumeIsInternal == false
    }

    func prepare(
        mediaURL: URL,
        stagingDirectory: URL,
        onCopyStart: @Sendable () -> Void = {}
    ) async throws -> Prepared {
        guard isOnExternalVolume(mediaURL) else {
            return Prepared(url: mediaURL, stagedCopy: nil, holdsDirectSlot: false)
        }
        // 직접 추출 자리가 비어 있으면 복사 없이 바로 처리합니다.
        if !directSlotBusy {
            directSlotBusy = true
            return Prepared(url: mediaURL, stagedCopy: nil, holdsDirectSlot: true)
        }

        let fileManager = FileManager.default
        let size = Int64((try? mediaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let free = (try? stagingDirectory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        // 여유가 없으면 복사 대신 직접 추출 자리를 기다립니다.
        guard size > 0, free > size * 2 else {
            await waitForDirectSlot()
            return Prepared(url: mediaURL, stagedCopy: nil, holdsDirectSlot: true)
        }

        // 복사는 한 번에 하나씩. 순차 읽기라 디코딩보다 훨씬 빠릅니다.
        await acquireCopySlot()
        defer { releaseCopySlot() }
        onCopyStart()
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let destination = stagingDirectory.appending(path: mediaURL.lastPathComponent)
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: mediaURL, to: destination)
        return Prepared(url: destination, stagedCopy: destination, holdsDirectSlot: false)
    }

    func finish(_ prepared: Prepared) {
        if prepared.holdsDirectSlot {
            directSlotBusy = false
        }
        if let staged = prepared.stagedCopy {
            try? FileManager.default.removeItem(at: staged)
        }
    }

    private func acquireCopySlot() async {
        if !copyBusy {
            copyBusy = true
            return
        }
        await withCheckedContinuation { copyWaiters.append($0) }
        copyBusy = true
    }

    private func releaseCopySlot() {
        copyBusy = false
        guard !copyWaiters.isEmpty else { return }
        copyWaiters.removeFirst().resume()
    }

    private func waitForDirectSlot() async {
        while directSlotBusy {
            try? await Task.sleep(for: .seconds(2))
        }
        directSlotBusy = true
    }
}

/// 중단된 작업이 남긴 SSD 복사본을 정리합니다.
extension RemoteAudioWorkspaceCleaner {
    @discardableResult
    static func removeStagedCopies() -> Int64 {
        guard let paths = try? AppPaths() else { return 0 }
        let fileManager = FileManager.default
        guard let jobs = try? fileManager.contentsOfDirectory(at: paths.jobs, includingPropertiesForKeys: nil) else {
            return 0
        }
        var reclaimed: Int64 = 0
        for job in jobs {
            let folder = job.appending(path: "Staging", directoryHint: .isDirectory)
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
