import AVKit
import SwiftUI
@preconcurrency import Translation
import VideoLingoCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showDemosaicSheet = false
    @AppStorage("simpleSidebar") private var simpleSidebar = false
    @State private var regenerationRequest: RegenerationRequest?
    @State private var showAdvancedSettings = false
    @State private var showProgressDetails = false
    @State private var showServiceDetails = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Group {
            if simpleSidebar {
                SimpleSidebarView(simpleSidebar: $simpleSidebar)
            } else {
            Form {
                Section {
                    Button("심플 메뉴로 전환", systemImage: "list.bullet") { simpleSidebar = true }
                }
                Section("영상") {
                    Button("MP4 영상 열기…", systemImage: "film") { model.openVideo() }
                    if let url = model.mediaURL {
                        Text(url.lastPathComponent).lineLimit(2).font(.caption)
                        if let resultURL = model.resultDirectoryURL {
                            Text("결과: \(resultURL.lastPathComponent)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("번역") {
                    Picker("STT 원어", selection: $model.sourceLanguage) {
                        ForEach(model.sourceLanguages, id: \.self) { language in
                            Text(model.sourceLanguageName(language)).tag(language)
                        }
                    }
                    .disabled(!model.canMutateStorage)
                    .help("자동 감지 또는 영상에서 말하는 원어를 직접 지정합니다")
                    Text(model.sourceLanguage.isEmpty
                         ? "초반에 음악·무음이 길면 원어를 직접 지정하는 것이 정확합니다."
                         : "\(model.sourceLanguageName(model.sourceLanguage))로 고정해 인식합니다. 변경 후 시작하면 기존 결과를 보존한 새 STT 작업으로 처리합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Menu {
                        ForEach(model.languages, id: \.self) { language in
                            Button {
                                model.toggleTargetLanguage(language)
                            } label: {
                                Label(
                                    language.uppercased(),
                                    systemImage: model.targetLanguages.contains(language) ? "checkmark.circle.fill" : "circle"
                                )
                            }
                        }
                    } label: {
                        Label("번역 언어 · \(model.targetLanguages.map { $0.uppercased() }.joined(separator: ", "))", systemImage: "globe")
                    }
                    Picker("화면에 볼 결과", selection: $model.selectedLanguage) {
                        ForEach(model.targetLanguages, id: \.self) { Text($0.uppercased()).tag($0) }
                    }
                    .onChange(of: model.selectedLanguage) { _, _ in model.refreshResults() }
                    Text("언어를 추가한 뒤 시작/재개하면 기존 STT로 추가 번역만 생성합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("모델·고급 설정", isExpanded: $showAdvancedSettings) {
                        Picker("품질 모드", selection: $model.qualityMode) {
                            Text("빠름").tag(ProcessingQualityMode.fast)
                            Text("품질 강화").tag(ProcessingQualityMode.enhanced)
                            Text("최고 품질").tag(ProcessingQualityMode.maximum)
                        }
                        Toggle("완료 후 자동 품질 개선", isOn: $model.continuousImprovement)
                        Toggle("완료 후 재검토·미번역 구간 자동 재시도", isOn: $model.autoRetryReviewedAndUntranslated)
                            .help("품질 개선까지 끝나면 STT가 재검토됨이거나 번역이 비어 있는 구간만 한 번 더 자동으로 추출·번역합니다.")
                        Toggle("앱 전체 반투명 모드", isOn: $model.translucentMode)
                            .help("Command+Shift+T로 전환")
                        if model.continuousImprovement {
                            Picker("최대 개선 회차", selection: $model.maximumRefinementPasses) {
                                ForEach(1...5, id: \.self) { Text("\($0)회").tag($0) }
                            }
                            Text("완료 결과는 유지하며 백그라운드 후보가 더 좋을 때만 교체합니다.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Picker("Whisper STT", selection: $model.sttModel) {
                            ForEach(model.models, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("번역 LLM", selection: $model.translationModel) {
                            ForEach(model.translationModels, id: \.self) { modelID in
                                Text(translationModelName(modelID)).tag(modelID)
                            }
                        }
                        .onChange(of: model.translationModel) { _, _ in model.refreshResults() }
                        Toggle("번역 음성 MP4 생성", isOn: $model.synthesizeSpeech)
                        Text("용어집 · 원문=번역, 한 줄에 하나")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $model.glossaryText)
                            .font(.caption.monospaced())
                            .frame(minHeight: 70)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                    }
                }
                Section("작업") {
                    Button("STT·번역 시작/재개", systemImage: "waveform.and.magnifyingglass") { model.startOrResume() }
                        .disabled(!model.canStart)
                    Menu("결과 재생성", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                        Button("번역만 재생성", systemImage: "character.book.closed") {
                            regenerationRequest = .translation
                        }
                        Button("STT·번역 모두 재생성", systemImage: "waveform.badge.magnifyingglass", role: .destructive) {
                            regenerationRequest = .all
                        }
                    }
                    .disabled(!model.canRegenerate)
                    Button("화자 이름 분석 적용", systemImage: "person.text.rectangle") {
                        model.startOrResume()
                    }
                    .disabled(!model.canRegenerate || model.transcript.isEmpty)
                    .help("저장된 전체 스크립트에서 이름과 역할을 분석하고 STT·번역 결과에 반영합니다")
                    if let snapshot = model.snapshot {
                        HStack {
                            ProgressView(value: snapshot.progress)
                            Text(snapshot.progress, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Text(snapshot.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DisclosureGroup("진행 상세", isExpanded: $showProgressDetails) {
                            StageProgressView(
                                title: "STT 추출",
                                icon: "waveform",
                                progress: snapshot.sttProgress,
                                liveLabel: "실시간 STT 추출 중",
                                liveText: snapshot.liveTranscriptText,
                                latestText: snapshot.lastTranscriptText
                            )
                            StageProgressView(
                                title: "다국어 번역",
                                icon: "character.book.closed",
                                progress: snapshot.translationProgress,
                                liveLabel: "실시간 번역 생성 중",
                                liveText: snapshot.liveTranslationText,
                                latestText: snapshot.lastTranslationText
                            )
                        }
                        if snapshot.status != .completed {
                            Button("작업 취소", role: .destructive) { model.cancel() }
                        }
                    }
                    Button("SRT 내보내기", systemImage: "square.and.arrow.up") { model.exportSRT() }
                    Button("영상 옆 결과 폴더 열기", systemImage: "folder") { model.revealOutput() }
                }
                Section("얼굴 모자이크 제거") {
                    Button("얼굴 모자이크 제거…", systemImage: "wand.and.stars") { showDemosaicSheet = true }
                        .disabled(!model.canStartDemosaic)
                    Text("실험적 · 결과는 AI로 재구성된 합성이며 실제 인물이 아닙니다. 권리 있는 영상에만 사용하세요.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section("화면 글자 번역 자막") {
                    Toggle("재생 중 화면 글자 인식·번역", isOn: $model.screenTextTranslationEnabled)
                    Text("영상에 박힌 글자(간판·자막 등)를 재생 중 OCR로 읽어 선택한 언어로 번역해 하단 자막으로 보여줍니다. 온디바이스 처리.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section("STT·번역 품질 개선") {
                    QualityImprovementStatusView(
                        snapshot: model.snapshot,
                        enabled: model.continuousImprovement,
                        maximumPasses: model.maximumRefinementPasses,
                        canResume: model.mediaURL != nil && model.canStart,
                        onResume: { model.startOrResume() },
                        onStop: { model.cancel() }
                    )
                }
                Section {
                    DisclosureGroup(isExpanded: $showServiceDetails) {
                        if let status = model.serviceStatus {
                            Text("PID \(status.processIdentifier) · 실행 작업 \(status.activeJobCount)개")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("상태 확인", systemImage: "arrow.clockwise") { model.refreshServiceStatus() }
                            Button("서버 다시 시작", systemImage: "restart", role: .destructive) { model.restartService() }
                                .disabled(model.isRestartingService)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(model.serviceIsAvailable ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(model.serviceMessage).font(.caption.weight(.medium))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 340)
        } detail: {
            // 플레이어·자막·화면글자 번역은 별도 뷰로 분리해, 실시간 갱신이 툴바를 다시 계산하지 않도록 합니다.
            PlayerPane()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggleFullScreen()
                } label: {
                    Label("전체화면", systemImage: "arrow.up.backward.and.arrow.down.forward")
                }
                .help("전체화면 전환 (⌃⌘F)")
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("설정", systemImage: "gearshape")
                }
                .help("설정 열기 (⌘,)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.hideTranscriptPanel.toggle()
                } label: {
                    Label(
                        model.hideTranscriptPanel ? "결과 패널 표시" : "결과 패널 감추기",
                        systemImage: model.hideTranscriptPanel ? "rectangle.bottomthird.inset.filled" : "rectangle.bottomthird.inset"
                    )
                }
                .disabled(model.isSimpleMode)
                .help(model.hideTranscriptPanel ? "아래 STT·번역 결과 패널 표시" : "아래 STT·번역 결과 패널 감추기")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isMiniViewer.toggle()
                } label: {
                    Label(model.isMiniViewer ? "미니 뷰어 종료" : "미니 뷰어", systemImage: model.isMiniViewer ? "arrow.up.left.and.arrow.down.right" : "pip")
                }
                .help(model.isMiniViewer ? "일반 창 크기로 돌아가기" : "작은 항상 위 영상 창으로 전환")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isSimpleMode.toggle()
                } label: {
                    Label(
                        model.isSimpleMode ? "일반 모드" : "심플 모드",
                        systemImage: model.isSimpleMode ? "rectangle.split.2x1" : "rectangle"
                    )
                }
                .help(model.isSimpleMode ? "왼쪽 컨트롤과 자막 목록 표시" : "영상과 재생 자막만 표시")
            }
        }
        .onAppear {
            columnVisibility = model.isSimpleMode ? .detailOnly : .all
        }
        .onChange(of: model.isSimpleMode) { _, simpleMode in
            withAnimation {
                columnVisibility = simpleMode ? .detailOnly : .all
            }
        }
        .onChange(of: model.isMiniViewer) { _, miniViewer in
            if miniViewer { model.isSimpleMode = true }
        }
        .confirmationDialog(
            regenerationRequest?.title ?? "결과를 재생성할까요?",
            isPresented: Binding(
                get: { regenerationRequest != nil },
                set: { if !$0 { regenerationRequest = nil } }
            ),
            presenting: regenerationRequest
        ) { request in
            Button(request.actionTitle, role: .destructive) {
                regenerationRequest = nil
                switch request {
                case .translation: model.regenerateTranslations()
                case .all: model.regenerateSTTAndTranslations()
                }
            }
            Button("취소", role: .cancel) { regenerationRequest = nil }
        } message: { request in
            Text(request.message)
        }
        .alert("VideoLingo", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .background(WindowModeAccessor(mini: model.isMiniViewer, opacity: model.windowOpacity))
        .sheet(isPresented: $showDemosaicSheet) {
            DemosaicSheet()
                .environment(model)
        }
    }
}

/// 왼쪽 사이드바의 심플 버전. 핵심 동작만 큰 버튼으로 보여줍니다.
private struct SimpleSidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var simpleSidebar: Bool

    private var isRunning: Bool {
        guard let status = model.snapshot?.status else { return false }
        return [.queued, .extracting, .transcribing, .translating, .synthesizing, .refining].contains(status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 영상
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    model.openVideo()
                } label: {
                    Label("영상 열기", systemImage: "film")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                if let url = model.mediaURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // 작업 (하나의 포커스 CTA: 시작은 강조, 중지는 파괴적)
            VStack(alignment: .leading, spacing: 8) {
                if isRunning {
                    Button(role: .destructive) {
                        model.cancel()
                    } label: {
                        Label("STT·번역 중지", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        model.startOrResume()
                    } label: {
                        Label("STT·번역 시작/재개", systemImage: "waveform.and.magnifyingglass")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
                }
                if let snapshot = model.snapshot {
                    ProgressView(value: snapshot.progress)
                    Text(snapshot.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .controlSize(.large)

            // 서버 상태
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(model.serviceMessage).lineLimit(2)
                } icon: {
                    Image(systemName: model.serviceIsAvailable ? "circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(model.serviceIsAvailable ? .green : .orange)
                        .imageScale(.small)
                }
                .font(.caption)
                Button("서버 상태 새로 고침", systemImage: "arrow.clockwise") {
                    model.refreshServiceStatus()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Spacer(minLength: 0)

            // 하단: 설정 / 고급 메뉴
            VStack(alignment: .leading, spacing: 8) {
                SettingsLink {
                    Label("설정", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button("고급 메뉴", systemImage: "slider.horizontal.3") {
                    simpleSidebar = false
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 영상 재생 영역. 화면글자 OCR 번역의 실시간 상태 변화를 이 뷰 안으로 가둬,
/// 툴바를 호스팅하는 ContentView가 매번 다시 계산되어 크래시하는 것을 방지합니다.
private struct PlayerPane: View {
    @Environment(AppModel.self) private var model
    @State private var screenTextConfig: TranslationSession.Configuration?
    @AppStorage("transcriptPanelHeight") private var transcriptPanelHeight: Double = 320

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: model.player)
                .background(Color.black)
                .overlay(alignment: .top) {
                    if model.screenTextTranslationEnabled,
                       let screenText = model.translatedScreenText,
                       !screenText.isEmpty {
                        PlayerCaption(text: screenText, color: .yellow)
                            .padding(.top, 14)
                    }
                }
                .overlay(alignment: .bottom) {
                    PlayerCaption(text: model.activeSubtitle)
                        .padding(.bottom, 16)
                }
            if !model.isSimpleMode && !model.hideTranscriptPanel {
                PanelResizeHandle(height: $transcriptPanelHeight)
                TranscriptInspector()
                    .frame(height: max(160, min(700, transcriptPanelHeight)))
            }
        }
        .overlay {
            if model.mediaURL == nil {
                ContentUnavailableView("영상을 선택하세요", systemImage: "film.stack", description: Text("MP4를 열면 재생과 동시에 로컬 STT·번역을 진행할 수 있습니다."))
                    .background(.background)
            }
        }
        .translationTask(screenTextConfig) { session in
            guard let text = model.recognizedScreenText, !text.isEmpty else {
                model.translatedScreenText = nil
                return
            }
            if let response = try? await session.translate(text) {
                model.translatedScreenText = response.targetText
            }
        }
        .onChange(of: model.recognizedScreenText) { _, _ in
            guard model.screenTextTranslationEnabled else { return }
            if screenTextConfig == nil {
                screenTextConfig = TranslationSession.Configuration(
                    source: nil,
                    target: Locale.Language(identifier: model.selectedLanguage)
                )
            } else {
                screenTextConfig?.invalidate()
            }
        }
        .onChange(of: model.selectedLanguage) { _, language in
            screenTextConfig = TranslationSession.Configuration(
                source: nil,
                target: Locale.Language(identifier: language)
            )
        }
    }
}

private struct DemosaicSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            Text("얼굴 모자이크 제거")
                .font(.title2.weight(.semibold))
                .padding(.bottom, 4)
            Text("모자이크는 비가역 손실이라 원본 복구가 아니라 AI 재구성입니다. 복원된 얼굴은 실제 인물이 아니며, 권리 있는 영상에만 사용하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
            Form {
                Picker("복원 모델", selection: $model.demosaicModel) {
                    Text("기본(Core Image)").tag(DemosaicModel.classical)
                    Text("Real-ESRGAN (모델 필요)").tag(DemosaicModel.realESRGAN)
                    Text("CodeFormer (모델 필요)").tag(DemosaicModel.codeFormer)
                }
                Toggle("얼굴 영역만 처리", isOn: $model.demosaicFaceOnly)
                VStack(alignment: .leading) {
                    Text("충실도 \(Int(model.demosaicFidelity * 100))%")
                        .font(.caption)
                    Slider(value: $model.demosaicFidelity, in: 0...1)
                }
                Toggle("합성 표식 남기기(권장)", isOn: $model.demosaicWatermark)
            }
            .formStyle(.grouped)
            .frame(height: 220)
            if model.demosaicModel != .classical {
                Label("이 모델을 쓰려면 Core ML 파일을 Models/Demosaic 폴더에 넣어야 합니다. 없으면 기본 복원으로 처리됩니다.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("모자이크 제거 시작") {
                    model.startDemosaic()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStartDemosaic)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 460)
    }
}

private enum RegenerationRequest: String, Identifiable {
    case translation
    case all

    var id: String { rawValue }
    var title: String {
        switch self {
        case .translation: "현재 언어 번역을 다시 생성할까요?"
        case .all: "STT와 모든 번역을 다시 생성할까요?"
        }
    }
    var actionTitle: String {
        switch self {
        case .translation: "번역 재생성"
        case .all: "STT·번역 재생성"
        }
    }
    var message: String {
        switch self {
        case .translation:
            "저장된 STT와 발화 타이밍은 유지하고 선택한 언어·모델의 번역만 삭제한 뒤 다시 생성합니다."
        case .all:
            "현재 영상의 기존 STT·번역 체크포인트와 사이드카 파일을 삭제한 뒤 처음부터 다시 생성합니다."
        }
    }
}

/// 하단 결과 패널 위의 드래그 핸들. 위아래로 끌어 패널 높이를 조절합니다.
private struct PanelResizeHandle: View {
    @Binding var height: Double
    @State private var startHeight: Double?
    private let minHeight: Double = 160
    private let maxHeight: Double = 700

    var body: some View {
        ZStack {
            Divider()
            Capsule()
                .fill(.secondary)
                .frame(width: 44, height: 5)
                .opacity(0.6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 12)
        .background(.background)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    let base = startHeight ?? height
                    if startHeight == nil { startHeight = height }
                    height = min(maxHeight, max(minHeight, base - value.translation.height))
                }
                .onEnded { _ in startHeight = nil }
        )
        .help("드래그해서 결과 패널 높이 조절")
    }
}

/// 영상 위에 얹는 통일된 자막 캡션. color가 nil이면 화자 색상(기본 흰색),
/// 지정하면 단색으로 렌더링합니다. 비어 있으면 아무것도 그리지 않습니다.
private struct PlayerCaption: View {
    let text: String
    var color: Color?

    init(text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        if !text.isEmpty {
            Group {
                if let color {
                    Text(text).foregroundStyle(color)
                } else {
                    SpeakerColoredText(text: text, defaultColor: .white)
                }
            }
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(.tail)
            .shadow(color: .black.opacity(0.85), radius: 3)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 24)
            .accessibilityLabel(text)
        }
    }
}

private struct StageProgressView: View {
    let title: String
    let icon: String
    let progress: Double
    let liveLabel: String
    let liveText: String?
    let latestText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
            if let liveText, !liveText.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label(liveLabel, systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                    SpeakerColoredText(text: liveText, defaultColor: .primary)
                        .font(.callout)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
            if let latestText, !latestText.isEmpty {
                SpeakerColoredText(text: latestText, defaultColor: .secondary)
                    .font(.caption)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else {
                Text("저장된 결과를 기다리는 중")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct QualityImprovementStatusView: View {
    let snapshot: JobSnapshot?
    let enabled: Bool
    let maximumPasses: Int
    let canResume: Bool
    let onResume: () -> Void
    let onStop: () -> Void

    private var liveCandidate: (label: String, text: String)? {
        if let text = snapshot?.liveTranslationText,
           text.contains("품질 개선 후보") {
            return ("번역 후보 검토 중", text)
        }
        if let text = snapshot?.liveTranscriptText,
           text.contains("품질 개선 후보") {
            return ("STT 후보 검토 중", text)
        }
        return nil
    }

    private var isRunning: Bool {
        snapshot?.status == .refining || liveCandidate != nil
    }

    private var state: (title: String, icon: String, color: Color) {
        guard enabled else { return ("자동 개선 꺼짐", "pause.circle", .secondary) }
        guard let snapshot else { return ("완료 후 자동 시작", "clock", .secondary) }
        if isRunning { return ("품질 개선 진행 중", "sparkles", .blue) }
        if snapshot.status == .failed { return ("오류 · 재개 가능", "exclamationmark.triangle", .orange) }
        if snapshot.status == .cancelled { return ("중지됨 · 재개 가능", "pause.circle", .orange) }
        if snapshot.status == .completed, snapshot.refinementPass != nil {
            return ("품질 개선 완료", "checkmark.seal", .green)
        }
        if snapshot.progress >= 1 { return ("품질 개선 대기", "clock", .secondary) }
        return ("STT·번역 완료 후 시작", "hourglass", .secondary)
    }

    private var refinementProgress: Double {
        if let progress = snapshot?.refinementProgress { return min(1, max(0, progress)) }
        return snapshot?.status == .completed && snapshot?.refinementPass != nil ? 1 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: state.icon)
                    .foregroundStyle(state.color)
                Text(state.title)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(snapshot?.refinementImprovements ?? 0)건 채택")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ProgressView(value: refinementProgress)
                Text(refinementProgress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("검토 \(snapshot?.refinementPass ?? 0)/\(maximumPasses)회차")
                Spacer()
                Text("완료 결과 보호")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if let liveCandidate {
                VStack(alignment: .leading, spacing: 4) {
                    Label(liveCandidate.label, systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                    SpeakerColoredText(text: liveCandidate.text, defaultColor: .primary)
                        .font(.caption)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            } else if let message = snapshot?.message, !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if isRunning {
                Button("품질 개선 중지", systemImage: "stop.circle", role: .destructive, action: onStop)
                    .buttonStyle(.borderless)
            } else if enabled, snapshot?.progress == 1 {
                Button("품질 개선 시작/재개", systemImage: "play.circle", action: onResume)
                    .buttonStyle(.borderless)
                    .disabled(!canResume)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("STT와 번역 품질 개선 상태")
    }
}

private enum ResultDisplayMode: String, CaseIterable, Identifiable {
    case transcript = "STT 원문"
    case translation = "번역"
    case both = "함께 보기"

    var id: Self { self }
}

private struct TranscriptInspector: View {
    @Environment(AppModel.self) private var model
    @State private var displayMode: ResultDisplayMode = .both
    @State private var searchText = ""
    @State private var lastAutoScrolledSegmentID: UUID?

    private var filteredSegments: [TranscriptSegment] {
        guard !searchText.isEmpty else { return model.transcript }
        return model.transcript.filter { segment in
            segment.text.localizedCaseInsensitiveContains(searchText)
                || model.translations[segment.id]?.text.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("STT·번역 결과 확인")
                            .font(.headline)
                        Text("STT \(model.transcript.count)개 · \(model.selectedLanguage.uppercased()) 번역 \(model.translations.count)개")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("표시 내용", selection: $displayMode) {
                        ForEach(ResultDisplayMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                    TextField("내용 검색", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button("현재 재생 위치", systemImage: "scope") {
                        locateCurrentPlayback(using: proxy)
                    }
                    .labelStyle(.iconOnly)
                    .help("현재 영상 재생 위치의 STT·번역 결과로 이동")
                    .disabled(model.activeTranscriptSegment == nil)
                    Button("새로 고침", systemImage: "arrow.clockwise") {
                        model.refreshResults()
                    }
                    .labelStyle(.iconOnly)
                    .help("저장된 STT·번역 결과 다시 불러오기")
                    let pendingCount = model.untranslatedSegments.count
                    Button {
                        model.retryUntranslatedSegments()
                    } label: {
                        Label("미번역 재시도\(pendingCount > 0 ? " (\(pendingCount))" : "")", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    }
                    .help("번역이 안 된 항목만 STT 추출과 번역을 다시 시도")
                    .disabled(!model.canRegenerate || pendingCount == 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                List(filteredSegments) { segment in
                    resultRow(segment)
                        .id(segment.id)
                        .listRowBackground(
                            model.activeTranscriptSegment?.id == segment.id
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                }
                .listStyle(.inset)
                .onChange(of: model.activeTranscriptSegment?.id) { _, segmentID in
                    guard searchText.isEmpty,
                          let segmentID,
                          segmentID != lastAutoScrolledSegmentID else { return }
                    lastAutoScrolledSegmentID = segmentID
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(segmentID, anchor: .center)
                    }
                }
            }
            .background(.background)
            .overlay {
                if model.transcript.isEmpty {
                    ContentUnavailableView(
                        "아직 확정된 결과가 없습니다",
                        systemImage: "captions.bubble",
                        description: Text("STT 청크가 확정되면 원문과 번역 내용이 여기에 추가됩니다.")
                    )
                    .padding(.top, 50)
                } else if filteredSegments.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 50)
                }
            }
        }
    }

    private func locateCurrentPlayback(using proxy: ScrollViewProxy) {
        guard let segment = model.activeTranscriptSegment else { return }
        if !searchText.isEmpty {
            searchText = ""
        }
        Task { @MainActor in
            await Task.yield()
            withAnimation {
                proxy.scrollTo(segment.id, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(time(segment.startTime))–\(time(segment.endTime))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("#\(segment.chunkIndex + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if let status = segment.qualityStatus {
                    qualityBadge("STT \(qualityLabel(status))", status: status)
                        .help((segment.qualityNotes ?? []).joined(separator: "\n"))
                }
                if displayMode != .transcript,
                   let translation = model.translations[segment.id],
                   let status = translation.qualityStatus {
                    qualityBadge("번역 \(qualityLabel(status))", status: status)
                        .help((translation.qualityNotes ?? []).joined(separator: "\n"))
                }
            }
            .frame(width: 100, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                if displayMode != .translation {
                    ResultTextBlock(label: "STT 원문", text: segment.text, color: .primary)
                }
                if displayMode != .transcript {
                    if let translated = model.translations[segment.id]?.text, !translated.isEmpty {
                        ResultTextBlock(label: "\(model.selectedLanguage.uppercased()) 번역", text: translated, color: .secondary)
                    } else {
                        Label("번역 대기 중", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .textSelection(.enabled)

            Spacer(minLength: 8)
            Button {
                model.regenerateSTT(for: segment)
            } label: {
                Image(systemName: "waveform.badge.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("이 구간 STT 재추출")
            .disabled(!model.canRegenerate)
            Button {
                model.regenerateTranslation(for: segment)
            } label: {
                Image(systemName: "character.book.closed")
            }
            .buttonStyle(.borderless)
            .help("이 문장 번역 재생성")
            .disabled(!model.canRegenerate)
            Button("이동") {
                model.player.seek(to: CMTime(seconds: segment.startTime, preferredTimescale: 600))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("이 구간으로 이동", systemImage: "arrow.right.circle") {
                model.player.seek(to: CMTime(seconds: segment.startTime, preferredTimescale: 600))
            }
            Divider()
            Button("이 구간 STT 재추출", systemImage: "waveform.badge.magnifyingglass") {
                model.regenerateSTT(for: segment)
            }
            .disabled(!model.canRegenerate)
            Button("이 문장 번역 재생성", systemImage: "character.book.closed") {
                model.regenerateTranslation(for: segment)
            }
            .disabled(!model.canRegenerate)
        }
    }

    private func qualityLabel(_ status: SegmentQualityStatus) -> String {
        switch status {
        case .good: String(localized: "양호")
        case .reviewed: String(localized: "재검토됨")
        case .warning: String(localized: "확인 필요")
        }
    }

    private func qualityIcon(_ status: SegmentQualityStatus) -> String {
        switch status {
        case .good: "checkmark.circle"
        case .reviewed: "checkmark.seal"
        case .warning: "exclamationmark.triangle"
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

private struct ResultTextBlock: View {
    let label: String
    let text: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(label))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            SpeakerColoredText(text: text, defaultColor: color)
        }
    }
}

private struct SpeakerColoredText: View {
    let text: String
    let defaultColor: Color

    var body: some View {
        renderedText
    }

    private var renderedText: Text {
        var result = AttributedString()
        for (index, lineValue) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 {
                result.append(AttributedString("\n"))
            }
            let line = String(lineValue)
            var attributedLine = AttributedString(line)
            attributedLine.foregroundColor = speakerLabel(in: line).map(speakerColor) ?? defaultColor
            result.append(attributedLine)
        }
        return Text(result)
    }

    private func speakerLabel(in line: String) -> String? {
        guard line.hasPrefix("["), let closingBracket = line.firstIndex(of: "]") else { return nil }
        let start = line.index(after: line.startIndex)
        guard start < closingBracket else { return nil }
        return String(line[start..<closingBracket])
    }

    private func speakerColor(_ speaker: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.10, green: 0.62, blue: 0.92),
            Color(red: 0.94, green: 0.42, blue: 0.12),
            Color(red: 0.16, green: 0.66, blue: 0.34),
            Color(red: 0.90, green: 0.24, blue: 0.55),
            Color(red: 0.58, green: 0.35, blue: 0.92),
            Color(red: 0.05, green: 0.68, blue: 0.65),
            Color(red: 0.72, green: 0.48, blue: 0.10),
            Color(red: 0.34, green: 0.48, blue: 0.88)
        ]
        if speaker.hasPrefix("화자 "), let number = Int(speaker.dropFirst("화자 ".count)) {
            return palette[(max(1, number) - 1) % palette.count]
        }
        let stableValue = speaker.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[stableValue % palette.count]
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("일반", systemImage: "gearshape") }
            DatabaseSettingsView()
                .tabItem { Label("데이터베이스", systemImage: "cylinder") }
            ServerSettingsView()
                .tabItem { Label("LLM 서버", systemImage: "server.rack") }
            ModelFilesSettingsView()
                .tabItem { Label("모델 파일", systemImage: "square.and.arrow.down") }
            KeyboardShortcutSettingsView()
                .tabItem { Label("단축키", systemImage: "keyboard") }
        }
        .frame(width: 680, height: 520)
        .task { model.refreshSettings() }
        .onAppear { model.applyWindowTransparency() }
    }
}

private struct GeneralSettingsView: View {
    @Environment(LocalizationManager.self) private var localization
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var localization = localization
        @Bindable var model = model
        Form {
            Section("언어") {
                Picker("표시 언어", selection: $localization.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text("앱 메뉴와 화면 문구에 사용할 언어입니다. 변경하면 즉시 적용됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("동작") {
                Toggle("앱 시작 시 무음", isOn: $model.startMuted)
                Toggle("마지막 영상 자동 복원", isOn: $model.autoloadLastVideoPreference)
                Toggle("이전 재생 위치 기억", isOn: $model.rememberPlaybackPosition)
                Text("동작 설정은 앱을 재시작하면 반영됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("번역 품질 개선") {
                Toggle("완료 후 자동 품질 개선", isOn: $model.continuousImprovement)
                Picker("최대 개선 회차", selection: $model.maximumRefinementPasses) {
                    ForEach(1...5, id: \.self) { Text("\($0)회").tag($0) }
                }
                .disabled(!model.continuousImprovement)
                Toggle("완료 후 재검토·미번역 구간 자동 재시도", isOn: $model.autoRetryReviewedAndUntranslated)
                Text("변경 사항은 새로 시작하는 작업부터 적용됩니다. 실행 중인 창은 앱을 재시작하면 반영됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyboardShortcutSettingsView: View {
    @Environment(ShortcutSettings.self) private var shortcuts
    private let categories = ["앱·화면", "재생", "STT·번역"]

    var body: some View {
        Form {
            Section {
                Text("오른쪽 단축키 영역을 클릭한 다음 원하는 키 조합을 누르세요. 방향키와 Space는 보조키 없이 사용할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(categories, id: \.self) { category in
                Section(LocalizedStringKey(category)) {
                    ForEach(ShortcutAction.allCases.filter { $0.category == category }) { action in
                        LabeledContent(LocalizedStringKey(action.title)) {
                            ShortcutRecorder(shortcut: shortcuts[action]) { value in
                                shortcuts.assign(value, to: action)
                            }
                            .frame(width: 118, height: 28)
                        }
                    }
                }
            }
            Section {
                HStack {
                    Button("기본 단축키 복원", systemImage: "arrow.counterclockwise") {
                        shortcuts.reset()
                    }
                    Spacer()
                    if !shortcuts.message.isEmpty {
                        Text(shortcuts.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DatabaseSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsReset = false

    private var databasePath: String {
        (try? AppPaths().database.path) ?? "경로를 확인할 수 없습니다."
    }

    var body: some View {
        Form {
            Section("DB 상태") {
                LabeledContent("작업", value: "\(model.databaseStatistics.jobCount)개")
                LabeledContent("STT 문장", value: "\(model.databaseStatistics.transcriptCount)개")
                LabeledContent("번역 문장", value: "\(model.databaseStatistics.translationCount)개")
                LabeledContent("사용 용량", value: formattedBytes(model.databaseSizeInBytes))
                LabeledContent("저장 위치") {
                    Text(databasePath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
            Section("관리") {
                HStack {
                    Button("Finder에서 보기", systemImage: "folder") { model.revealDatabase() }
                    Button("DB 최적화", systemImage: "sparkles") { model.optimizeDatabase() }
                        .disabled(!model.canMutateStorage || model.settingsIsBusy)
                    Spacer()
                    Button("모든 DB 기록 삭제", systemImage: "trash", role: .destructive) {
                        confirmsReset = true
                    }
                    .disabled(!model.canMutateStorage || model.settingsIsBusy)
                }
                Text("최적화는 WAL 체크포인트, VACUUM, SQLite 최적화를 순서대로 실행합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsMessageView()
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog("모든 DB 기록을 삭제할까요?", isPresented: $confirmsReset) {
            Button("작업·STT·번역 기록 삭제", role: .destructive) { model.deleteAllDatabaseData() }
        } message: {
            Text("모델 파일과 원본 영상은 삭제되지 않지만 DB 기록은 복구할 수 없습니다.")
        }
    }
}

private struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("내장 LLM 서버") {
                HStack {
                    Circle()
                        .fill(model.serviceIsAvailable ? Color.green : (model.isRestartingService ? Color.orange : Color.red))
                        .frame(width: 10, height: 10)
                    Text(model.serviceMessage)
                    Spacer()
                    if model.isRestartingService { ProgressView().controlSize(.small) }
                }
                if let status = model.serviceStatus {
                    LabeledContent("프로세스 ID", value: "\(status.processIdentifier)")
                    LabeledContent("실행 중 작업", value: "\(status.activeJobCount)개")
                    LabeledContent("시작 시간", value: status.startedAt.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("버전", value: status.version)
                }
            }
            Section("서버 제어") {
                HStack {
                    Button("상태 확인", systemImage: "arrow.clockwise") { model.refreshServiceStatus() }
                    Button("서버 다시 시작", systemImage: "restart", role: .destructive) { model.restartService() }
                        .disabled(model.isRestartingService)
                }
                Text("재시작 중인 STT·번역 작업은 DB의 마지막 저장 지점부터 자동으로 이어집니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsMessageView()
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ModelDeleteTarget: Identifiable {
    let kind: ManagedModelKind
    let modelID: String
    var id: String { "\(kind.rawValue):\(modelID)" }
}

private struct ModelFilesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var deleteTarget: ModelDeleteTarget?
    @State private var demosaicModelName = "realesrgan"
    @State private var demosaicModelURL = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section("얼굴 모자이크 제거 모델") {
                Picker("모델 이름", selection: $demosaicModelName) {
                    Text("realesrgan").tag("realesrgan")
                    Text("codeformer").tag("codeformer")
                }
                TextField("Core ML 모델 URL (.zip 권장)", text: $demosaicModelURL)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("모델 다운로드", systemImage: "square.and.arrow.down") {
                        if let url = URL(string: demosaicModelURL.trimmingCharacters(in: .whitespaces)) {
                            model.downloadDemosaicModel(name: demosaicModelName, sourceURL: url)
                        }
                    }
                    .disabled(URL(string: demosaicModelURL.trimmingCharacters(in: .whitespaces)) == nil)
                    Spacer()
                    demosaicStatus(demosaicModelName)
                }
                Text("Models/Demosaic/<이름>.mlpackage 로 저장되며 .zip은 자동 추출됩니다. 변환 방법은 docs/mosaic-removal/COREML_MODELS.md 참고.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("Whisper STT 모델") {
                ForEach(model.models, id: \.self) { modelID in
                    modelRow(kind: .stt, modelID: modelID)
                }
            }
            Section("음성 합성 모델") {
                modelRow(kind: .tts, modelID: "qwen3-tts-0.6b")
            }
            Section("번역 LLM") {
                Picker("사용할 번역 모델", selection: $model.translationModel) {
                    ForEach(model.translationModels, id: \.self) { modelID in
                        Text(translationModelName(modelID)).tag(modelID)
                    }
                }
                LabeledContent("Apple Foundation Models", value: "macOS에서 관리")
                Text("번역 모델 파일은 Apple Intelligence 시스템 자산이므로 앱에서 직접 다운로드하거나 삭제하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.translationModels.filter { $0 != "apple-foundation-models" }, id: \.self) { modelID in
                    modelRow(kind: .translation, modelID: modelID)
                }
            }
            Section {
                HStack {
                    Button("상태 새로 고침", systemImage: "arrow.clockwise") { model.refreshModelManager() }
                    Button("모델 폴더 열기", systemImage: "folder") { model.revealModelsFolder() }
                }
                Text("다운로드 파일은 Application Support/VideoLingo/Models에 저장되며 앱 재실행 후에도 유지됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsMessageView()
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "모델 파일을 삭제할까요?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { target in
            Button("\(target.modelID) 삭제", role: .destructive) {
                model.deleteModel(kind: target.kind, modelID: target.modelID)
            }
        } message: { target in
            Text("다음 사용 시 \(target.modelID) 모델을 다시 다운로드해야 합니다.")
        }
    }

    @ViewBuilder
    private func demosaicStatus(_ name: String) -> some View {
        if let record = model.managedModel(kind: .demosaic, modelID: name) {
            switch record.state {
            case .downloading:
                Text("다운로드 중 \(Int((record.progress * 100).rounded()))%")
                    .font(.caption).foregroundStyle(.secondary)
            case .downloaded:
                Label("설치됨", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed:
                Label(record.error ?? "실패", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            case .notDownloaded:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func modelRow(kind: ManagedModelKind, modelID: String) -> some View {
        let record = model.managedModel(kind: kind, modelID: modelID)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(kind == .translation ? translationModelName(modelID) : modelID)
                    .font(.callout.weight(.medium))
                switch record?.state ?? .notDownloaded {
                case .notDownloaded:
                    Text("다운로드되지 않음").font(.caption).foregroundStyle(.secondary)
                case .downloading:
                    ProgressView(value: record?.progress ?? 0)
                    Text(record?.progress ?? 0, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                case .downloaded:
                    Text("다운로드 완료 · \(formattedBytes(record?.sizeInBytes ?? 0))")
                        .font(.caption).foregroundStyle(.green)
                case .failed:
                    Text(record?.error ?? "다운로드 실패")
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            if record?.state == .downloaded {
                Button("삭제", role: .destructive) {
                    deleteTarget = ModelDeleteTarget(kind: kind, modelID: modelID)
                }
                .disabled(!model.canMutateStorage)
            } else if record?.state != .downloading {
                Button("다운로드") { model.downloadModel(kind: kind, modelID: modelID) }
                    .disabled(!model.serviceIsAvailable || !model.canMutateStorage)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SettingsMessageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.settingsMessage.isEmpty {
            Section("최근 작업") {
                Text(model.settingsMessage)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
    }
}

private func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func translationModelName(_ modelID: String) -> String {
    switch modelID {
    case "apple-foundation-models": String(localized: "Apple Foundation Models (시스템)")
    case "mlx-community/Qwen3-0.6B-4bit": "Qwen3 0.6B 4-bit"
    case "mlx-community/Qwen3-1.7B-4bit": "Qwen3 1.7B 4-bit"
    case "mlx-community/Qwen3-4B-4bit": String(localized: "Qwen3 4B 4-bit · 균형")
    case "mlx-community/Qwen3-8B-4bit": String(localized: "Qwen3 8B 4-bit · 고품질")
    case "mlx-community/gemma-3-1b-it-qat-4bit": "Gemma 3 1B QAT 4-bit"
    default: modelID
    }
}
