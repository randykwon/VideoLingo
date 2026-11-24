import AppKit
import Foundation
import Observation
import VideoLingoCore

/// 3가지 영상 복원·제거 트랙(CoreML / MLX FlashVSR / ComfyUI · uv MPS)의
/// 설치 상태 확인, 원클릭 설치/가중치 다운로드, ComfyUI 서버 진단을 관리합니다.
@MainActor
@Observable
final class VideoEnhancerSetupManager {
    static let shared = VideoEnhancerSetupManager()

    struct ComfyUIProbeResult: Sendable {
        let reachable: Bool
        let summary: String
        let hasVHS: Bool
        let hasSeedVR2: Bool
        let hasWanVACE: Bool
    }

    private(set) var installedCoreMLIDs: Set<String> = []
    private(set) var flashVSRBinaryInstalled = false
    private(set) var flashVSRWeightsInstalled = false
    private(set) var wanVACEWeightsInstalled = false
    private(set) var seedVR2WeightsInstalled = false
    private(set) var uvInstalled = false
    private(set) var workerScriptFound = false

    private(set) var isProbingComfyUI = false
    private(set) var comfyProbe: ComfyUIProbeResult?

    private(set) var isRunningSetup = false
    private(set) var activeSetupTarget: String?
    private(set) var setupStatusMessage = ""
    private(set) var setupLogTail: [String] = []
    private(set) var setupError: String?

    @ObservationIgnored private var setupProcess: Process?

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        let fm = FileManager.default
        let demosaicDir = VideoRestorationPaths.demosaicModelsDirectory()

        var coreML: Set<String> = []
        for preset in VideoRestorationCatalog.coreMLPresets {
            if VideoRestorationPaths.coreMLModelExists(id: preset.id) {
                coreML.insert(preset.id)
            }
        }
        installedCoreMLIDs = coreML
        flashVSRBinaryInstalled = fm.isExecutableFile(atPath: VideoRestorationPaths.defaultFlashVSRBinaryURL().path)
        flashVSRWeightsInstalled = VideoRestorationPaths.flashVSRWeightsExist()
        wanVACEWeightsInstalled = fm.fileExists(atPath: demosaicDir.appending(path: "Wan2.1-VACE-1.3B").path)
        seedVR2WeightsInstalled = fm.fileExists(atPath: demosaicDir.appending(path: "SeedVR2-3B").path)
        uvInstalled = [
            NSHomeDirectory() + "/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv"
        ].contains { fm.isExecutableFile(atPath: $0) }
        workerScriptFound = VideoRestorationPaths.defaultLocalWorkerScriptURL() != nil
    }

    func isReady(model: DemosaicModel, backend: VideoEnhancerBackend) -> Bool {
        switch model {
        case .classical:
            return true
        case .lamaCoreML:
            return installedCoreMLIDs.contains("lama")
        case .realESRGAN:
            return installedCoreMLIDs.contains("realesrgan")
        case .gfpganCoreML:
            return installedCoreMLIDs.contains("gfpgan")
        case .codeFormer:
            return installedCoreMLIDs.contains("codeformer")
        case .flashVSRMLX:
            return flashVSRBinaryInstalled && flashVSRWeightsInstalled
        case .wanVACE:
            if backend == .comfyUI {
                return comfyProbe?.reachable == true && comfyProbe?.hasVHS == true && comfyProbe?.hasWanVACE == true
            }
            return uvInstalled && workerScriptFound && wanVACEWeightsInstalled
        case .seedVR2:
            if backend == .comfyUI {
                return comfyProbe?.reachable == true && comfyProbe?.hasVHS == true && comfyProbe?.hasSeedVR2 == true
            }
            return uvInstalled && workerScriptFound && seedVR2WeightsInstalled
        }
    }

    func probeComfyUI(baseURLString: String) {
        guard !isProbingComfyUI else { return }
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: trimmed.isEmpty ? "http://127.0.0.1:8188" : trimmed) else {
            comfyProbe = ComfyUIProbeResult(
                reachable: false,
                summary: "ComfyUI 주소 형식이 올바르지 않습니다.",
                hasVHS: false,
                hasSeedVR2: false,
                hasWanVACE: false
            )
            return
        }
        isProbingComfyUI = true
        Task {
            defer { isProbingComfyUI = false }
            do {
                var statsReq = URLRequest(url: baseURL.appending(path: "system_stats"))
                statsReq.timeoutInterval = 5
                let (statsData, statsResp) = try await URLSession.shared.data(for: statsReq)
                guard let http = statsResp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    comfyProbe = ComfyUIProbeResult(
                        reachable: false,
                        summary: "ComfyUI 응답 오류 (HTTP \((statsResp as? HTTPURLResponse)?.statusCode ?? 0))",
                        hasVHS: false,
                        hasSeedVR2: false,
                        hasWanVACE: false
                    )
                    return
                }
                var deviceName = "Apple Silicon"
                if let statsJSON = try? JSONSerialization.jsonObject(with: statsData) as? [String: Any],
                   let devices = statsJSON["devices"] as? [[String: Any]],
                   let first = devices.first,
                   let name = first["name"] as? String {
                    deviceName = name
                }

                var infoReq = URLRequest(url: baseURL.appending(path: "object_info"))
                infoReq.timeoutInterval = 8
                let (infoData, _) = try await URLSession.shared.data(for: infoReq)
                let infoJSON = (try? JSONSerialization.jsonObject(with: infoData) as? [String: Any]) ?? [:]
                let hasVHS = infoJSON["VHS_LoadVideo"] != nil && infoJSON["VHS_VideoCombine"] != nil
                let hasSeedVR2 = infoJSON["SeedVR2VideoUpscaler"] != nil
                let hasWanVACE = infoJSON["WanVaceToVideo"] != nil

                var tags: [String] = []
                tags.append(hasVHS ? "VHS ✓" : "VHS 미설치")
                tags.append(hasWanVACE ? "WanVACE ✓" : "WanVACE 미설치")
                tags.append(hasSeedVR2 ? "SeedVR2 ✓" : "SeedVR2 미설치")

                comfyProbe = ComfyUIProbeResult(
                    reachable: true,
                    summary: "연결됨 (\(deviceName)) · " + tags.joined(separator: " / "),
                    hasVHS: hasVHS,
                    hasSeedVR2: hasSeedVR2,
                    hasWanVACE: hasWanVACE
                )
            } catch {
                comfyProbe = ComfyUIProbeResult(
                    reachable: false,
                    summary: "연결 불가 · ComfyUI를 \(baseURL.absoluteString)에서 먼저 실행하세요.",
                    hasVHS: false,
                    hasSeedVR2: false,
                    hasWanVACE: false
                )
            }
        }
    }

    func runSetupScript(target: String, label: String) {
        guard !isRunningSetup else { return }
        guard let scriptURL = VideoRestorationPaths.defaultSetupScriptURL() else {
            setupError = "설치 스크립트(scripts/setup_video_enhancers.sh)를 찾지 못했습니다."
            return
        }
        isRunningSetup = true
        activeSetupTarget = target
        setupError = nil
        setupLogTail = []
        setupStatusMessage = "\(label) 준비 중…"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, target]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        setupProcess = process

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            let lines = chunk.split(whereSeparator: \.isNewline).map(String.init)
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.setupLogTail.append(line)
                    if self.setupLogTail.count > 12 {
                        self.setupLogTail.removeFirst(self.setupLogTail.count - 12)
                    }
                    self.setupStatusMessage = String(line.prefix(90))
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setupProcess = nil
                self.isRunningSetup = false
                self.activeSetupTarget = nil
                self.refreshStatus()
                if status == 0 {
                    self.setupStatusMessage = "\(label) 설치 완료"
                } else if reason == .uncaughtSignal {
                    self.setupStatusMessage = "설치가 취소되었습니다."
                } else {
                    self.setupError = "\(label) 설치 실패 (코드 \(status)). 아래 로그를 확인해 주세요."
                }
            }
        }

        do {
            try process.run()
        } catch {
            setupProcess = nil
            isRunningSetup = false
            activeSetupTarget = nil
            setupError = error.localizedDescription
        }
    }

    func cancelSetup() {
        setupProcess?.terminate()
    }

    func revealModelsFolder() {
        let dir = VideoRestorationPaths.demosaicModelsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func chooseWorkflowJSON() -> String? {
        let panel = NSOpenPanel()
        panel.title = "ComfyUI API 워크플로 JSON 선택"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
