# VideoLingo

[한국어](README.md) | [English](README.en.md)

MP4를 재생하면서 별도 XPC 프로세스에서 로컬 STT, 다국어 번역, 번역 음성 생성을 수행하는 Swift macOS 앱입니다. 결과는 청크마다 SQLite에 저장되어 앱을 종료하거나 작업이 실패해도 이어서 처리할 수 있습니다.

## 구현된 기능

- `AVPlayer` 기반 MP4 재생
- XPC 서비스 기반 비동기 AI 처리
- 30초 오디오 청크 추출
- WhisperKit/Core ML 기반 Whisper Large v3 로컬 STT 및 모델 자동 다운로드
- macOS Foundation Models 기반 온디바이스 번역
- TTSKit/Qwen3-TTS 기반 번역 음성 및 모델 자동 다운로드
- 원음 볼륨을 낮추고 번역 음성을 합성한 `dubbed-<language>.mp4` 생성
- SQLite WAL과 청크 단위 트랜잭션
- SQLite busy timeout·잠금 재시도·연결 재사용 및 동일 작업 중복 실행 차단
- 완료된 STT를 재사용하여 새 언어 번역이나 TTS만 추가
- 플레이어 번역 자막 오버레이
- SRT 내보내기

## 요구사항

- Apple Silicon Mac
- macOS 26 이상
- Xcode 26 이상
- XcodeGen
- 번역에는 Apple Intelligence가 활성화되어 있고 시스템 언어 모델이 사용 가능해야 합니다.

WhisperKit과 TTSKit 모델은 기능을 처음 실행할 때 내려받습니다. 정확도 중심의 `large-v3-v20240930_626MB` STT 모델을 기본값으로 사용하며, 저사양 환경에서는 `small`, `base`, `tiny`로 바꿀 수 있습니다. TTS를 선택하면 약 1GB의 기본 모델을 추가로 내려받습니다. 모델 다운로드 이후에는 오프라인으로 실행할 수 있습니다.

Whisper는 일반적인 텍스트 LLM은 아니지만, 음성을 입력받아 텍스트 토큰을 생성하는 encoder-decoder Transformer 모델입니다. 영상 STT에서는 오디오를 텍스트 LLM에 직접 넣는 방식보다 타임스탬프와 다국어 인식에 적합합니다.

## 빌드

```bash
./scripts/build_app.sh
open .build/DerivedData/Build/Products/Release/VideoLingo.app
```

또는 `VideoLingo.xcodeproj`를 Xcode에서 열고 `VideoLingo` scheme을 실행합니다. `project.yml`을 변경했다면 먼저 `xcodegen generate`를 실행합니다.

### DMG 만들기

```bash
./scripts/build_dmg.sh
```

완성된 DMG는 `dist/VideoLingo-<version>.dmg`에 생성됩니다. 현재 스크립트는 로컬 실행용 ad-hoc 서명을 사용합니다. 외부 배포 시에는 Developer ID Application 인증서로 서명한 뒤 Apple 공증을 추가해야 합니다.

## 사용 순서

1. `MP4 영상 열기…`로 영상을 선택합니다.
2. STT 모델과 대상 언어를 선택합니다.
3. 실제 번역 음성 영상이 필요하면 `번역 음성 MP4 생성`을 켭니다.
4. `STT·번역 시작/재개`를 누릅니다.
5. 처리 중에도 영상을 계속 재생할 수 있습니다.
6. 자막은 `SRT 내보내기`, 번역 영상은 `작업 결과 폴더 열기`에서 확인합니다.

## 저장 위치

```text
~/Library/Application Support/VideoLingo/
├── videolingo.sqlite
└── Jobs/<job-id>/
    ├── AudioChunks/
    ├── TranslatedSpeech/
    └── dubbed-<language>.mp4
```

영상 경로, STT 모델, 원본 언어가 같은 작업은 동일한 체크포인트를 사용합니다. 대상 번역 언어를 바꾸면 저장된 STT를 재사용합니다.

## 테스트

```bash
xcodebuild -project VideoLingo.xcodeproj \
  -scheme VideoLingo \
  -destination 'platform=macOS' \
  -derivedDataPath .build/TestDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

현재 자동 테스트는 SRT 타임코드/번역 선택과 SQLite 청크 원자 저장·재개 인덱스를 검증합니다.

## 주요 구조

- `Sources/VideoLingo`: SwiftUI 앱, 플레이어, 작업 UI
- `Sources/VideoLingoAIService`: XPC 서비스, 미디어/STT/번역/TTS 파이프라인
- `Sources/VideoLingoCore`: 공유 모델, SQLite 저장소, XPC 프로토콜, 자막 출력
- `Tests/VideoLingoCoreTests`: 체크포인트 및 자막 테스트

번역 모델이 사용 불가능한 Mac에서는 작업이 실패 상태로 기록되며, 이미 저장된 STT 청크는 그대로 보존됩니다. Apple Intelligence를 활성화한 뒤 같은 작업을 다시 시작하면 STT를 재사용해 번역부터 계속합니다.
