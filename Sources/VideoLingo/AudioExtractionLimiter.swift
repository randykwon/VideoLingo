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
    static func export(asset: AVURLAsset, to outputURL: URL) async throws {
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
        writer.startSession(atSourceTime: .zero)

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
