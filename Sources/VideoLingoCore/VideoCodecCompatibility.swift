import Foundation

/// 영상 파일의 코덱·컨테이너·타임스탬프·인터레이스 호환성 진단 결과입니다.
public enum VideoCompatibilityIssue: String, Codable, Sendable, Equatable, Hashable {
    case brokenFrameOrder       // B-프레임 PTS 역전 (AVPlayer 화면 떨림 원인)
    case interlaced             // 인터레이스 영상 (디인터레이스 필요)
    case unsupportedContainer   // MKV, WebM, AVI, FLV, WMV, TS 등 AVFoundation 미지원 컨테이너
    case unsupportedCodec       // VP8, VP9, AV1, MPEG-2, WMV, 10-bit H.264 등 AVFoundation 미지원/불안정 코덱
}

public struct VideoStreamProbeInfo: Codable, Sendable, Equatable {
    public let fileExtension: String
    public let codecName: String
    public let pixelFormat: String
    public let fieldOrder: String
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let duration: Double
    public let bitRate: Int
    public let hasAudio: Bool
    public let audioCodecName: String?
    public let interlacedFrames: Int
    public let sampledFrames: Int
    public let backwardsPTSCount: Int

    public init(
        fileExtension: String,
        codecName: String,
        pixelFormat: String = "yuv420p",
        fieldOrder: String = "progressive",
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Double = 30,
        duration: Double = 0,
        bitRate: Int = 6_000_000,
        hasAudio: Bool = true,
        audioCodecName: String? = "aac",
        interlacedFrames: Int = 0,
        sampledFrames: Int = 0,
        backwardsPTSCount: Int = 0
    ) {
        self.fileExtension = fileExtension
        self.codecName = codecName
        self.pixelFormat = pixelFormat
        self.fieldOrder = fieldOrder
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.duration = duration
        self.bitRate = bitRate
        self.hasAudio = hasAudio
        self.audioCodecName = audioCodecName
        self.interlacedFrames = interlacedFrames
        self.sampledFrames = sampledFrames
        self.backwardsPTSCount = backwardsPTSCount
    }
}

public struct VideoCompatibilityAssessment: Sendable, Equatable {
    public let info: VideoStreamProbeInfo
    public let issues: [VideoCompatibilityIssue]

    public init(info: VideoStreamProbeInfo, issues: [VideoCompatibilityIssue]) {
        self.info = info
        self.issues = issues
    }

    public var needsCompatibilityProxy: Bool { !issues.isEmpty }

    public var badgeTitle: String {
        if issues.contains(.brokenFrameOrder) { return "떨림 보정" }
        if issues.contains(.interlaced) { return "디인터레이스" }
        if issues.contains(.unsupportedCodec) || issues.contains(.unsupportedContainer) { return "코덱 호환" }
        return "호환 재생"
    }

    public var summary: String {
        guard !issues.isEmpty else { return "네이티브 재생 정상 (\(info.codecName.uppercased()))" }
        let labels = issues.map { issue -> String in
            switch issue {
            case .brokenFrameOrder: "B-프레임 PTS 역전(\(info.backwardsPTSCount)/\(max(1, info.sampledFrames)))"
            case .interlaced: "인터레이스(\(info.fieldOrder))"
            case .unsupportedContainer: "컨테이너(.\(info.fileExtension))"
            case .unsupportedCodec: "코덱(\(info.codecName)/\(info.pixelFormat))"
            }
        }
        return labels.joined(separator: " · ")
    }
}

/// FFprobe 메타데이터로 AVPlayer 직접 재생 가능 여부와 FFmpeg 호환 스트림 필요성을 판정합니다.
public enum VideoCodecCompatibilityAdvisor {
    private static let nativeContainers: Set<String> = ["mp4", "mov", "m4v"]
    private static let nativeVideoCodecs: Set<String> = ["h264", "hevc", "prores", "mpeg4"]
    private static let interlacedFieldOrders: Set<String> = ["tt", "bb", "tb", "bt"]

    public static func assess(_ info: VideoStreamProbeInfo) -> VideoCompatibilityAssessment {
        var issues: [VideoCompatibilityIssue] = []

        let ext = info.fileExtension.lowercased()
        if !ext.isEmpty && !nativeContainers.contains(ext) {
            issues.append(.unsupportedContainer)
        }

        let codec = info.codecName.lowercased()
        let pix = info.pixelFormat.lowercased()
        // H.264 10-bit(Hi10P)나 VP8/VP9/AV1/MPEG-2/WMV 등은 macOS AVPlayer에서 깨지거나 재생 불가
        let is10BitH264 = codec == "h264" && (pix.contains("10") || pix.contains("422") || pix.contains("444"))
        if (!codec.isEmpty && !nativeVideoCodecs.contains(codec)) || is10BitH264 {
            issues.append(.unsupportedCodec)
        }

        let field = info.fieldOrder.lowercased()
        if interlacedFieldOrders.contains(field) || (info.sampledFrames > 0 && info.interlacedFrames * 3 >= info.sampledFrames) {
            issues.append(.interlaced)
        }

        // B-프레임 CTTS 누락/오류로 디코딩 프레임의 PTS가 역전되는 경우(화면 앞뒤 떨림 원인)
        if info.backwardsPTSCount >= 2 {
            issues.append(.brokenFrameOrder)
        }

        return VideoCompatibilityAssessment(info: info, issues: issues)
    }

    /// FFmpeg 분수 프레임레이트 문자열("30000/1001" 등)을 Double로 파싱합니다.
    public static func parseFrameRate(_ raw: String?) -> Double {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return 30 }
        let parts = raw.split(separator: "/")
        if parts.count == 2,
           let num = Double(parts[0]),
           let den = Double(parts[1]),
           den > 0, num > 0 {
            let fps = num / den
            return (fps >= 5 && fps <= 240) ? fps : 30
        }
        if let direct = Double(raw), direct >= 5, direct <= 240 {
            return direct
        }
        return 30
    }

    /// 전체 재생 길이를 고정 세그먼트 길이의 HLS VOD 플레이리스트(.m3u8)로 즉시 생성합니다.
    /// VOD 플레이리스트를 미리 선언하므로 AVPlayer에서 전체 길이 표시와 임의 구간 즉시 탐색(시크)이 가능합니다.
    public static func buildVODPlaylist(
        duration: Double,
        segmentDuration: Double = 4.0,
        segmentURLPrefix: String = ""
    ) -> String {
        let safeDuration = max(0.5, duration.isFinite ? duration : 4.0)
        let safeSeg = max(1.0, segmentDuration)
        let count = max(1, Int(ceil(safeDuration / safeSeg)))
        let targetDuration = Int(ceil(safeSeg))

        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0"
        ]
        for index in 0..<count {
            let start = Double(index) * safeSeg
            let remaining = max(0.25, min(safeSeg, safeDuration - start))
            if index > 0 {
                // 각 세그먼트가 독립된 FFmpeg 호출로 인코딩되므로 세그먼트 경계의 PCR/AAC 프라이밍 리셋을 AVPlayer에 명시합니다.
                lines.append("#EXT-X-DISCONTINUITY")
            }
            lines.append(String(format: "#EXTINF:%.3f,", remaining))
            lines.append("\(segmentURLPrefix)seg_\(index).ts")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 세그먼트 인덱스에 해당하는 (시작 시각, 길이)를 계산합니다.
    public static func segmentBounds(
        index: Int,
        duration: Double,
        segmentDuration: Double = 4.0
    ) -> (start: Double, length: Double)? {
        guard index >= 0 else { return nil }
        let safeDuration = max(0.5, duration.isFinite ? duration : 4.0)
        let safeSeg = max(1.0, segmentDuration)
        let start = Double(index) * safeSeg
        guard start < safeDuration else { return nil }
        let length = max(0.25, min(safeSeg, safeDuration - start))
        return (start, length)
    }

    /// 호환 스트림용 FFmpeg 비디오 필터 체인을 조합합니다.
    public static func videoFilterChain(for assessment: VideoCompatibilityAssessment) -> String {
        var filters: [String] = []
        if assessment.issues.contains(.interlaced) {
            filters.append("yadif=mode=0:parity=-1:deint=0")
        }
        let fps = max(10, min(120, assessment.info.frameRate))
        // 프레임 표시 순서(POC) 기준으로 단조 증가 PTS를 재부여해 B-프레임 역전 떨림을 제거합니다.
        filters.append(String(format: "setpts=N/(%.6f)/TB", fps))
        filters.append("format=yuv420p")
        return filters.joined(separator: ",")
    }
}
