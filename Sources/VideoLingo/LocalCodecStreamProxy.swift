import Foundation
import Network
import VideoLingoCore

/// 로컬 환경(앱 번들 · Application Support · Homebrew)에서 ffmpeg / ffprobe 실행 파일을 찾습니다.
enum FFmpegToolLocator {
    static func executable(named tool: String) -> URL? {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support", directoryHint: .isDirectory)
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appending(path: "ManagedRuntime/\(tool)"))
        }
        candidates.append(appSupport.appending(path: "VideoLingo/ManagedRuntime/\(tool)"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(tool)"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/\(tool)"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/\(tool)"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    static var isAvailable: Bool {
        executable(named: "ffmpeg") != nil && executable(named: "ffprobe") != nil
    }
}

/// 영상 파일을 빠르게(약 70ms) 점검해 B-프레임 PTS 역전(화면 떨림), 인터레이스,
/// AVFoundation 미지원 코덱/컨테이너 여부를 판정합니다.
actor VideoCompatibilityInspector {
    static let shared = VideoCompatibilityInspector()

    private struct CacheKey: Hashable {
        let path: String
        let fileSize: Int64
        let modifiedTime: TimeInterval
    }

    private var cache: [CacheKey: VideoCompatibilityAssessment] = [:]

    func inspect(url: URL) async -> VideoCompatibilityAssessment? {
        guard let ffprobe = FFmpegToolLocator.executable(named: "ffprobe") else { return nil }
        let std = url.standardizedFileURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: std.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mod = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = CacheKey(path: std.path, fileSize: size, modifiedTime: mod)
        if let cached = cache[key] {
            return cached
        }

        guard let info = await Self.probeVideo(url: std, ffprobe: ffprobe) else { return nil }
        let assessment = VideoCodecCompatibilityAdvisor.assess(info)
        cache[key] = assessment
        return assessment
    }

    private static func probeVideo(url: URL, ffprobe: URL) async -> VideoStreamProbeInfo? {
        // 1단계: 스트림·컨테이너 메타데이터 조회
        guard let metaData = await runCapture(
            executable: ffprobe,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration:stream=codec_type,codec_name,pix_fmt,field_order,width,height,r_frame_rate,avg_frame_rate,bit_rate,duration",
                "-of", "json",
                url.path
            ]
        ),
              let root = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]],
              let video = streams.first(where: { ($0["codec_type"] as? String) == "video" }) else {
            return nil
        }

        let audio = streams.first(where: { ($0["codec_type"] as? String) == "audio" })
        let formatDict = root["format"] as? [String: Any]
        let duration = parseDouble(formatDict?["duration"]) ?? parseDouble(video["duration"]) ?? 0
        let codecName = (video["codec_name"] as? String ?? "").lowercased()
        let pixFmt = (video["pix_fmt"] as? String ?? "yuv420p").lowercased()
        let fieldOrder = (video["field_order"] as? String ?? "progressive").lowercased()
        let width = (video["width"] as? Int) ?? 1920
        let height = (video["height"] as? Int) ?? 1080
        let rFPS = VideoCodecCompatibilityAdvisor.parseFrameRate(video["r_frame_rate"] as? String)
        let avgFPS = VideoCodecCompatibilityAdvisor.parseFrameRate(video["avg_frame_rate"] as? String)
        let fps = (rFPS >= 5 && rFPS <= 120) ? rFPS : avgFPS
        let bitRate = Int(parseDouble(video["bit_rate"]) ?? 6_000_000)

        // 2단계: 25프레임 샘플링으로 B-프레임 PTS 역전(화면 떨림) 및 인터레이스 플래그 검사
        let sampleStart = duration > 45 ? 30.0 : max(0, duration * 0.15)
        var backwardsPTS = 0
        var interlacedFrames = 0
        var sampledFrames = 0

        if let frameData = await runCapture(
            executable: ffprobe,
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "frame=pts_time,interlaced_frame",
                "-read_intervals", String(format: "%.1f%%+#25", sampleStart),
                "-of", "json",
                url.path
            ]
        ),
           let frameRoot = try? JSONSerialization.jsonObject(with: frameData) as? [String: Any],
           let frames = frameRoot["frames"] as? [[String: Any]] {
            sampledFrames = frames.count
            var previousPTS: Double?
            for fr in frames {
                if (fr["interlaced_frame"] as? Int) == 1 {
                    interlacedFrames += 1
                }
                if let pts = parseDouble(fr["pts_time"]) {
                    if let prev = previousPTS, pts < prev - 0.0005 {
                        backwardsPTS += 1
                    }
                    previousPTS = pts
                }
            }
        }

        return VideoStreamProbeInfo(
            fileExtension: url.pathExtension.lowercased(),
            codecName: codecName,
            pixelFormat: pixFmt,
            fieldOrder: fieldOrder,
            width: width,
            height: height,
            frameRate: fps,
            duration: duration,
            bitRate: max(1_500_000, min(20_000_000, bitRate)),
            hasAudio: audio != nil,
            audioCodecName: (audio?["codec_name"] as? String)?.lowercased(),
            interlacedFrames: interlacedFrames,
            sampledFrames: sampledFrames,
            backwardsPTSCount: backwardsPTS
        )
    }

    private static func parseDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d.isFinite ? d : nil }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s), d.isFinite { return d }
        return nil
    }

    private static func runCapture(executable: URL, arguments: [String]) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = executable
                proc.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    continuation.resume(returning: proc.terminationStatus == 0 ? data : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// FFmpeg(VideoToolbox 하드웨어 인코더) 기반 로컬 온디맨드 HLS VOD 스트리밍 프록시입니다.
/// - B-프레임 PTS 역전으로 화면이 떨리는 MP4
/// - 인터레이스 영상
/// - MKV / WebM / VP9 / AV1 / 10-bit H.264 / MPEG-2 / WMV 등 AVFoundation 미지원 영상
/// 을 4초 단위 세그먼트로 즉시 보정·변환해 AVPlayer에서 끊김 없이 재생 및 임의 탐색(시크)할 수 있게 합니다.
final class LocalCodecStreamProxy: @unchecked Sendable {
    static let shared = LocalCodecStreamProxy()

    struct Session: Sendable {
        let id: String
        let sourceURL: URL
        let assessment: VideoCompatibilityAssessment
        let playlistURL: URL
    }

    private final class SessionState {
        let id: String
        let sourceURL: URL
        let assessment: VideoCompatibilityAssessment
        let segmentDuration: Double = 4.0
        var cache: [Int: Data] = [:]
        var cacheOrder: [Int] = []
        var inFlight: [Int: Task<Data, Error>] = [:]

        init(id: String, sourceURL: URL, assessment: VideoCompatibilityAssessment) {
            self.id = id
            self.sourceURL = sourceURL
            self.assessment = assessment
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.vvv.VideoLingo.LocalCodecStreamProxy", qos: .userInitiated)
    private var listener: NWListener?
    private var port: UInt16?
    private var sessions: [String: SessionState] = [:]

    func openSession(for url: URL, assessment: VideoCompatibilityAssessment) throws -> Session {
        guard FFmpegToolLocator.executable(named: "ffmpeg") != nil else {
            throw VideoLingoError.modelUnavailable("호환 재생에 필요한 ffmpeg를 찾을 수 없습니다. (brew install ffmpeg)")
        }
        let activePort = try ensureServerRunning()
        let sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let state = SessionState(id: sessionID, sourceURL: url.standardizedFileURL, assessment: assessment)
        lock.withLock {
            sessions[sessionID] = state
        }
        let playlistURL = URL(string: "http://127.0.0.1:\(activePort)/hls/\(sessionID)/index.m3u8")!
        return Session(id: sessionID, sourceURL: url.standardizedFileURL, assessment: assessment, playlistURL: playlistURL)
    }

    func releaseSession(_ id: String) {
        let removed: SessionState? = lock.withLock {
            sessions.removeValue(forKey: id)
        }
        removed?.inFlight.values.forEach { $0.cancel() }
        removed?.inFlight.removeAll()
        removed?.cache.removeAll()
    }

    func shutdown() {
        let all: [SessionState] = lock.withLock {
            let values = Array(sessions.values)
            sessions.removeAll()
            listener?.cancel()
            listener = nil
            port = nil
            return values
        }
        for s in all {
            s.inFlight.values.forEach { $0.cancel() }
            s.inFlight.removeAll()
            s.cache.removeAll()
        }
    }

    // MARK: - Loopback HTTP 서버

    private func ensureServerRunning() throws -> UInt16 {
        if let existing = lock.withLock({ port }) {
            return existing
        }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let newListener = try NWListener(using: params)
        let readySem = DispatchSemaphore(value: 0)
        var startError: Error?

        newListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let boundPort = newListener.port?.rawValue {
                    self?.lock.withLock {
                        self?.listener = newListener
                        self?.port = boundPort
                    }
                }
                readySem.signal()
            case .failed(let err):
                startError = err
                readySem.signal()
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        newListener.start(queue: queue)
        _ = readySem.wait(timeout: .now() + 3)

        if let startError { throw startError }
        guard let boundPort = lock.withLock({ port }) else {
            throw VideoLingoError.serviceUnavailable
        }
        return boundPort
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, let requestText = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let firstLine = requestText.split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.sendResponse(connection, status: "400 Bad Request", contentType: "text/plain", body: Data())
                return
            }
            let method = String(parts[0]).uppercased()
            let path = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
            let isHead = (method == "HEAD")

            Task.detached(priority: .userInitiated) {
                await self.route(path: path, headOnly: isHead, connection: connection)
            }
        }
    }

    private func route(path: String, headOnly: Bool, connection: NWConnection) async {
        // /hls/<sessionID>/index.m3u8 또는 /hls/<sessionID>/seg_<N>.ts
        let comps = path.split(separator: "/").map(String.init)
        guard comps.count == 3, comps[0] == "hls" else {
            sendResponse(connection, status: "404 Not Found", contentType: "text/plain", body: Data())
            return
        }
        let sessionID = comps[1]
        let file = comps[2]

        guard let state = lock.withLock({ sessions[sessionID] }) else {
            sendResponse(connection, status: "404 Not Found", contentType: "text/plain", body: Data())
            return
        }

        if file == "index.m3u8" {
            let playlist = VideoCodecCompatibilityAdvisor.buildVODPlaylist(
                duration: state.assessment.info.duration,
                segmentDuration: state.segmentDuration
            )
            let body = Data(playlist.utf8)
            sendResponse(
                connection,
                status: "200 OK",
                contentType: "application/vnd.apple.mpegurl",
                body: headOnly ? Data() : body,
                contentLengthOverride: body.count
            )
            return
        }

        if file.hasPrefix("seg_"), file.hasSuffix(".ts") {
            let numStr = file.dropFirst("seg_".count).dropLast(".ts".count)
            guard let index = Int(numStr),
                  VideoCodecCompatibilityAdvisor.segmentBounds(
                    index: index,
                    duration: state.assessment.info.duration,
                    segmentDuration: state.segmentDuration
                  ) != nil else {
                sendResponse(connection, status: "404 Not Found", contentType: "text/plain", body: Data())
                return
            }
            do {
                let tsData = try await fetchOrRenderSegment(sessionID: sessionID, index: index)
                sendResponse(
                    connection,
                    status: "200 OK",
                    contentType: "video/mp2t",
                    body: headOnly ? Data() : tsData,
                    contentLengthOverride: tsData.count
                )
                // 다음 세그먼트를 백그라운드에서 미리 준비해 재생 경계 지연을 없앱니다.
                prefetchSegmentIfValid(sessionID: sessionID, index: index + 1)
            } catch {
                sendResponse(connection, status: "500 Internal Server Error", contentType: "text/plain", body: Data())
            }
            return
        }

        sendResponse(connection, status: "404 Not Found", contentType: "text/plain", body: Data())
    }

    private func prefetchSegmentIfValid(sessionID: String, index: Int) {
        guard let state = lock.withLock({ sessions[sessionID] }),
              VideoCodecCompatibilityAdvisor.segmentBounds(
                index: index,
                duration: state.assessment.info.duration,
                segmentDuration: state.segmentDuration
              ) != nil else { return }
        Task.detached(priority: .utility) { [weak self] in
            _ = try? await self?.fetchOrRenderSegment(sessionID: sessionID, index: index)
        }
    }

    private func fetchOrRenderSegment(sessionID: String, index: Int) async throws -> Data {
        let cachedOrTask: (cached: Data?, task: Task<Data, Error>?) = lock.withLock {
            guard let state = sessions[sessionID] else { return (nil, nil) }
            if let hit = state.cache[index] {
                return (hit, nil)
            }
            if let existingTask = state.inFlight[index] {
                return (nil, existingTask)
            }
            let sourceURL = state.sourceURL
            let assessment = state.assessment
            let segDuration = state.segmentDuration
            let task = Task<Data, Error>(priority: .userInitiated) {
                try await Self.renderSegment(
                    sourceURL: sourceURL,
                    assessment: assessment,
                    index: index,
                    segmentDuration: segDuration
                )
            }
            state.inFlight[index] = task
            return (nil, task)
        }

        if let hit = cachedOrTask.cached {
            return hit
        }
        guard let task = cachedOrTask.task else {
            throw CancellationError()
        }

        do {
            let data = try await task.value
            lock.withLock {
                guard let state = sessions[sessionID] else { return }
                state.inFlight.removeValue(forKey: index)
                state.cache[index] = data
                state.cacheOrder.removeAll { $0 == index }
                state.cacheOrder.append(index)
                while state.cacheOrder.count > 16 {
                    let evicted = state.cacheOrder.removeFirst()
                    state.cache.removeValue(forKey: evicted)
                }
            }
            return data
        } catch {
            lock.withLock {
                sessions[sessionID]?.inFlight.removeValue(forKey: index)
            }
            throw error
        }
    }

    private static func renderSegment(
        sourceURL: URL,
        assessment: VideoCompatibilityAssessment,
        index: Int,
        segmentDuration: Double
    ) async throws -> Data {
        guard let ffmpeg = FFmpegToolLocator.executable(named: "ffmpeg"),
              let bounds = VideoCodecCompatibilityAdvisor.segmentBounds(
                index: index,
                duration: assessment.info.duration,
                segmentDuration: segmentDuration
              ) else {
            throw VideoLingoError.invalidPayload
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appending(path: "vl-hls-\(UUID().uuidString).ts")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let filterChain = VideoCodecCompatibilityAdvisor.videoFilterChain(for: assessment)
        let targetBitrateK = max(2000, min(14000, assessment.info.bitRate / 1000))

        var args: [String] = [
            "-y",
            "-v", "error",
            "-ss", String(format: "%.6f", bounds.start),
            "-t", String(format: "%.6f", bounds.length),
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-vf", filterChain,
            "-c:v", "h264_videotoolbox",
            "-b:v", "\(targetBitrateK)k",
            "-allow_sw", "1"
        ]
        if assessment.info.hasAudio {
            args += [
                "-map", "0:a:0?",
                "-c:a", "aac",
                "-b:a", "192k",
                "-af", "aresample=async=1:first_pts=0"
            ]
        } else {
            args += ["-an"]
        }
        args += [
            "-muxdelay", "0",
            "-muxpreload", "0",
            "-output_ts_offset", String(format: "%.6f", bounds.start),
            "-f", "mpegts",
            tempFile.path
        ]

        try await runProcess(executable: ffmpeg, arguments: args)
        return try Data(contentsOf: tempFile)
    }

    private static func runProcess(executable: URL, arguments: [String]) async throws {
        final class ProcBox: @unchecked Sendable {
            let process: Process
            init(_ p: Process) { self.process = p }
        }
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let box = ProcBox(proc)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.process.terminationHandler = { finished in
                    if finished.terminationStatus == 0 {
                        continuation.resume()
                    } else if finished.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: VideoLingoError.modelUnavailable("ffmpeg 세그먼트 변환 실패 (코드 \(finished.terminationStatus))"))
                    }
                }
                do {
                    try box.process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }

    private func sendResponse(
        _ connection: NWConnection,
        status: String,
        contentType: String,
        body: Data,
        contentLengthOverride: Int? = nil
    ) {
        let length = contentLengthOverride ?? body.count
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(length)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
