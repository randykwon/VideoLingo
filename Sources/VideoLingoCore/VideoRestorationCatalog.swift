import Foundation

/// 1번 트랙(CoreML 네이티브) 원클릭 다운로드 프리셋 정의입니다.
public struct CoreMLRestorationPreset: Identifiable, Sendable, Equatable {
    public let id: String          // Models/Demosaic/<id>.mlpackage
    public let model: DemosaicModel
    public let title: String
    public let sizeDescription: String
    public let license: String
    public let summary: String
    public let downloadURL: URL?

    public init(
        id: String,
        model: DemosaicModel,
        title: String,
        sizeDescription: String,
        license: String,
        summary: String,
        downloadURL: URL?
    ) {
        self.id = id
        self.model = model
        self.title = title
        self.sizeDescription = sizeDescription
        self.license = license
        self.summary = summary
        self.downloadURL = downloadURL
    }
}

public enum VideoRestorationCatalog {
    public static let flashVSRRepoID = "mlx-community/FlashVSR-v1.1-bf16"
    public static let flashVSRSwiftRepoURL = "https://github.com/xocialize/mlx-flashvsr-swift.git"
    public static let wanVACERepoID = "Wan-AI/Wan2.1-VACE-1.3B"
    public static let seedVR2RepoID = "numz/SeedVR2_comfyUI"

    public static let coreMLPresets: [CoreMLRestorationPreset] = [
        CoreMLRestorationPreset(
            id: "lama",
            model: .lamaCoreML,
            title: "LaMa (영역 제거 · 인페인팅)",
            sizeDescription: "187 MB",
            license: "Apache 2.0",
            summary: "마스크 영역 주변 문맥으로 로고·자막·모자이크 영역을 자연스럽게 메웁니다. (800×800)",
            downloadURL: URL(string: "https://huggingface.co/mlboydaisuke/coreml-zoo/resolve/main/lama/LaMa.mlpackage.zip")
        ),
        CoreMLRestorationPreset(
            id: "realesrgan",
            model: .realESRGAN,
            title: "Real-ESRGAN ×4 (화질 · 블록 복원)",
            sizeDescription: "62 MB",
            license: "BSD-3",
            summary: "저화질·압축 깨짐·블록 노이즈를 완화하고 선명도를 높입니다.",
            downloadURL: URL(string: "https://huggingface.co/mlboydaisuke/coreml-zoo/resolve/main/realesrgan/RealESRGAN_x4.mlpackage.zip")
        ),
        CoreMLRestorationPreset(
            id: "gfpgan",
            model: .gfpganCoreML,
            title: "GFPGAN (얼굴 복원)",
            sizeDescription: "312 MB",
            license: "Apache 2.0",
            summary: "얼굴 영역의 흐림과 열화를 보완하는 전용 CoreML 복원 모델입니다.",
            downloadURL: URL(string: "https://huggingface.co/mlboydaisuke/coreml-zoo/resolve/main/gfpgan/GFPGAN.mlpackage.zip")
        ),
        CoreMLRestorationPreset(
            id: "codeformer",
            model: .codeFormer,
            title: "CodeFormer (수동 변환 배치)",
            sizeDescription: "사용자 변환",
            license: "S-Lab 1.0",
            summary: "직접 변환한 codeformer.mlpackage를 Models/Demosaic 폴더에 배치해 사용합니다.",
            downloadURL: nil
        )
    ]

    public static func coreMLPreset(for model: DemosaicModel) -> CoreMLRestorationPreset? {
        coreMLPresets.first { $0.model == model }
    }

    public static func coreMLPreset(id: String) -> CoreMLRestorationPreset? {
        coreMLPresets.first { $0.id == id }
    }

    public static let flashVSRRequiredFiles = [
        "dit_bf16.safetensors",
        "lq_proj_bf16.safetensors",
        "tcdecoder_bf16.safetensors",
        "prompt_bf16.safetensors"
    ]
}

/// 3가지 트랙의 표준 로컬 경로를 일관되게 계산합니다.
public enum VideoRestorationPaths {
    public static func appSupportRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return base.appending(path: "VideoLingo", directoryHint: .isDirectory)
    }

    public static func demosaicModelsDirectory(modelsURL: URL? = nil) -> URL {
        let root = modelsURL ?? appSupportRoot().appending(path: "Models", directoryHint: .isDirectory)
        return root.appending(path: "Demosaic", directoryHint: .isDirectory)
    }

    public static func enhancerRoot() -> URL {
        appSupportRoot().appending(path: "VideoEnhancer", directoryHint: .isDirectory)
    }

    public static func defaultFlashVSRBinaryURL() -> URL {
        enhancerRoot().appending(path: "bin/flashvsr-smoke")
    }

    public static func defaultFlashVSRWeightsURL(modelsURL: URL? = nil) -> URL {
        demosaicModelsDirectory(modelsURL: modelsURL).appending(path: "FlashVSR-v1.1-bf16", directoryHint: .isDirectory)
    }

    public static func defaultLocalWorkerScriptURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appending(path: "video-enhancer/worker.py"))
        }
        candidates.append(enhancerRoot().appending(path: "worker.py"))
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appending(path: "tools/video-enhancer/worker.py"))
        // 개발 빌드(.build/DerivedData/...) 실행 시 워크스페이스 경로 자동 탐색
        let executablePath = Bundle.main.bundleURL.path
        if let range = executablePath.range(of: "/.build/") {
            let repoRoot = String(executablePath[..<range.lowerBound])
            candidates.append(URL(fileURLWithPath: repoRoot).appending(path: "tools/video-enhancer/worker.py"))
        }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    public static func defaultSetupScriptURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appending(path: "video-enhancer/setup_video_enhancers.sh"))
        }
        candidates.append(enhancerRoot().appending(path: "setup_video_enhancers.sh"))
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appending(path: "scripts/setup_video_enhancers.sh"))
        let executablePath = Bundle.main.bundleURL.path
        if let range = executablePath.range(of: "/.build/") {
            let repoRoot = String(executablePath[..<range.lowerBound])
            candidates.append(URL(fileURLWithPath: repoRoot).appending(path: "scripts/setup_video_enhancers.sh"))
        }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    public static func coreMLModelExists(id: String, modelsURL: URL? = nil) -> Bool {
        let dir = demosaicModelsDirectory(modelsURL: modelsURL)
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appending(path: "\(id).mlmodelc").path)
            || fm.fileExists(atPath: dir.appending(path: "\(id).mlpackage").path)
    }

    public static func flashVSRWeightsExist(at directory: URL? = nil, modelsURL: URL? = nil) -> Bool {
        let dir = directory ?? defaultFlashVSRWeightsURL(modelsURL: modelsURL)
        let fm = FileManager.default
        return VideoRestorationCatalog.flashVSRRequiredFiles.allSatisfy {
            fm.fileExists(atPath: dir.appending(path: $0).path)
        }
    }
}

/// ComfyUI API 워크플로 JSON 생성 및 치환 유틸리티입니다.
public enum ComfyUIWorkflowBuilder {
    public struct TemplateParameters: Sendable {
        public let inputVideoFilename: String
        public let maskVideoFilename: String?
        public let promptText: String
        public let outputPrefix: String
        public let frameRate: Double
        public let width: Int
        public let height: Int

        public init(
            inputVideoFilename: String,
            maskVideoFilename: String? = nil,
            promptText: String = "clean natural restoration, sharp details, seamless background",
            outputPrefix: String = "videolingo_out",
            frameRate: Double = 24,
            width: Int = 832,
            height: Int = 480
        ) {
            self.inputVideoFilename = inputVideoFilename
            self.maskVideoFilename = maskVideoFilename
            self.promptText = promptText
            self.outputPrefix = outputPrefix
            self.frameRate = frameRate
            self.width = width
            self.height = height
        }
    }

    /// 사용자 커스텀 ComfyUI API JSON 템플릿에서 플레이스홀더를 치환합니다.
    public static func renderCustomWorkflow(
        jsonString: String,
        model: DemosaicModel,
        parameters: TemplateParameters
    ) throws -> Data {
        let escapedInput = escapeJSONString(parameters.inputVideoFilename)
        let escapedMask = escapeJSONString(parameters.maskVideoFilename ?? parameters.inputVideoFilename)
        let escapedPrompt = escapeJSONString(parameters.promptText)
        let escapedPrefix = escapeJSONString(parameters.outputPrefix)
        let rendered = jsonString
            .replacingOccurrences(of: "{{INPUT_VIDEO}}", with: escapedInput)
            .replacingOccurrences(of: "{{MASK_VIDEO}}", with: escapedMask)
            .replacingOccurrences(of: "{{PROMPT}}", with: escapedPrompt)
            .replacingOccurrences(of: "{{OUTPUT_PREFIX}}", with: escapedPrefix)
            .replacingOccurrences(of: "{{MODEL}}", with: escapeJSONString(model.rawValue))
        guard let data = rendered.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VideoLingoError.invalidPayload
        }
        // 사용자가 prompt 래퍼 없이 노드 딕셔너리만 저장한 경우 {"prompt": ...}로 감쌉니다.
        if parsed["prompt"] is [String: Any] {
            return data
        }
        return try JSONSerialization.data(withJSONObject: ["prompt": parsed])
    }

    /// SeedVR2-3B 기본 ComfyUI API 워크플로(ComfyUI-SeedVR2_VideoUpscaler + VideoHelperSuite).
    public static func defaultSeedVR2Workflow(
        parameters: TemplateParameters,
        modelName: String = "seedvr2_ema_3b_fp8_e4m3fn.safetensors"
    ) throws -> Data {
        let targetResolution = max(512, min(1080, min(parameters.width, parameters.height)))
        let promptGraph: [String: Any] = [
            "1": [
                "class_type": "VHS_LoadVideo",
                "inputs": [
                    "video": parameters.inputVideoFilename,
                    "force_rate": 0,
                    "force_size": "Disabled",
                    "custom_width": parameters.width,
                    "custom_height": parameters.height,
                    "frame_load_cap": 0,
                    "skip_first_frames": 0,
                    "select_every_nth": 1
                ]
            ],
            "2": [
                "class_type": "SeedVR2LoadDiTModel",
                "inputs": [
                    "model": modelName,
                    "device": "mps",
                    "blocks_to_swap": 12
                ]
            ],
            "3": [
                "class_type": "SeedVR2LoadVAEModel",
                "inputs": [
                    "model": "ema_vae_fp16.safetensors",
                    "device": "mps"
                ]
            ],
            "4": [
                "class_type": "SeedVR2VideoUpscaler",
                "inputs": [
                    "image": ["1", 0],
                    "dit": ["2", 0],
                    "vae": ["3", 0],
                    "seed": 42,
                    "resolution": targetResolution,
                    "batch_size": 5
                ]
            ],
            "5": [
                "class_type": "VHS_VideoCombine",
                "inputs": [
                    "images": ["4", 0],
                    "frame_rate": parameters.frameRate,
                    "loop_count": 0,
                    "filename_prefix": parameters.outputPrefix,
                    "format": "video/h264-mp4",
                    "save_output": true
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: ["prompt": promptGraph])
    }

    /// Wan2.1-VACE-1.3B 기본 ComfyUI API 워크플로(ComfyUI 코어 WanVaceToVideo + VideoHelperSuite).
    public static func defaultWanVACEWorkflow(
        parameters: TemplateParameters,
        diffusionModel: String = "wan2.1_vace_1.3B_bf16.safetensors",
        textEncoder: String = "umt5_xxl_fp8_e4m3fn_scaled.safetensors",
        vaeModel: String = "wan_2.1_vae.safetensors"
    ) throws -> Data {
        let alignedWidth = max(256, (min(parameters.width, 832) / 16) * 16)
        let alignedHeight = max(256, (min(parameters.height, 480) / 16) * 16)
        var promptGraph: [String: Any] = [
            "1": [
                "class_type": "VHS_LoadVideo",
                "inputs": [
                    "video": parameters.inputVideoFilename,
                    "force_rate": 0,
                    "force_size": "Disabled",
                    "custom_width": alignedWidth,
                    "custom_height": alignedHeight,
                    "frame_load_cap": 81,
                    "skip_first_frames": 0,
                    "select_every_nth": 1
                ]
            ],
            "2": [
                "class_type": "UNETLoader",
                "inputs": [
                    "unet_name": diffusionModel,
                    "weight_dtype": "default"
                ]
            ],
            "3": [
                "class_type": "CLIPLoader",
                "inputs": [
                    "clip_name": textEncoder,
                    "type": "wan"
                ]
            ],
            "4": [
                "class_type": "VAELoader",
                "inputs": [
                    "vae_name": vaeModel
                ]
            ],
            "5": [
                "class_type": "CLIPTextEncode",
                "inputs": [
                    "text": parameters.promptText,
                    "clip": ["3", 0]
                ]
            ],
            "6": [
                "class_type": "CLIPTextEncode",
                "inputs": [
                    "text": "blurry, mosaic, pixelated, distorted, artifacts, watermark",
                    "clip": ["3", 0]
                ]
            ]
        ]

        var vaceInputs: [String: Any] = [
            "positive": ["5", 0],
            "negative": ["6", 0],
            "vae": ["4", 0],
            "width": alignedWidth,
            "height": alignedHeight,
            "length": 41,
            "batch_size": 1,
            "strength": 1.0,
            "control_video": ["1", 0]
        ]
        if let maskVideo = parameters.maskVideoFilename {
            promptGraph["10"] = [
                "class_type": "VHS_LoadVideo",
                "inputs": [
                    "video": maskVideo,
                    "force_rate": 0,
                    "force_size": "Disabled",
                    "custom_width": alignedWidth,
                    "custom_height": alignedHeight,
                    "frame_load_cap": 81,
                    "skip_first_frames": 0,
                    "select_every_nth": 1
                ]
            ]
            promptGraph["11"] = [
                "class_type": "ImageToMask",
                "inputs": [
                    "image": ["10", 0],
                    "channel": "red"
                ]
            ]
            vaceInputs["control_masks"] = ["11", 0]
        }

        promptGraph["7"] = [
            "class_type": "WanVaceToVideo",
            "inputs": vaceInputs
        ]
        promptGraph["8"] = [
            "class_type": "KSampler",
            "inputs": [
                "model": ["2", 0],
                "positive": ["7", 0],
                "negative": ["7", 1],
                "latent_image": ["7", 2],
                "seed": 42,
                "steps": 12,
                "cfg": 5.0,
                "sampler_name": "uni_pc",
                "scheduler": "simple",
                "denoise": 1.0
            ]
        ]
        promptGraph["9"] = [
            "class_type": "VAEDecode",
            "inputs": [
                "samples": ["8", 0],
                "vae": ["4", 0]
            ]
        ]
        promptGraph["12"] = [
            "class_type": "VHS_VideoCombine",
            "inputs": [
                "images": ["9", 0],
                "frame_rate": parameters.frameRate,
                "loop_count": 0,
                "filename_prefix": parameters.outputPrefix,
                "format": "video/h264-mp4",
                "save_output": true
            ]
        ]
        return try JSONSerialization.data(withJSONObject: ["prompt": promptGraph])
    }

    private static func escapeJSONString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
