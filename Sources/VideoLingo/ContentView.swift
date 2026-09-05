import AVKit
import SwiftUI
@preconcurrency import Translation
import VideoLingoCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(ThemeManager.self) private var theme
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showDemosaicSheet = false
    @AppStorage("simpleSidebar") private var simpleSidebar = false
    @State private var regenerationRequest: RegenerationRequest?
    @State private var showAdvancedSettings = false
    @State private var showProgressDetails = false
    @State private var showServiceDetails = false

    private var isCurrentJobRunning: Bool {
        guard let status = model.snapshot?.status else { return false }
        return [.queued, .extracting, .transcribing, .translating, .synthesizing, .refining].contains(status)
    }

    var body: some View {
        @Bindable var model = model
        Group {
        if model.isTheaterMode {
            PlayerPane()
                .background(Color.black)
                .ignoresSafeArea()
        } else {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Group {
            if model.playerMode == .viewing {
                ViewingSidebarView()
            } else if simpleSidebar {
                SimpleSidebarView(simpleSidebar: $simpleSidebar)
            } else {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Picker("플레이어 모드", selection: $model.playerMode) {
                            ForEach(PlayerWorkspaceMode.allCases) { mode in
                                Label(mode.title, systemImage: mode.symbol).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Button("심플 메뉴로 전환", systemImage: "list.bullet") { simpleSidebar = true }
                            .labelStyle(.iconOnly)
                            .help("핵심 버튼만 표시하는 심플 메뉴로 전환")
                    }

                    HStack(spacing: 8) {
                        Button { model.openVideo() } label: {
                            Label("영상 열기", systemImage: "film")
                                .frame(maxWidth: .infinity)
                        }
                        Button {
                                BatchProcessor.shared.configure(options: model.currentProcessingOptions())
                                openWindow(id: "batch")
                        } label: {
                            Label("대량 번역", systemImage: "rectangle.stack.badge.play")
                                .frame(maxWidth: .infinity)
                        }
                        .help("여러 영상을 새 창에서 동시에 STT·LLM 번역합니다")
                    }
                    .buttonStyle(.bordered)

                    if isCurrentJobRunning {
                        Button(role: .destructive) {
                            model.cancel()
                        } label: {
                            Label("STT·번역 중지", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            model.startOrResume()
                        } label: {
                            Label("STT·번역 시작/재개", systemImage: "waveform.and.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStart)
                        .help(model.mediaURL == nil ? "먼저 영상을 열어 주세요" : "현재 설정으로 STT·번역을 시작하거나 저장된 지점부터 재개")
                    }

                    if let snapshot = model.snapshot {
                        HStack(spacing: 8) {
                            ProgressView(value: snapshot.progress)
                            Text(snapshot.progress, format: .percent.precision(.fractionLength(0)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(snapshot.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .controlSize(.large)
                .padding(16)

                Divider()

            Form {
                Section("현재 영상") {
                    if let url = model.mediaURL {
                        Text(url.lastPathComponent).lineLimit(2).font(.caption)
                        if let resultURL = model.resultDirectoryURL {
                            Text("결과: \(resultURL.lastPathComponent)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("상단의 ‘영상 열기’를 눌러 번역할 영상을 선택하세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("언어 및 자막") {
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
                    Toggle("원문과 번역 자막 함께 보기", isOn: $model.showOriginalWithTranslation)
                        .help("번역 자막 아래에 같은 구간의 원문 STT를 함께 표시합니다")
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
                        Toggle("완료 후 미번역 구간 자동 재시도", isOn: $model.autoRetryUntranslated)
                            .help("품질 개선까지 끝나면 번역이 비어 있는 구간만 한 번 더 시도합니다. STT 재검토 상태는 자동 재추출하지 않습니다.")
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
                            ForEach(model.models, id: \.self) { Text(sttModelName($0)).tag($0) }
                        }
                        Picker("번역 LLM", selection: $model.translationModel) {
                            ForEach(model.translationModels, id: \.self) { modelID in
                                Text(translationModelName(modelID)).tag(modelID)
                            }
                        }
                        .onChange(of: model.translationModel) { _, _ in model.refreshResults() }
                        if model.translationModel == ProcessingOptions.externalServerModelID {
                            ExternalServerFields()
                        }
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
                Section("결과 및 재처리") {
                    Menu("결과 재생성", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                        Button("STT 재생성", systemImage: "waveform.badge.magnifyingglass") {
                            model.regenerateSTT()
                        }
                        .disabled(!model.canRegenerateSTT)
                        .help("기존 STT를 유지한 채 전체 구간을 다시 추출하고, 더 나은 결과만 반영합니다")
                        Button("번역만 재생성", systemImage: "character.book.closed") {
                            regenerationRequest = .translation
                        }
                    }
                    .disabled(!model.canRegenerate)
                    Button("기존 결과 삭제 후 재생성", systemImage: "trash", role: .destructive) {
                        regenerationRequest = .deleteAll
                    }
                    .disabled(!model.canRegenerate)
                    .help("현재 영상의 STT·번역 결과를 모두 삭제하고 처음부터 다시 생성합니다")
                    Button("화자 이름 분석 적용", systemImage: "person.text.rectangle") {
                        model.startOrResume()
                    }
                    .disabled(!model.canRegenerate || model.transcript.isEmpty)
                    .help("저장된 전체 스크립트에서 이름과 역할을 분석하고 STT·번역 결과에 반영합니다")
                    if let snapshot = model.snapshot {
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
                    }
                    Button("SRT 내보내기", systemImage: "square.and.arrow.up") { model.exportSRT() }
                    Button("iPhone·iPad로 공유", systemImage: "iphone.and.arrow.forward") {
                        model.exportMobilePackage()
                    }
                    .disabled(model.isExportingMobilePackage || model.transcript.isEmpty)
                    Button("영상 옆 결과 폴더 열기", systemImage: "folder") { model.revealOutput() }
                    if model.isExportingMobilePackage {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if !model.mobileExportMessage.isEmpty {
                        Text(model.mobileExportMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                        .disabled(AppModel.screenTextTranslationTemporarilyDisabled)
                    Text(AppModel.screenTextTranslationTemporarilyDisabled
                        ? "성능 보호를 위해 임시 비활성화되었습니다. 다른 방식으로 다시 제공할 예정입니다."
                        : "영상에 박힌 글자(간판·자막 등)를 재생 중 OCR로 읽어 선택한 언어로 번역해 하단 자막으로 보여줍니다. 온디바이스 처리.")
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
            .scrollContentBackground(theme.translucent ? .hidden : .automatic)
            }
            }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 340)
            .background {
                if theme.translucent {
                    VisualEffectView(material: .sidebar).ignoresSafeArea()
                }
            }
        } detail: {
            // 플레이어·자막·화면글자 번역은 별도 뷰로 분리해, 실시간 갱신이 툴바를 다시 계산하지 않도록 합니다.
            PlayerPane()
        }
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
                case .deleteAll: model.regenerateSTTAndTranslations()
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
        .background(WindowModeAccessor(model: model, mini: model.isMiniViewer, opacity: model.windowOpacity, translucent: theme.translucent))
        .sheet(isPresented: $showDemosaicSheet) {
            DemosaicSheet()
                .environment(model)
        }
        .overlay {
            if model.isMiniViewer {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
                    .allowsHitTesting(false)
            }
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
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 20) {
            Picker("플레이어 모드", selection: $model.playerMode) {
                ForEach(PlayerWorkspaceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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

/// AI 작업 설정을 감추고 재생·자막·화면 제어만 제공하는 영상 감상 전용 사이드바입니다.
private struct ViewingSidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("플레이어 모드", selection: $model.playerMode) {
                    ForEach(PlayerWorkspaceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("영상") {
                Button("영상 열기…", systemImage: "film") { model.openVideo() }
                    .buttonStyle(.borderedProminent)
                if let url = model.mediaURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Section("재생") {
                HStack(spacing: 8) {
                    Button("10초 뒤로", systemImage: "gobackward.10") { model.seekVideo(by: -10) }
                        .labelStyle(.iconOnly)
                    Button(playbackTitle, systemImage: playbackSymbol) { model.togglePlayback() }
                        .buttonStyle(.borderedProminent)
                    Button("10초 앞으로", systemImage: "goforward.10") { model.seekVideo(by: 10) }
                        .labelStyle(.iconOnly)
                }
                .controlSize(.large)
                .disabled(model.mediaURL == nil)

                Text("\(timeText(model.currentTime)) / \(timeText(duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Section("자막") {
                Toggle("자막 표시", isOn: $model.subtitlesEnabled)
                Picker("번역 언어", selection: $model.selectedLanguage) {
                    ForEach(model.targetLanguages, id: \.self) { language in
                        Text(language.uppercased()).tag(language)
                    }
                }
                .disabled(!model.subtitlesEnabled || model.targetLanguages.isEmpty)
                .onChange(of: model.selectedLanguage) { _, _ in model.refreshResults() }
                Toggle("원문과 번역 함께 보기", isOn: $model.showOriginalWithTranslation)
                    .disabled(!model.subtitlesEnabled)
            }

            Section("화면") {
                Button("전체 화면", systemImage: "arrow.up.left.and.arrow.down.right") {
                    model.toggleFullScreen()
                }
                Button(model.isMiniViewer ? "미니 뷰어 종료" : "미니 뷰어", systemImage: "pip") {
                    model.isMiniViewer.toggle()
                }
                Button("영화관 보기", systemImage: "rectangle.inset.filled") {
                    model.isTheaterMode = true
                    model.toggleFullScreen()
                }
            }
            .disabled(model.mediaURL == nil)

            Section {
                Text("STT·번역 작업이 실행 중이어도 감상 모드에서는 백그라운드에서 계속됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var playbackTitle: String {
        model.player.timeControlStatus == .playing ? "일시 정지" : "재생"
    }

    private var playbackSymbol: String {
        model.player.timeControlStatus == .playing ? "pause.fill" : "play.fill"
    }

    private var duration: TimeInterval {
        let seconds = model.player.currentItem?.duration.seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

/// 영상 재생 영역. 화면글자 OCR 번역의 실시간 상태 변화를 이 뷰 안으로 가둬,
/// 툴바를 호스팅하는 ContentView가 매번 다시 계산되어 크래시하는 것을 방지합니다.
private struct PlayerPane: View {
    @Environment(AppModel.self) private var model
    @Environment(ThemeManager.self) private var theme
    @State private var screenTextConfig: TranslationSession.Configuration?
    @AppStorage("transcriptPanelHeight") private var transcriptPanelHeight: Double = 320
    @AppStorage("subtitlePositionX") private var subtitlePositionX = 0.5
    @AppStorage("subtitlePositionY") private var subtitlePositionY = 0.86
    @AppStorage("subtitlePositionLocked") private var subtitlePositionLocked = false
    @State private var subtitleDragStart: CGPoint?
    @State private var swipeSeekStart: TimeInterval?
    @State private var swipeSeekTarget: TimeInterval?
    @State private var swipeSeekFeedback: TimeInterval?
    @State private var swipeFeedbackID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            PlayerVideoSurface(player: model.player)
                .background(Color.black)
                .overlay(alignment: .top) {
                    if model.screenTextTranslationEnabled,
                       let screenText = model.translatedScreenText,
                       !screenText.isEmpty {
                        PlayerCaption(text: screenText, color: .yellow)
                            .padding(.top, model.mediaURL != nil && theme.volumeBarPosition == .top ? 58 : 14)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    GeometryReader { geometry in
                        if model.subtitlesEnabled, !model.activeSubtitle.isEmpty {
                            VStack(spacing: 6) {
                                PlayerCaption(
                                    text: model.activeSubtitle,
                                    color: theme.subtitleColor,
                                    opacity: theme.subtitleOpacity
                                )
                                if model.showOriginalWithTranslation,
                                   model.activeTranslationSubtitle != nil,
                                   !model.activeOriginalSubtitle.isEmpty {
                                    PlayerCaption(
                                        text: model.activeOriginalSubtitle,
                                        color: .white,
                                        isSecondary: true,
                                        isItalic: model.originalSubtitleItalic,
                                        opacity: theme.subtitleOpacity * (model.originalSubtitleTranslucent ? 0.68 : 1)
                                    )
                                }
                            }
                                .frame(maxWidth: max(0, geometry.size.width - 48))
                                .position(
                                    x: geometry.size.width * subtitlePositionX,
                                    y: geometry.size.height * subtitlePositionY
                                )
                                .contentShape(Rectangle())
                                .overlay {
                                    if !subtitlePositionLocked {
                                        RightMouseDragSurface { translation in
                                            moveSubtitle(by: translation, in: geometry.size)
                                        } onEnded: {
                                            subtitleDragStart = nil
                                        }
                                    }
                                }
                                .help(subtitlePositionLocked ? "자막 위치가 고정되어 있습니다" : "오른쪽 버튼을 누른 채 드래그해서 자막 위치 이동")
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.mediaURL != nil {
                        HStack(spacing: 8) {
                            // 번역 자막을 화면에서 없앴다 되돌리는 토글입니다.
                            CaptionOverlayButton(
                                title: model.subtitlesEnabled ? "자막 끄기" : "자막 켜기",
                                systemImage: model.subtitlesEnabled ? "captions.bubble.fill" : "captions.bubble"
                            ) {
                                withAnimation(.snappy) { model.subtitlesEnabled.toggle() }
                            }
                            // 자막을 반투명하게 만들어 화면을 덜 가리게 합니다.
                            CaptionOverlayButton(
                                title: theme.subtitleTranslucent ? "자막 불투명하게" : "자막 반투명하게",
                                systemImage: theme.subtitleTranslucent ? "circle.lefthalf.filled" : "circle.fill"
                            ) {
                                withAnimation(.snappy) { theme.toggleSubtitleTranslucency() }
                            }
                            .disabled(!model.subtitlesEnabled)
                            CaptionOverlayButton(
                                title: subtitlePositionLocked ? "자막 위치 고정 해제" : "자막 위치 고정",
                                systemImage: subtitlePositionLocked ? "lock.fill" : "lock.open",
                                accessibilityValue: subtitlePositionLocked ? "고정됨" : "이동 가능"
                            ) {
                                subtitleDragStart = nil
                                withAnimation(.snappy) { subtitlePositionLocked.toggle() }
                            }
                        }
                        .padding(12)
                    }
                }
                .overlay {
                    PlayerInteractionSurface {
                        model.togglePlayback()
                    } onHorizontalSwipe: { seconds in
                        seekWithSwipe(by: seconds)
                    } onSwipeEnded: {
                        swipeSeekStart = nil
                        swipeSeekTarget = nil
                    }
                }
                .overlay {
                    if let seconds = swipeSeekFeedback {
                        Label(
                            swipeFeedbackText(seconds),
                            systemImage: seconds < 0 ? "gobackward" : "goforward"
                        )
                        .font(.headline)
                        .monospacedDigit()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .overlay(alignment: theme.volumeBarPosition.alignment) {
                    // 재생 조작 레이어보다 뒤에 놓아야 슬라이더 드래그가 가려지지 않습니다.
                    if model.mediaURL != nil {
                        PlayerControlBar(
                            volume: Binding(
                                get: { Double(model.player.volume) },
                                set: { model.player.volume = Float($0) }
                            ),
                            currentTime: model.currentTime,
                            duration: model.duration,
                            isPlaying: model.isPlaying,
                            onTogglePlayback: { model.togglePlayback() },
                            onSeek: { model.seekVideo(to: $0) }
                        )
                        .padding(theme.volumeBarPosition.edge, 12)
                    }
                }
                .contextMenu {
                    Button {
                        model.subtitlesEnabled.toggle()
                    } label: {
                        Label(
                            model.subtitlesEnabled ? "자막 끄기" : "자막 켜기",
                            systemImage: model.subtitlesEnabled ? "captions.bubble.fill" : "captions.bubble"
                        )
                    }
                }
            if model.playerMode == .translation && !model.isSimpleMode && !model.hideTranscriptPanel {
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

    private func moveSubtitle(by translation: CGSize, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let start = subtitleDragStart ?? CGPoint(x: subtitlePositionX, y: subtitlePositionY)
        if subtitleDragStart == nil { subtitleDragStart = start }
        subtitlePositionX = min(0.92, max(0.08, start.x + translation.width / size.width))
        subtitlePositionY = min(0.92, max(0.08, start.y + translation.height / size.height))
    }

    private func seekWithSwipe(by seconds: TimeInterval) {
        guard let item = model.player.currentItem else { return }
        let current = model.player.currentTime().seconds
        guard current.isFinite else { return }

        let start = swipeSeekStart ?? current
        let previousTarget = swipeSeekTarget ?? current
        var target = max(0, previousTarget + seconds)
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 {
            target = min(target, duration)
        }
        swipeSeekStart = start
        swipeSeekTarget = target
        model.player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)
        )

        let feedbackID = UUID()
        swipeFeedbackID = feedbackID
        withAnimation(.snappy) {
            swipeSeekFeedback = target - start
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard swipeFeedbackID == feedbackID else { return }
            withAnimation(.snappy) {
                swipeSeekFeedback = nil
            }
        }
    }

    private func swipeFeedbackText(_ seconds: TimeInterval) -> String {
        let rounded = Int64(abs(seconds).rounded())
        let format = seconds < 0
            ? String(localized: "%lld초 뒤로")
            : String(localized: "%lld초 앞으로")
        return String(format: format, rounded)
    }
}

/// AVPlayer의 기본 컨트롤은 그대로 통과시키면서 더블 클릭과 가로 스와이프만 받습니다.
private struct PlayerInteractionSurface: NSViewRepresentable {
    let onDoubleClick: () -> Void
    let onHorizontalSwipe: (TimeInterval) -> Void
    let onSwipeEnded: () -> Void

    func makeNSView(context: Context) -> SurfaceView {
        SurfaceView(
            onDoubleClick: onDoubleClick,
            onHorizontalSwipe: onHorizontalSwipe,
            onSwipeEnded: onSwipeEnded
        )
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.onDoubleClick = onDoubleClick
        view.onHorizontalSwipe = onHorizontalSwipe
        view.onSwipeEnded = onSwipeEnded
    }

    final class SurfaceView: NSView {
        var onDoubleClick: () -> Void
        var onHorizontalSwipe: (TimeInterval) -> Void
        var onSwipeEnded: () -> Void

        init(
            onDoubleClick: @escaping () -> Void,
            onHorizontalSwipe: @escaping (TimeInterval) -> Void,
            onSwipeEnded: @escaping () -> Void
        ) {
            self.onDoubleClick = onDoubleClick
            self.onHorizontalSwipe = onHorizontalSwipe
            self.onSwipeEnded = onSwipeEnded
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            if event.type == .leftMouseDown, event.clickCount >= 2 {
                return self
            }
            if event.type == .scrollWheel,
               abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
               abs(event.scrollingDeltaX) > 0.1 {
                return self
            }
            return nil
        }

        override func mouseDown(with event: NSEvent) {
            guard event.clickCount >= 2 else { return }
            onDoubleClick()
        }

        override func scrollWheel(with event: NSEvent) {
            let horizontal = event.scrollingDeltaX
            guard abs(horizontal) > abs(event.scrollingDeltaY), abs(horizontal) > 0.1 else {
                nextResponder?.scrollWheel(with: event)
                return
            }

            // 정밀 트랙패드는 포인트 단위이므로 부드럽게, 휠은 한 단계씩 탐색합니다.
            let multiplier = event.hasPreciseScrollingDeltas ? 0.18 : 2.0
            let seconds = min(12, max(-12, horizontal * multiplier))
            onHorizontalSwipe(seconds)
            if event.phase == .ended || event.momentumPhase == .ended {
                onSwipeEnded()
            }
        }
    }
}

/// 왼쪽 클릭은 아래의 VideoPlayer로 통과시키고, 오른쪽 버튼 드래그만 자막 이동에 사용합니다.
private struct RightMouseDragSurface: NSViewRepresentable {
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> SurfaceView {
        SurfaceView(onChanged: onChanged, onEnded: onEnded)
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.onChanged = onChanged
        view.onEnded = onEnded
    }

    final class SurfaceView: NSView {
        var onChanged: (CGSize) -> Void
        var onEnded: () -> Void
        private var dragStart: NSPoint?

        init(onChanged: @escaping (CGSize) -> Void, onEnded: @escaping () -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func rightMouseDown(with event: NSEvent) {
            dragStart = event.locationInWindow
            NSCursor.closedHand.set()
        }

        override func rightMouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            let current = event.locationInWindow
            onChanged(CGSize(
                width: current.x - dragStart.x,
                height: dragStart.y - current.y
            ))
        }

        override func rightMouseUp(with event: NSEvent) {
            dragStart = nil
            onEnded()
            NSCursor.openHand.set()
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
                Picker("처리 영역", selection: $model.demosaicRegionMode) {
                    Text("얼굴 영역만").tag(DemosaicRegionMode.face)
                    Text("모자이크 자동 탐지(실험적)").tag(DemosaicRegionMode.autoMosaic)
                    Text("전체 화면").tag(DemosaicRegionMode.wholeFrame)
                }
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
    case deleteAll

    var id: String { rawValue }
    var title: String {
        switch self {
        case .translation: "현재 언어 번역을 다시 생성할까요?"
        case .deleteAll: "기존 결과를 삭제하고 다시 생성할까요?"
        }
    }
    var actionTitle: String {
        switch self {
        case .translation: "번역 재생성"
        case .deleteAll: "삭제 후 재생성"
        }
    }
    var message: String {
        switch self {
        case .translation:
            "저장된 STT와 발화 타이밍은 유지하고 선택한 언어·모델의 번역만 삭제한 뒤 다시 생성합니다."
        case .deleteAll:
            "현재 영상의 기존 STT·번역 체크포인트와 사이드카 파일을 삭제한 뒤 처음부터 다시 생성합니다."
        }
    }
}

/// 하단 결과 패널 위의 드래그 핸들. 위아래로 끌어 패널 높이를 조절합니다.
private struct PanelResizeHandle: View {
    @Environment(ThemeManager.self) private var theme
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
        .background {
            if theme.translucent {
                VisualEffectView(material: .contentBackground)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
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
/// AVKit 기본 재생 컨트롤을 끈 영상 표면입니다.
/// 기본 컨트롤에도 음량 슬라이더가 있어 커스텀 컨트롤 바와 중복으로 보였습니다.
struct PlayerVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// 영상 위에 겹쳐 놓는 재생 컨트롤 바입니다. 재생·타임라인·음량을 하나로 모았습니다.
struct PlayerControlBar: View {
    @Binding var volume: Double
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onTogglePlayback: () -> Void
    let onSeek: (TimeInterval) -> Void

    @State private var volumeBeforeMute: Double?
    /// 드래그 중에는 재생 위치 갱신이 슬라이더를 되돌리지 않도록 로컬 값을 씁니다.
    @State private var scrubbingTime: TimeInterval?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTogglePlayback) {
                Label(isPlaying ? "일시 정지" : "재생", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isPlaying ? "일시 정지" : "재생")

            Text(timeText(scrubbingTime ?? currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { min(scrubbingTime ?? currentTime, max(duration, 0.1)) },
                    set: { scrubbingTime = $0 }
                ),
                in: 0...max(duration, 0.1),
                onEditingChanged: { editing in
                    guard !editing, let target = scrubbingTime else { return }
                    onSeek(target)
                    scrubbingTime = nil
                }
            )
            .frame(width: 190)
            .controlSize(.small)
            .disabled(duration <= 0)

            Text(timeText(duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            Divider().frame(height: 16)

            Button {
                toggleMute()
            } label: {
                Label(volume <= 0 ? "음량 켜기" : "음소거", systemImage: symbol)
                    .labelStyle(.iconOnly)
                    .frame(width: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(volume <= 0 ? "음량 켜기" : "음소거")

            Slider(value: $volume, in: 0...1)
                .frame(width: 92)
                .controlSize(.small)

            Text(volume, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("재생 컨트롤")
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private var symbol: String {
        switch volume {
        case ..<0.01: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    private func toggleMute() {
        if volume > 0 {
            volumeBeforeMute = volume
            volume = 0
        } else {
            volume = volumeBeforeMute ?? 0.5
        }
    }
}

/// 영상 위에 겹쳐 놓는 원형 아이콘 버튼입니다. 자막 관련 조작을 같은 모양으로 통일합니다.
private struct CaptionOverlayButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var accessibilityValue: LocalizedStringKey?
    let action: () -> Void

    init(
        title: LocalizedStringKey,
        systemImage: String,
        accessibilityValue: LocalizedStringKey? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessibilityValue = accessibilityValue
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .background(.regularMaterial, in: Circle())
        .help(title)
        .accessibilityValue(accessibilityValue.map { Text($0) } ?? Text(""))
    }
}

private struct PlayerCaption: View {
    let text: String
    var color: Color?
    var isSecondary: Bool
    var isItalic: Bool
    var opacity: Double

    init(
        text: String,
        color: Color? = nil,
        isSecondary: Bool = false,
        isItalic: Bool = false,
        opacity: Double = 1
    ) {
        self.text = text
        self.color = color
        self.isSecondary = isSecondary
        self.isItalic = isItalic
        self.opacity = opacity
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
            .font(captionFont)
            .multilineTextAlignment(.center)
            .lineLimit(isSecondary ? 2 : 3)
            .truncationMode(.tail)
            .shadow(color: .black.opacity(0.85), radius: 3)
            .padding(.horizontal, isSecondary ? 12 : 16)
            .padding(.vertical, isSecondary ? 6 : 8)
            .background(.black.opacity(isSecondary ? 0.32 : 0.42), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 24)
            .opacity(min(1, max(0.35, opacity)))
            .accessibilityLabel(text)
        }
    }

    private var captionFont: Font {
        let base: Font = isSecondary ? .callout.weight(.medium) : .title3.weight(.semibold)
        return isItalic ? base.italic() : base
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
    @State private var showRegenerateConfirmation = false

    @Environment(AppModel.self) private var model
    @Environment(ThemeManager.self) private var theme
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

    /// 모든 구간의 번역이 채워졌는지. 진행 상태가 아니라 실제 결과를 기준으로 판단합니다.
    private var resultsAreComplete: Bool {
        !model.transcript.isEmpty && model.untranslatedSegments.isEmpty
    }

    private var remainingSegmentCount: Int { model.untranslatedSegments.count }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("STT·번역 결과 확인")
                                .font(.headline)
                            if resultsAreComplete {
                                Label("완료", systemImage: "checkmark.seal.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                                    .labelStyle(.titleAndIcon)
                                    .help("모든 구간의 번역이 채워졌습니다")
                            } else if remainingSegmentCount > 0 {
                                Text("남은 구간 \(remainingSegmentCount)개")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text("STT \(model.transcript.count)개 · \(model.selectedLanguage.uppercased()) 번역 \(model.translations.count)개")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("삭제 후 다시 생성", systemImage: "trash") {
                        showRegenerateConfirmation = true
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!model.canRegenerate)
                    .help("저장된 STT·번역을 모두 지우고 처음부터 다시 만듭니다")
                    .confirmationDialog(
                        "저장된 STT·번역을 모두 지우고 다시 생성할까요?",
                        isPresented: $showRegenerateConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("삭제 후 다시 생성", role: .destructive) {
                            model.regenerateSTTAndTranslations()
                        }
                        Button("취소", role: .cancel) {}
                    } message: {
                        Text("이 영상의 저장된 결과가 삭제됩니다. 되돌릴 수 없습니다.")
                    }
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
                    .disabled(!model.canRegenerateSegment || pendingCount == 0)
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
                .scrollContentBackground(theme.translucent ? .hidden : .automatic)
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
            .background {
                if theme.translucent {
                    VisualEffectView(material: .contentBackground)
                        .ignoresSafeArea()
                } else {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
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
            .disabled(!model.canRegenerateSegment)
            Button {
                model.regenerateTranslation(for: segment)
            } label: {
                Image(systemName: "character.book.closed")
            }
            .buttonStyle(.borderless)
            .help("이 문장 번역 재생성")
            .disabled(!model.canRegenerateSegment)
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
            .disabled(!model.canRegenerateSegment)
            Button("이 문장 번역 재생성", systemImage: "character.book.closed") {
                model.regenerateTranslation(for: segment)
            }
            .disabled(!model.canRegenerateSegment)
        }
    }

    @ViewBuilder
    private func qualityBadge(_ title: String, status: SegmentQualityStatus) -> some View {
        let tint: Color = status == .warning ? .orange : (status == .good ? .green : .secondary)
        Label(title, systemImage: qualityIcon(status))
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
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
    @Environment(ThemeManager.self) private var theme
    @Environment(AppModel.self) private var model
    @AppStorage("subtitlePositionX") private var subtitlePositionX = 0.5
    @AppStorage("subtitlePositionY") private var subtitlePositionY = 0.86
    @AppStorage("subtitlePositionLocked") private var subtitlePositionLocked = false

    var body: some View {
        @Bindable var localization = localization
        @Bindable var theme = theme
        @Bindable var model = model
        Form {
            Section("테마") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("프리셋")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        ForEach(ThemePreset.allCases) { preset in
                            Button {
                                withAnimation(.smooth) { theme.apply(preset) }
                            } label: {
                                Label(preset.displayName, systemImage: preset.symbol)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                }
                Picker("외형", selection: $theme.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("강조 색", selection: $theme.accent) {
                    ForEach(AccentTheme.allCases) { accent in
                        HStack {
                            Circle()
                                .fill(accent.swatch)
                                .frame(width: 10, height: 10)
                            Text(accent.displayName)
                        }
                        .tag(accent)
                    }
                }
                Picker("밀도", selection: $theme.density) {
                    ForEach(InterfaceDensity.allCases) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                Toggle("반투명(글래스) 배경", isOn: $theme.translucent)
                Text("외형·강조 색·밀도·반투명을 바꾸면 앱 전체에 바로 반영됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            Section("화면 자막") {
                ColorPicker("자막 색상", selection: $theme.subtitleColor, supportsOpacity: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text("자막 불투명도 \(Int((theme.subtitleOpacity * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $theme.subtitleOpacity, in: 0.35...1)
                }
                Picker("음량 바 위치", selection: $theme.volumeBarPosition) {
                    ForEach(VolumeBarPosition.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("원문과 번역 자막 함께 보기", isOn: $model.showOriginalWithTranslation)
                Toggle("원문 자막 반투명", isOn: $model.originalSubtitleTranslucent)
                    .disabled(!model.showOriginalWithTranslation)
                Toggle("원문 자막 이탤릭체", isOn: $model.originalSubtitleItalic)
                    .disabled(!model.showOriginalWithTranslation)
                Toggle("자막 위치 고정", isOn: $subtitlePositionLocked)
                HStack {
                    Button("색상 초기화", systemImage: "paintbrush") {
                        theme.resetSubtitleColor()
                    }
                    Button("위치 초기화", systemImage: "arrow.counterclockwise") {
                        subtitlePositionX = 0.5
                        subtitlePositionY = 0.86
                    }
                }
                Text("이중 자막을 켜면 번역 아래에 원문 STT를 표시합니다. 잠금을 해제한 뒤 자막을 오른쪽 버튼으로 드래그해 옮길 수 있으며 왼쪽 클릭은 재생 조작에 사용됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("동작") {
                Toggle("앱 시작 시 무음", isOn: $model.startMuted)
                Toggle("마지막 영상 자동 복원", isOn: $model.autoloadLastVideoPreference)
                Toggle("이전 재생 위치 기억", isOn: $model.rememberPlaybackPosition)
                Picker("방향키 음량 조절 폭", selection: $model.volumeAdjustmentStep) {
                    Text("1% · 매우 미세").tag(0.01)
                    Text("2% · 미세").tag(0.02)
                    Text("5% · 보통").tag(0.05)
                    Text("10% · 크게").tag(0.10)
                }
                .help("위·아래 방향키를 한 번 누를 때 바뀌는 음량입니다")
                Text("음량 조절 폭은 즉시 적용됩니다. 시작·복원 설정은 앱을 재시작하면 반영됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("번역 품질 개선") {
                Toggle("완료 후 자동 품질 개선", isOn: $model.continuousImprovement)
                Picker("최대 개선 회차", selection: $model.maximumRefinementPasses) {
                    ForEach(1...5, id: \.self) { Text("\($0)회").tag($0) }
                }
                .disabled(!model.continuousImprovement)
                Toggle("완료 후 미번역 구간 자동 재시도", isOn: $model.autoRetryUntranslated)
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
    @State private var remotePool = RemoteWorkerPool.shared
    @State private var workerName = ""
    @State private var workerAddress = ""
    @State private var workerToken = ""
    @State private var workerMessage = ""
    @State private var defaultServerKey = ""
    @State private var keyMessage = ""
    @State private var workerUsesAuthentication = true
    @State private var workerToRemove: RemoteWorkerConfiguration?
    @State private var isAddingWorker = false
    @State private var confirmsClearingServerKey = false
    @FocusState private var workerAddressIsFocused: Bool

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
            Section("원격 서버 API 키") {
                SecureField("STTLMMServer 공통 API 키", text: $defaultServerKey)
                    .onSubmit { saveDefaultServerKey() }
                HStack {
                    Button("키 저장", systemImage: "key") { saveDefaultServerKey() }
                        .disabled(defaultServerKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("저장된 키 삭제", systemImage: "trash", role: .destructive) {
                        confirmsClearingServerKey = true
                    }
                    .disabled(!remotePool.hasDefaultAuthenticationToken)
                    Spacer()
                    Label(
                        remotePool.hasDefaultAuthenticationToken ? "Keychain에 저장됨" : "저장된 키 없음",
                        systemImage: remotePool.hasDefaultAuthenticationToken ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(remotePool.hasDefaultAuthenticationToken ? .green : .secondary)
                }
                if !keyMessage.isEmpty {
                    Text(keyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("키는 macOS Keychain에 안전하게 저장되며, 별도 키를 입력하지 않은 모든 원격 서버에 자동 적용됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("STTLMMServer 추가") {
                VStack(alignment: .leading, spacing: 12) {
                    Label("설치 없이 서버 연결", systemImage: "network")
                        .font(.callout.weight(.semibold))
                    Text("Windows·Linux·macOS에서 이미 실행 중인 STTLMMServer 주소만 입력하세요. VideoLingo Worker나 추가 프로그램을 설치할 필요가 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if remotePool.workers.isEmpty {
                    ContentUnavailableView(
                        "추가 서버 없음",
                        systemImage: "server.rack",
                        description: Text("실행 중인 STTLMMServer의 IP 주소나 도메인을 아래에 입력하세요.")
                    )
                } else {
                    ForEach(remotePool.workers) { worker in
                        HStack(spacing: 12) {
                            workerStatusIcon(remotePool.states[worker.id] ?? .unchecked)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(worker.name.isEmpty ? worker.baseURL.host() ?? "Worker" : worker.name)
                                    .font(.callout.weight(.semibold))
                                Text(worker.baseURL.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Label(worker.usesAuthentication ? "API 키 인증" : "키 없이 연결", systemImage: worker.usesAuthentication ? "key" : "key.slash")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                workerStatusText(remotePool.states[worker.id] ?? .unchecked)
                            }
                            Spacer()
                            Toggle("사용", isOn: Binding(
                                get: { worker.isEnabled },
                                set: { remotePool.setEnabled($0, for: worker.id) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            Button("상태 확인", systemImage: "arrow.clockwise") {
                                Task { await remotePool.refresh(worker.id) }
                            }
                            .labelStyle(.iconOnly)
                            .disabled(!worker.isEnabled || remotePool.states[worker.id] == .checking)
                            Button("서버 제거", systemImage: "trash", role: .destructive) {
                                workerToRemove = worker
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                    LabeledContent("사용 가능한 추가 용량") {
                        Text("STT \(remotePool.totalSTTSlots)개 · 번역 \(remotePool.totalTranslationSlots)개")
                            .monospacedDigit()
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("이름")
                        TextField("예: 작업실 STTLMM GPU", text: $workerName)
                    }
                    GridRow {
                        Text("서버 IP 또는 주소")
                        TextField("예: 192.168.0.20", text: $workerAddress)
                            .focused($workerAddressIsFocused)
                            .onSubmit { connectAndAddRemoteWorker() }
                    }
                    GridRow {
                        Text("인증")
                        Toggle("API 키 사용", isOn: $workerUsesAuthentication)
                    }
                    GridRow {
                        Text("개별 키 (선택)")
                        SecureField("공통 키와 다른 경우에만 입력", text: $workerToken)
                            .onSubmit { connectAndAddRemoteWorker() }
                            .disabled(!workerUsesAuthentication)
                    }
                }
                HStack {
                    Button("연결 후 추가", systemImage: "link.badge.plus") { connectAndAddRemoteWorker() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(workerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingWorker)
                    if isAddingWorker { ProgressView().controlSize(.small) }
                    Button("전체 상태 확인", systemImage: "arrow.clockwise") {
                        Task { await remotePool.refreshAll() }
                    }
                    .disabled(remotePool.workers.isEmpty || isAddingWorker)
                    Spacer()
                }
                if !workerMessage.isEmpty {
                    Text(workerMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("IP만 입력하면 http와 기본 포트 8848을 자동 적용합니다. API 키 사용을 끄면 인증 헤더 없이 연결하며, 켜면 개별 키 또는 위의 공통 키를 사용합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsMessageView()
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await remotePool.refreshAll()
            if remotePool.workers.isEmpty { workerAddressIsFocused = true }
        }
        .confirmationDialog(
            "이 추가 서버를 목록에서 제거할까요?",
            isPresented: Binding(get: { workerToRemove != nil }, set: { if !$0 { workerToRemove = nil } }),
            presenting: workerToRemove
        ) { worker in
            Button("‘\(worker.name)’ 제거", role: .destructive) {
                remotePool.remove(worker.id)
                workerToRemove = nil
            }
            Button("취소", role: .cancel) { workerToRemove = nil }
        } message: { _ in
            Text("원격 PC의 Worker와 저장된 결과는 삭제되지 않습니다.")
        }
        .confirmationDialog("Keychain에 저장된 원격 서버 키를 삭제할까요?", isPresented: $confirmsClearingServerKey) {
            Button("키 삭제", role: .destructive) { clearDefaultServerKey() }
            Button("취소", role: .cancel) { }
        } message: {
            Text("공통 키를 사용하는 서버는 다음 연결 확인 및 작업부터 인증에 실패할 수 있습니다.")
        }
    }

    private func saveDefaultServerKey() {
        do {
            try remotePool.saveDefaultAuthenticationToken(defaultServerKey)
            defaultServerKey = ""
            keyMessage = "원격 서버 공통 키를 Keychain에 저장했습니다."
        } catch {
            keyMessage = "키를 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func clearDefaultServerKey() {
        do {
            try remotePool.clearDefaultAuthenticationToken()
            defaultServerKey = ""
            keyMessage = "저장된 원격 서버 공통 키를 삭제했습니다."
        } catch {
            keyMessage = "키를 삭제하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func connectAndAddRemoteWorker() {
        guard !isAddingWorker, !workerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isAddingWorker = true
        workerMessage = "STTLMMServer 연결을 확인하는 중…"
        Task {
            defer { isAddingWorker = false }
            do {
                let status = try await remotePool.connectAndAdd(
                    name: workerName,
                    address: workerAddress,
                    token: workerToken,
                    usesAuthentication: workerUsesAuthentication
                )
                workerName = ""
                workerAddress = ""
                workerToken = ""
                workerUsesAuthentication = true
                workerMessage = "연결 및 추가 완료 · \(status.name) · STT \(status.capabilities.sttSlots)개 · 번역 \(status.capabilities.translationSlots)개"
            } catch {
                workerMessage = "추가하지 못했습니다: \(error.localizedDescription)"
                workerAddressIsFocused = true
            }
        }
    }

    @ViewBuilder
    private func workerStatusIcon(_ state: RemoteWorkerConnectionState) -> some View {
        switch state {
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .checking:
            ProgressView().controlSize(.small)
        case .unchecked:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func workerStatusText(_ state: RemoteWorkerConnectionState) -> some View {
        switch state {
        case .available(let status):
            Text("연결됨 · STT \(status.capabilities.sttSlots) · 번역 \(status.capabilities.translationSlots) · 실행 \(status.activeJobs)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        case .checking:
            Text("연결 확인 중…").font(.caption).foregroundStyle(.secondary)
        case .unchecked:
            Text("상태를 확인하지 않음").font(.caption).foregroundStyle(.secondary)
        case .unavailable(let message):
            Text("연결 실패 · \(message)").font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
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
                Text(kind == .translation ? translationModelName(modelID) : sttModelName(modelID))
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

private func sttModelName(_ modelID: String) -> String {
    switch modelID {
    case "large-v3-v20240930_626MB": String(localized: "Large v3 · 626MB (기본)")
    case "openai_whisper-large-v3-v20240930_turbo_632MB": String(localized: "Large v3 Turbo · 632MB (빠름)")
    case "openai_whisper-large-v3-v20240930_547MB": String(localized: "Large v3 · 547MB (가벼움)")
    case "openai_whisper-small_216MB": String(localized: "Small · 216MB (가장 가벼움)")
    default: modelID
    }
}

/// 외부 LLM 서버 접속 정보를 입력받습니다. API 키는 필요한 서버에서만 씁니다.
private struct ExternalServerFields: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            TextField("서버 주소", text: $model.externalServerEndpoint, prompt: Text("http://localhost:11434/v1"))
                .textFieldStyle(.roundedBorder)
            TextField("모델 이름", text: $model.externalServerModel, prompt: Text("qwen2.5:7b"))
                .textFieldStyle(.roundedBorder)
            TextField("API 키 (선택)", text: $model.externalServerAPIKey, prompt: Text("대부분의 로컬 서버는 비워 둡니다"))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("연결 테스트") {
                    Task { await model.testExternalServerConnection() }
                }
                .disabled(model.isTestingExternalServer)
                if model.isTestingExternalServer { ProgressView().controlSize(.small) }
            }
            if !model.externalServerTestMessage.isEmpty {
                Text(model.externalServerTestMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Ollama · LM Studio · llama.cpp · vLLM 등 OpenAI 호환 서버를 API 키 없이 연결합니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private func translationModelName(_ modelID: String) -> String {
    switch modelID {
    case "apple-foundation-models": String(localized: "Apple Foundation Models (시스템)")
    case "mlx-community/Qwen3-0.6B-4bit": "Qwen3 0.6B 4-bit"
    case "mlx-community/Qwen3-1.7B-4bit": "Qwen3 1.7B 4-bit"
    case "mlx-community/Qwen3-4B-4bit": String(localized: "Qwen3 4B 4-bit · 균형")
    case "mlx-community/Qwen3-8B-4bit": String(localized: "Qwen3 8B 4-bit · 고품질")
    case "mlx-community/gemma-3-1b-it-qat-4bit": "Gemma 3 1B QAT 4-bit"
    case ProcessingOptions.externalServerModelID: String(localized: "외부 LLM 서버 (OpenAI 호환)")
    default: modelID
    }
}
