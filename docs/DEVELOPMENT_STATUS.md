# VideoLingo 개발 기능 현황

기준일: 2026-08-23

## 1. 제품 구성

VideoLingo는 동일한 Xcode 프로젝트 안에서 다음 실행 타깃으로 구성된다.

| 타깃 | 플랫폼 | 역할 |
|---|---|---|
| `VideoLingo` | macOS 26 이상 | 영상 재생, STT·번역·TTS·모자이크 작업 제어 및 결과 관리 |
| `VideoLingoAIService` | macOS XPC | 무거운 AI·미디어 처리를 앱과 분리해 비동기로 실행 |
| `VideoLingoCore` | macOS Framework | 공용 데이터 모델, SQLite 저장소, XPC 프로토콜, 자막 출력 |
| `VideoLingoMobile` | iOS/iPadOS 18 이상 | Mac에서 생성한 영상·자막 패키지 수신, 보관 및 재생 |

Swift 6과 SwiftUI를 사용하며 프로젝트 정의는 `project.yml`, 생성 결과는 `VideoLingo.xcodeproj`에서 관리한다.

## 2. macOS 앱 기능

### 영상 재생

- `AVPlayer` 기반 MP4 재생
- 재생·일시 정지, 앞뒤 탐색, 음량 조절
- 마지막 영상과 재생 위치 복원
- 여러 플레이어 창 지원
- 전체 화면 영화관 보기
- 심플 보기, 미니 뷰어, 결과 패널 표시 전환
- 창 투명도 및 테마 설정
- 재생 중 현재 구간의 원문 또는 번역 자막 표시
- 자막 위치와 색상 저장

### STT

- WhisperKit/Core ML 기반 로컬 음성 인식
- 기본 모델: `large-v3-v20240930_626MB`
- 선택 모델: `small`, `base`, `tiny`
- 원본 언어 자동 감지 또는 직접 선택
- 시간 정보가 포함된 청크 단위 처리
- 전체 STT 재생성 및 개별 구간 재생성
- 기존 결과와 새 결과의 품질 비교 후 선택적 교체
- 처리되지 않은 구간 자동 재시도

### 번역

- macOS Foundation Models 기반 온디바이스 번역
- MLX 기반 로컬 번역 모델 선택 지원
- 여러 대상 언어 동시 작업
- 저장된 STT를 재사용해 번역만 추가 또는 재생성
- 개별 번역 구간 재생성
- 용어집 입력
- 빠른 처리, 향상, 최대 품질 모드
- 지속적 품질 개선과 최대 개선 횟수 설정

### 번역 음성 및 영상 출력

- TTSKit/Qwen3-TTS 기반 번역 음성 생성
- 원본 음량을 낮추고 번역 음성을 혼합
- 언어별 `dubbed-<language>.mp4` 생성
- 모델 최초 사용 시 다운로드 및 이후 로컬 실행

### 화면 텍스트 처리

- Vision 기반 재생 화면 OCR
- 화면에서 인식한 텍스트의 실시간 번역 자막 표시

### 모자이크 복원

- 얼굴, 자동 모자이크 영역, 전체 프레임 처리 모드
- Core Image 기반 기본 복원
- Core ML 복원 모델 연결 구조
- 복원 강도, 시간축 안정화, 합성 결과 워터마크 옵션
- 별도 XPC 작업으로 실행 및 취소

### 작업 안정성

- AI 작업을 별도 XPC 서비스에서 실행하여 UI 응답성 유지
- 진행률, 현재 단계, 작업 메시지 표시
- 작업 취소, 서비스 연결 감시 및 재연결
- 서비스 상태 확인과 재시작
- 동일 작업 중복 실행 방지
- 청크 단위 체크포인트와 중단 후 재개
- 성공한 중간 결과를 유지한 채 실패 지점 재시도

### 대량 번역

- 메인 창과 `STT·번역` 메뉴의 `대량 번역…` 버튼
- 독립적인 대량 번역 창
- 한 번에 여러 영상 선택 및 중복 파일 제외
- Finder에서 대량 번역 창으로 여러 영상을 드래그앤드롭해 추가
- 드래그 중 드롭 영역 강조와 지원 형식 안내
- 영상이 아닌 파일 및 이미 추가된 파일 자동 제외
- 메인 창의 현재 STT 모델, 번역 LLM, 원어, 대상 언어, 품질 설정 사용
- 여러 영상의 STT·LLM 번역 병렬 실행
- 동시 처리 수 1~10개 설정 및 사용자 선택 저장
- 기본 동시 처리 수 5개
- 파일별 상태, 진행률, 현재 작업 메시지 표시
- 파일별 `STT → LLM 번역 → 완료` 그래픽 파이프라인
- STT와 번역 단계의 독립 진행률 및 활성 단계 강조
- 현재 처리 청크와 전체 청크 개수 표시
- 펼쳐서 확인하는 실시간 STT·LLM 생성 텍스트
- 전체 진행률과 실행·대기·완료 개수 표시
- 전체 작업 취소 및 실패·취소 항목 다시 시도
- 완료 항목 정리와 실행 전 큐 삭제

### 결과 및 저장소 관리

- SQLite WAL 및 청크 단위 트랜잭션
- busy timeout, 잠금 재시도, 연결 재사용
- 미디어 옆 sidecar 결과와 앱 데이터베이스 결과 탐색
- SRT 자막 내보내기
- 결과 폴더, 데이터베이스, 모델 폴더 Finder 열기
- 데이터베이스 통계 확인 및 최적화
- 저장 데이터 삭제
- AI 모델 상태 확인, 다운로드 및 삭제

## 3. iPhone 및 iPad 앱 기능

### 영상 가져오기와 재생

- 파일 앱에서 일반 영상 선택
- 가져온 영상을 앱의 Application Support 영역으로 복사
- 마지막으로 연 영상 또는 패키지 복원
- 시스템 `VideoPlayer` 기반 재생
- 세로·가로 회전 지원
- iPhone의 세로형 레이아웃과 iPad의 넓은 분할 레이아웃
- iPad 멀티태스킹을 위한 전체 화면 강제 해제

### VideoLingo 패키지 수신

- 전용 문서 형식: `.videolingo`
- 파일 앱, iCloud Drive, AirDrop으로 전달받은 패키지 열기
- 외부 앱에서 파일을 열 때 VideoLingo로 전달되는 `onOpenURL` 처리
- 패키지를 기기 내부에 복사한 뒤 지속적으로 보관
- 패키지 형식 버전 검증 및 영상 누락 오류 처리

### 모바일 자막

- 원문 STT와 번역 트랙 목록 표시
- 원하는 자막 트랙 선택 또는 자막 끄기
- 현재 재생 시간에 맞는 자막 탐색
- 영상 위 자막 오버레이 표시

### 모바일 제한 사항

- 모바일 앱은 현재 AI 추론을 직접 실행하지 않는다.
- STT, 번역, TTS, 모자이크 복원은 Mac의 XPC 서비스에서 수행한다.
- 모바일 앱은 Mac 결과의 수신, 보관, 재생과 자막 전환을 담당한다.
- 실제 기기 설치에는 Xcode의 Apple 개발팀 서명과 iOS/iPadOS 18 이상 기기가 필요하다.

## 4. Mac과 모바일 간 공유

Mac 앱의 `iPhone·iPad로 공유` 기능은 다음 항목을 하나의 `.videolingo` 문서 패키지로 만든다.

- 원본 영상 파일
- 원문 STT 트랙
- 데이터베이스에 저장된 대상 언어별 번역 트랙
- 자막 시작·종료 시간
- 제목, 생성 시각, 패키지 형식 버전과 미디어 파일명

기본 사용 흐름은 다음과 같다.

1. Mac에서 영상의 STT와 번역을 완료한다.
2. `iPhone·iPad로 공유`를 눌러 `.videolingo` 파일을 저장한다.
3. AirDrop 또는 iCloud Drive로 iPhone/iPad에 전달한다.
4. 모바일 VideoLingo로 패키지를 연다.
5. 영상 재생 중 원문 또는 번역 자막을 선택한다.

패키지 포맷 구현은 `Sources/VideoLingoTransfer/VideoLingoPackage.swift`에 있으며 macOS와 iOS 타깃이 같은 코드를 사용한다.

## 5. 설정과 사용자 경험

- 한국어와 영어 리소스
- 외형, 강조색, 컨트롤 밀도, 반투명 프리셋
- STT·번역·품질·동작 설정 저장
- macOS 키보드 단축키 사용자 지정 및 충돌 안내
- 빈 화면, 작업 중, 오류 상태 구분
- 긴 작업의 진행 상태와 취소 기능
- 내보내기 및 가져오기 진행 표시
- 작업 불가 상태에서 관련 버튼 비활성화

## 6. 저장 위치와 데이터 흐름

macOS 기본 저장 구조:

```text
~/Library/Application Support/VideoLingo/
├── videolingo.sqlite
├── Models/
└── Jobs/<job-id>/
    ├── AudioChunks/
    ├── TranslatedSpeech/
    └── dubbed-<language>.mp4
```

모바일 앱은 가져온 일반 영상과 `.videolingo` 패키지를 각각 Application Support의 `Imported Videos`, `Imported Packages` 아래에 저장한다.

## 7. 현재 검증 상태

- XcodeGen 프로젝트 생성 성공
- 모바일 Swift 소스 컴파일 성공
- `.videolingo` UTType 및 양쪽 앱 문서 형식 등록 확인
- iPhone 17, iOS 26.5 시뮬레이터 빌드 성공
- iPad Air 11-inch (M4), iPadOS 26.5 시뮬레이터 빌드 성공
- iPhone 시뮬레이터 설치·실행 및 초기 화면 렌더링 확인
- 모바일 문서 열기 경고 수정
- `UILaunchScreen` 누락으로 발생한 레터박스 실행 문제 수정
- macOS Core 자동 테스트는 SRT 출력, SQLite 원자 저장과 작업 재개 동작을 검증

아직 실제 iPhone/iPad에서 확인해야 하는 항목:

- Apple 개발팀 서명 후 실제 기기 설치
- AirDrop을 통한 대용량 `.videolingo` 전송
- 대용량 MP4 복사 중 메모리와 저장 공간 동작
- 실제 기기에서 장시간 영상 재생과 자막 동기 정확도
- 백그라운드 전환 및 저장 공간 부족 상황

## 8. 빌드 및 실행

프로젝트 재생성:

```bash
xcodegen generate
```

macOS 앱:

```bash
./scripts/build_app.sh
```

모바일 앱은 Xcode에서 `VideoLingoMobile` scheme을 선택한 뒤 iPhone/iPad 시뮬레이터 또는 서명된 실제 기기로 실행한다.

## 9. 주요 소스 경로

- `Sources/VideoLingo`: macOS SwiftUI 앱과 작업 제어
- `Sources/VideoLingoMobile`: iPhone/iPad 앱과 모바일 라이브러리
- `Sources/VideoLingoTransfer`: 플랫폼 공용 패키지 포맷
- `Sources/VideoLingoAIService`: STT·번역·TTS·모자이크 XPC 파이프라인
- `Sources/VideoLingoCore`: 모델, 저장소, 자막 출력, XPC 프로토콜
- `Tests/VideoLingoCoreTests`: macOS Core 자동 테스트
- `docs/mosaic-removal`: 모자이크 복원 설계와 모델 문서
