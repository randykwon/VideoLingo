import AVFoundation
import Foundation
import VideoLingoCore

/// 영상 파일 자체에 문제가 있는지 실제로 열어 보고 판정합니다.
/// 실패 메시지만으로는 파일 손상인지, 서버·디스크 같은 외부 요인인지 구분할 수 없어
/// 삭제 여부를 사용자가 판단하기 어렵습니다.
struct MediaDiagnosis: Sendable, Identifiable {
    enum Verdict: String, Sendable {
        case missing
        case unreadable
        case empty
        case corruptContainer
        case noAudioTrack
        case damagedAudio
        case healthy

        var title: String {
            switch self {
            case .missing: String(localized: "파일 없음")
            case .unreadable: String(localized: "읽기 권한 없음")
            case .empty: String(localized: "빈 파일")
            case .corruptContainer: String(localized: "파일 손상")
            case .noAudioTrack: String(localized: "오디오 없음")
            case .damagedAudio: String(localized: "오디오 손상")
            case .healthy: String(localized: "파일 정상")
            }
        }

        /// 파일을 지우는 게 타당한 경우입니다. 정상 파일은 다른 원인이므로 삭제 대상이 아닙니다.
        var isFileProblem: Bool {
            switch self {
            case .missing, .healthy, .unreadable: false
            case .empty, .corruptContainer, .noAudioTrack, .damagedAudio: true
            }
        }
    }

    let id: UUID
    let url: URL
    let verdict: Verdict
    let detail: String
    let byteCount: Int64
}

enum MediaDiagnostics {
    /// 파일을 단계적으로 확인합니다. 앞 단계에서 걸리면 뒤는 보지 않습니다.
    static func diagnose(itemID: UUID, url: URL) async -> MediaDiagnosis {
        let fileManager = FileManager.default
        func result(_ verdict: MediaDiagnosis.Verdict, _ detail: String, size: Int64 = 0) -> MediaDiagnosis {
            MediaDiagnosis(id: itemID, url: url, verdict: verdict, detail: detail, byteCount: size)
        }

        guard fileManager.fileExists(atPath: url.path) else {
            return result(.missing, String(localized: "지정한 경로에 파일이 없습니다. 이동했거나 외장 디스크가 연결되지 않았을 수 있습니다."))
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            return result(.unreadable, String(localized: "파일을 읽을 권한이 없습니다."))
        }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size > 0 else {
            return result(.empty, String(localized: "크기가 0바이트입니다."), size: size)
        }

        // 다운로드가 끊긴 파일은 용량만 잡히고 앞부분이 0으로 채워져 있습니다(실측).
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 16), head.allSatisfy({ $0 == 0 }) {
                return result(
                    .corruptContainer,
                    String(localized: "파일 앞부분이 비어 있습니다. 다운로드가 완료되지 않은 파일로 보입니다."),
                    size: size
                )
            }
        }

        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                return result(.corruptContainer, String(localized: "재생 길이를 읽을 수 없습니다."), size: size)
            }
        } catch {
            // moov atom이 없는 등 컨테이너가 깨진 경우 여기서 걸립니다.
            return result(
                .corruptContainer,
                String(localized: "영상을 열 수 없습니다: \(error.localizedDescription)"),
                size: size
            )
        }

        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard let track = audioTracks.first else {
            return result(.noAudioTrack, String(localized: "오디오 트랙이 없어 STT를 할 수 없습니다."), size: size)
        }

        // 오디오를 실제로 디코딩해 보는 단계입니다. 트랙은 있어도 내용이 깨진 경우가 있습니다.
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1
                ]
            )
            guard reader.canAdd(output) else {
                return result(.damagedAudio, String(localized: "오디오 형식을 디코딩할 수 없습니다."), size: size)
            }
            reader.add(output)
            guard reader.startReading(), output.copyNextSampleBuffer() != nil else {
                return result(
                    .damagedAudio,
                    String(localized: "오디오 디코딩에 실패했습니다: \(reader.error?.localizedDescription ?? "원인 불명")"),
                    size: size
                )
            }
            reader.cancelReading()
        } catch {
            return result(.damagedAudio, String(localized: "오디오를 읽을 수 없습니다: \(error.localizedDescription)"), size: size)
        }

        return result(
            .healthy,
            String(localized: "파일은 정상입니다. 서버·디스크 등 다른 원인을 확인하세요."),
            size: size
        )
    }
}
