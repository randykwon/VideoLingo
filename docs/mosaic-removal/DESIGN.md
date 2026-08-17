# VideoLingo — 얼굴 모자이크 제거 모듈 설계 (Swift / XPC 통합)

[한국어](DESIGN.md) | [English](DESIGN.en.md)

> 대상 시나리오: **인물/얼굴 모자이크 · 오프라인 배치 · 최고 품질**
> 상태: 설계 초안 (Phase 0 PoC 검증 전제)

## 0. 반드시 먼저 읽을 것 — 기술적·윤리적 전제

- 모자이크는 **비가역 손실**이다. 결과는 원본 복구가 아니라 **그럴듯한 생성(hallucination)** 이며, 얼굴의 경우 **실제 인물의 얼굴이 아니다.** 복원된 얼굴을 실제로 오인시키는 사용은 초상권·명예 문제를 일으킬 수 있다.
- 본인이 **권리를 가진 영상**에만 사용한다. 신원 식별 가능한 타인, 검열 해제(성인물 등)는 법적·플랫폼 약관 리스크가 있다.
- 이 모듈은 결과물에 **합성(AI로 재구성됨) 사실을 메타데이터/워터마크로 남기는** 옵션을 기본 제공한다(§7).

## 1. 아키텍처 개요

기존 앱 구조를 그대로 재사용한다.

```
VideoLingo.app (UI)
   │  StartDemosaicRequest (XPC)
   ▼
VideoLingoAIService.xpc  ── DemosaicPipeline (신규)
   │   AVAssetReader ─▶ 프레임(CVPixelBuffer)
   │        │
   │        ├─ Vision 얼굴 검출/트래킹 (VNDetectFaceRectangles + 트래커)
   │        ├─ 1차 디모자이크 (DeepMosaics-CoreML)   [영역 복원]
   │        ├─ 2차 얼굴 복원 (선택 모델, Core ML/MLX) [디테일 재생성]
   │        └─ 시간 일관성 안정화 (옵티컬 플로우 / 코드북 전파)
   │   AVAssetWriter ─▶ demosaiced-<name>.mp4 (+ 원본 오디오)
   ▼
JobSnapshot 진행률 (기존 폴링 메커니즘 재사용)
```

재사용하는 기존 자산:
- **XPC 서비스 + 작업 큐**: `Sources/VideoLingoAIService/ServiceDelegate.swift`의 `tasks: [UUID: Task]`, `installTaskIfAbsent`, 작업별 `JobSnapshot` — 동시 실행/취소/진행률 그대로 활용.
- **미디어 합성 패턴**: `Sources/VideoLingoAIService/MediaPipeline.swift`의 `DubbedVideoExporter`(AVMutableComposition, AVAssetExportSession, 오디오 트랙 유지) — 출력 인코딩 참고.
- **모델 다운로드/관리**: `ManagedModelKind`(`Sources/VideoLingoCore/XPCProtocol.swift`) + `AppModel`의 다운로드 흐름 — 복원 모델도 동일 방식으로 관리.
- **진행률/스냅샷**: `JobSnapshot`, `onLiveTranscript` 유사 콜백으로 프레임 진행 표시.

## 2. 데이터 모델 추가 (`Sources/VideoLingoCore`)

`Models.swift` / `XPCProtocol.swift`에 추가:

```swift
public enum DemosaicModel: String, Codable, Sendable, CaseIterable {
    case deepMosaics          // 블록 디모자이크 (탐지+복원)
    case codeFormer           // 얼굴 복원 (이미지, 베이스라인)
    case dicFaceVideo         // 얼굴 복원 (영상, 시간 일관)  ← 최고 품질 후보
    case realESRGAN           // 일반 디블록/초해상 (폴백)
}

public struct DemosaicOptions: Codable, Sendable, Equatable {
    public var model: DemosaicModel
    public var restoreFaceOnly: Bool          // 얼굴 ROI만 처리
    public var fidelity: Double               // CodeFormer식 충실도(0=화질,1=원형 유지)
    public var temporalStabilization: Bool    // 프레임 간 깜빡임 억제
    public var manualROIs: [CGRect]?          // 수동 지정(정규화 좌표), nil이면 자동 얼굴검출
    public var watermarkSynthetic: Bool       // 합성 표식 삽입
}

public struct StartDemosaicRequest: Codable, Sendable {
    public var jobID: UUID
    public var mediaURL: URL
    public var securityScopedBookmark: Data?
    public var options: DemosaicOptions
    public var databaseURL: URL
    public var workspaceURL: URL
    public var uiLanguageCode: String?        // 진행 메시지 로컬라이즈용
}
```

XPC 프로토콜(`VideoLingoAIServiceProtocol`)에 추가:
```swift
func startDemosaic(_ payload: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
```
스냅샷/취소는 기존 `snapshot(for:)`, `cancelJob(_:)`를 그대로 사용(같은 `jobID` 공간).

`ManagedModelKind`에 `.demosaic` 추가 → 복원 모델도 `ModelManager`로 다운로드/삭제.

## 3. 파이프라인 상세 (`DemosaicPipeline.swift`, 신규)

`MediaPipeline`와 동일한 구조(`@unchecked Sendable`, `run(_:) async`, `onSnapshot` 콜백).

### 3.1 프레임 IO
- 입력: `AVAssetReader` + `AVAssetReaderTrackOutput`(`kCVPixelFormatType_32BGRA`) → `CVPixelBuffer` 스트림.
- 출력: `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`. 원본 프레임레이트/타임스케일 유지.
- 오디오: 원본 오디오 트랙을 그대로 패스스루(디코드/재인코드 없이 `AVAssetWriterInput` passthrough 또는 최종 `AVMutableComposition` 합성 — `DubbedVideoExporter` 방식).
- 체크포인트: N프레임마다 부분 저장(중단 후 재개). 청크 개념을 프레임 구간으로 확장.

### 3.2 얼굴 검출 + 트래킹
- `VNDetectFaceRectanglesRequest`(온디바이스, 무료, 빠름)로 프레임별 박스.
- **트래킹**: `VNTrackObjectRequest` 또는 IoU 기반 간이 트래커로 track id 부여 → 같은 인물에 **일관된 복원**(identity drift 완화의 1차 방어).
- `restoreFaceOnly`면 얼굴 ROI만, 아니면 프레임 전체(또는 수동 ROI) 처리.

### 3.3 복원 스테이지 (2단)
1. **디모자이크(선택)**: 블록 모자이크가 굵으면 DeepMosaics-CoreML로 먼저 블록 제거(거친 복원).
2. **얼굴 복원**: ROI를 정렬(align)→ 선택 모델 추론 → 역정렬 → 원본에 **feather/포아송 블렌딩**.
   - Core ML 경로(빠름, 앱 내장): `codeFormer`, `realESRGAN`.
   - MLX 경로(무거움, 최고 품질): 영상 얼굴 복원(`dicFaceVideo` 등)은 §6 참고.

### 3.4 시간 일관성 (temporal)
프레임 단위 복원의 **identity flicker**가 가장 큰 품질 리스크. 세 단계 방어:
1. 트랙별 동일 파라미터/코드북 사용.
2. 인접 프레임 **옵티컬 플로우 워핑 + 가중 평균**으로 고주파 안정화(경량, Core ML 광류 or Vision).
3. 가능하면 **영상 전용 복원 모델**(코드북 전파/디퓨전) 사용 — 근본 해결.

## 4. UI (앱)

- 새 작업 유형 진입점: 툴바/메뉴 "모자이크 제거" → 시트.
- 시트 구성: 대상 영상, 모델 선택(Picker), 얼굴만/전체, 충실도 슬라이더, 시간안정화 토글, **ROI 수동 지정**(플레이어 위 드래그 박스, 프레임 스크럽), 합성 워터마크 토글, 예상 소요/모델 다운로드 상태.
- 진행: 기존 `JobSnapshot` 진행바 재사용("프레임 1234/50000 복원 중").
- 결과: `demosaiced-<name>.mp4`를 결과 폴더/플레이어에서 확인.
- 로컬라이즈: 진행 메시지는 `uiLanguageCode`로 서비스에서 처리(기존 로컬라이제이션 인프라와 동일 원칙).

## 5. 모델 관리
- `ManagedModelKind.demosaic` + 모델별 매니페스트(기존 `Manifests/*.json` 패턴).
- Core ML(`.mlpackage`)/MLX 가중치는 최초 사용 시 다운로드, 이후 오프라인.
- 저장 위치: 기존 `Application Support/VideoLingo/Models` 하위 `Demosaic/`.

## 6. 모델 변환 현실 (중요한 제약)

| 모델 | 형태 | 온디바이스(Core ML/MLX) | 비고 |
|---|---|---|---|
| Real-ESRGAN | GAN | ✅ 이미 MLX/CoreML 포팅 존재 | 얼굴엔 약함, 폴백용 |
| CodeFormer | Transformer+VQ | ⚠️ 변환 가능(코드북/VQ 주의) | 이미지 얼굴 복원 베이스라인 |
| DeepMosaics | GAN(pix2pix) | ⚠️ 변환 필요(PyTorch) | 모자이크 전용 탐지+복원 |
| DicFace/KEEP/DVFace(영상) | 코드북/디퓨전 | ❌ 현재 PyTorch 연구코드, 포팅 미존재 | **최고 품질이지만 앱 내장은 대형 작업** |

**결론**: "최고 품질 영상 얼굴 복원"을 앱에 **완전 내장**하려면 연구 모델의 Core ML/MLX 포팅이 선행돼야 하며 이는 수주 규모다. 따라서 **단계 전략**:
- **Phase 1 (내장 MVP)**: Real-ESRGAN/CodeFormer(Core ML)로 앱 내 온디바이스 복원 — 중간 품질, 지금 구조에 바로 통합.
- **Phase 2 (전용)**: DeepMosaics 탐지+복원망 변환 → 자동 검출 + 모자이크 특화.
- **Phase 3 (SOTA)**: 영상 얼굴 복원 모델 포팅(또는 앱이 번들 파이썬/외부 워커로 오프라인 처리 위임) → 최고 품질.

과도기 옵션: 앱은 오케스트레이터만 맡고, 무거운 SOTA는 **동봉 파이썬 워커(오프라인)** 로 위임 → UI/진행률은 앱, 연산은 워커. Phase 0 PoC 코드를 그대로 워커로 승격 가능.

## 7. 안전장치
- 결과 MP4에 `com.videolingo.synthetic=true` 메타데이터 + 선택적 코너 워터마크.
- 실행 전 1회 고지(권리/합성 경고) 동의.
- 로그에 원본 프레임 저장 금지(작업 폴더 임시본은 완료 후 정리).

## 8. 성능 기대치 (Apple Silicon 오프라인)
- Real-ESRGAN: ~0.2–2s/frame → 3분/30fps(≈5,400프레임) 수십 분.
- 디퓨전 얼굴 복원: 수~수십 s/frame → 같은 클립 **수 시간**. 반드시 배치·재개 지원, 진행률 필수.

## 9. 구현 순서 체크리스트
- [ ] Phase 0 PoC로 실제 클립 품질/모델 선정 (→ `tools/demosaic-poc/`)
- [ ] Core 모델(`DemosaicOptions`, `StartDemosaicRequest`, XPC 메서드) 추가
- [ ] `DemosaicPipeline` 프레임 IO + Vision 얼굴검출/트래킹
- [ ] Real-ESRGAN/CodeFormer Core ML 통합(Phase 1)
- [ ] ROI 선택 UI + 진행률 + 결과 export
- [ ] 시간 안정화(광류) 추가
- [ ] DeepMosaics 변환(Phase 2) → 자동 검출
- [ ] 영상 얼굴 복원 포팅 또는 파이썬 워커 위임(Phase 3)
- [ ] 합성 메타데이터/워터마크/동의 고지

## 참고
- DeepMosaics: https://github.com/HypoX64/DeepMosaics
- Real-ESRGAN (MLX): https://huggingface.co/mlx-community/Real-ESRGAN-x2plus
- DicFace (temporally coherent video face restoration): https://arxiv.org/html/2506.13355
- Discrete Prior-based Temporal-coherent Blind Face Video Restoration: https://arxiv.org/pdf/2501.09960
