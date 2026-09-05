import SwiftUI

/// 포커스된 창(플레이어)의 AppModel을 전역 메뉴 명령에 전달하기 위한 키입니다.
struct AppModelFocusedValueKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedValueKey.self] }
        set { self[AppModelFocusedValueKey.self] = newValue }
    }
}

@main
struct VideoLingoApp: App {
    @State private var shortcuts = ShortcutSettings()
    @State private var localization = LocalizationManager.shared
    @State private var theme = ThemeManager.shared
    @State private var batchProcessor = BatchProcessor.shared
    // 설정 창은 영상 플레이어가 필요 없으므로 마지막 영상은 복원하지 않는 전용 모델을 사용합니다.
    @State private var settingsModel = AppModel(autoloadLastVideo: false)

    var body: some Scene {
        WindowGroup(id: "player") {
            PlayerWindow()
                .environment(shortcuts)
                .environment(localization)
                .environment(theme)
                .tint(theme.accentColor)
                .controlSize(theme.controlSize)
                .preferredColorScheme(theme.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            VideoLingoCommands(shortcuts: shortcuts, batchProcessor: batchProcessor)
        }
        Window("대량 번역", id: "batch") {
            BatchTranslationView()
                .environment(batchProcessor)
                .environment(localization)
                .environment(theme)
                .environment(\.locale, localization.locale)
                .tint(theme.accentColor)
                .controlSize(theme.controlSize)
                .preferredColorScheme(theme.colorScheme)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 920, height: 680)
        Window("STT·번역 멀티 화면", id: "batch-monitor") {
            BatchMultiMonitorView()
                .environment(batchProcessor)
                .environment(localization)
                .environment(theme)
                .environment(\.locale, localization.locale)
                .tint(theme.accentColor)
                .controlSize(theme.controlSize)
                .preferredColorScheme(theme.colorScheme)
        }
        .defaultSize(width: 1_280, height: 820)
        WindowGroup("번역 상세 진행", id: "batch-detail", for: UUID.self) { $itemID in
            BatchTranslationDetailView(itemID: itemID)
                .environment(batchProcessor)
                .environment(localization)
                .environment(theme)
                .environment(\.locale, localization.locale)
                .tint(theme.accentColor)
                .controlSize(theme.controlSize)
                .preferredColorScheme(theme.colorScheme)
        }
        .defaultSize(width: 820, height: 680)
        WindowGroup("큰 미리보기", id: "batch-monitor-preview", for: UUID.self) { $itemID in
            BatchMonitorExpandedPreviewView(itemID: itemID)
                .environment(batchProcessor)
                .environment(localization)
                .environment(theme)
                .environment(\.locale, localization.locale)
                .tint(theme.accentColor)
                .controlSize(theme.controlSize)
                .preferredColorScheme(theme.colorScheme)
        }
        .defaultSize(width: 1_100, height: 780)
        WindowGroup("번역 결과 검토", id: "batch-preview", for: UUID.self) { $itemID in
            BatchCompletedPreviewView(itemID: itemID)
                .environment(batchProcessor)
                .environment(localization)
                .environment(theme)
                .environment(\.locale, localization.locale)
                .tint(theme.accentColor)
                .preferredColorScheme(theme.colorScheme)
        }
        .defaultSize(width: 1_100, height: 720)
        Settings {
            SettingsView()
                .environment(settingsModel)
                .environment(shortcuts)
                .environment(localization)
                .environment(theme)
                .environment(\.locale, localization.locale)
                .id(localization.language)
                .tint(theme.accentColor)
                .controlSize(theme.controlSize)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}

/// 각 창마다 독립적인 AppModel(자체 AVPlayer·자체 작업)을 소유해 여러 플레이어를 동시에 실행합니다.
private struct PlayerWindow: View {
    @Environment(LocalizationManager.self) private var localization
    // 첫 창만(그리고 '마지막 영상 자동 복원' 설정이 켜졌을 때만) 마지막 영상을 복원합니다.
    @State private var model = AppModel(
        autoloadLastVideo: !AppModel.hasAutoloadedInitialVideo
            && (UserDefaults.standard.object(forKey: "autoloadLastVideo") as? Bool ?? true)
    )

    var body: some View {
        ContentView()
            .environment(model)
            .frame(
                minWidth: model.isMiniViewer ? 360 : model.playerMode == .viewing ? 820 : 1_050,
                minHeight: model.isMiniViewer ? 240 : model.playerMode == .viewing ? 560 : 680
            )
            // 언어 변경 시 문구만 새로 그리고, 창의 모델(플레이어·작업)은 그대로 유지합니다.
            .environment(\.locale, localization.locale)
            .id(localization.language)
            .focusedSceneValue(\.appModel, model)
    }
}

/// 전역 메뉴 명령. 포커스된 플레이어 창의 AppModel을 대상으로 동작합니다.
private struct VideoLingoCommands: Commands {
    let shortcuts: ShortcutSettings
    let batchProcessor: BatchProcessor
    @FocusedValue(\.appModel) private var model: AppModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 창") { openWindow(id: "player") }
                .keyboardShortcut("n", modifiers: .command)
            Button("영상 열기…") { model?.openVideo() }
                .keyboardShortcut(shortcuts[.openVideo].keyEquivalent, modifiers: shortcuts[.openVideo].modifiers)
                .disabled(model == nil)
            Button("대량 번역…") {
                if let model { batchProcessor.configure(options: model.currentProcessingOptions()) }
                openWindow(id: "batch")
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
        }
        CommandMenu("재생 제어") {
            Button("재생/일시 정지") { model?.togglePlayback() }
                .keyboardShortcut(shortcuts[.playPause].keyEquivalent, modifiers: shortcuts[.playPause].modifiers)
                .disabled(model?.mediaURL == nil)
            Button("10초 뒤로") { model?.seekVideo(by: -10) }
                .keyboardShortcut(shortcuts[.seekBackward].keyEquivalent, modifiers: shortcuts[.seekBackward].modifiers)
                .disabled(model?.mediaURL == nil)
            Button("10초 앞으로") { model?.seekVideo(by: 10) }
                .keyboardShortcut(shortcuts[.seekForward].keyEquivalent, modifiers: shortcuts[.seekForward].modifiers)
                .disabled(model?.mediaURL == nil)
            Divider()
            Button("음량 크게 (\(volumeStepPercent)%)") {
                guard let model else { return }
                model.adjustVolume(by: model.volumeAdjustmentStep)
            }
                .keyboardShortcut(shortcuts[.volumeUp].keyEquivalent, modifiers: shortcuts[.volumeUp].modifiers)
                .disabled(model?.mediaURL == nil)
            Button("음량 작게 (\(volumeStepPercent)%)") {
                guard let model else { return }
                model.adjustVolume(by: -model.volumeAdjustmentStep)
            }
                .keyboardShortcut(shortcuts[.volumeDown].keyEquivalent, modifiers: shortcuts[.volumeDown].modifiers)
                .disabled(model?.mediaURL == nil)
        }
        CommandMenu("플레이어 모드") {
            Button {
                model?.playerMode = .viewing
            } label: {
                Label("영상 감상 모드", systemImage: model?.playerMode == .viewing ? "checkmark" : "play.rectangle")
            }
            .disabled(model == nil)
            Button {
                model?.playerMode = .translation
            } label: {
                Label("번역 모드", systemImage: model?.playerMode == .translation ? "checkmark" : "character.book.closed")
            }
            .disabled(model == nil)
        }
        CommandMenu("보기") {
            Button("전체화면 전환") { model?.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(model == nil)
            Divider()
            Button(model?.isSimpleMode == true ? "전체 보기" : "심플 보기") { model?.isSimpleMode.toggle() }
                .keyboardShortcut(shortcuts[.toggleSimpleMode].keyEquivalent, modifiers: shortcuts[.toggleSimpleMode].modifiers)
                .disabled(model == nil)
            Button(model?.isMiniViewer == true ? "미니 뷰어 종료" : "미니 뷰어") { model?.isMiniViewer.toggle() }
                .keyboardShortcut(shortcuts[.toggleMiniViewer].keyEquivalent, modifiers: shortcuts[.toggleMiniViewer].modifiers)
                .disabled(model == nil)
            Button(model?.hideTranscriptPanel == true ? "결과 패널 표시" : "결과 패널 감추기") { model?.hideTranscriptPanel.toggle() }
                .keyboardShortcut(shortcuts[.toggleBottomPanel].keyEquivalent, modifiers: shortcuts[.toggleBottomPanel].modifiers)
                .disabled(model == nil)
            Divider()
            Button("투명도 조절 (\(Int(((model?.windowOpacity ?? 1) * 100).rounded()))%)") {
                model?.cycleTranslucency()
            }
            .keyboardShortcut(shortcuts[.toggleTranslucency].keyEquivalent, modifiers: shortcuts[.toggleTranslucency].modifiers)
            .disabled(model == nil)
            Button("앱 숨기기") { NSApplication.shared.hide(nil) }
                .keyboardShortcut(shortcuts[.hideApp].keyEquivalent, modifiers: shortcuts[.hideApp].modifiers)
            // 소리부터 끄고 창을 숨겨야 숨긴 뒤에 소리가 새지 않습니다.
            Button("앱 숨기고 음소거") {
                AppModel.muteAllWindows()
                NSApplication.shared.hide(nil)
            }
            .keyboardShortcut(shortcuts[.hideAndMute].keyEquivalent, modifiers: shortcuts[.hideAndMute].modifiers)
        }
        CommandMenu("STT·번역") {
            Button("대량 번역…") {
                if let model { batchProcessor.configure(options: model.currentProcessingOptions()) }
                openWindow(id: "batch")
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            Menu("대량 번역 결과 저장 위치") {
                Button(
                    batchProcessor.alternateResultDirectoryURL == nil ? "폴더 지정…" : "저장 폴더 변경…",
                    systemImage: "folder.badge.plus"
                ) {
                    batchProcessor.chooseAlternateResultDirectory()
                }
                .disabled(batchProcessor.isRunning)

                if let path = batchProcessor.alternateResultDirectoryDisplayPath {
                    Button("Finder에서 열기", systemImage: "folder") {
                        batchProcessor.revealAlternateResultDirectory()
                    }
                    Divider()
                    Button(path) {}
                        .disabled(true)
                    Button("지정 해제", systemImage: "xmark.circle") {
                        batchProcessor.clearAlternateResultDirectory()
                    }
                    .disabled(batchProcessor.isRunning)
                } else {
                    Button("지정된 폴더 없음") {}
                        .disabled(true)
                }
            }
            Divider()
            Button("시작/재개") { model?.startOrResume() }
                .keyboardShortcut(shortcuts[.startOrResume].keyEquivalent, modifiers: shortcuts[.startOrResume].modifiers)
                .disabled(!(model?.canStart ?? false))
            Button("결과 새로 고침") { model?.refreshResults() }
                .keyboardShortcut(shortcuts[.refreshResults].keyEquivalent, modifiers: shortcuts[.refreshResults].modifiers)
                .disabled(model == nil)
            Button("SRT 내보내기") { model?.exportSRT() }
                .keyboardShortcut(shortcuts[.exportSRT].keyEquivalent, modifiers: shortcuts[.exportSRT].modifiers)
                .disabled(model == nil)
            Button("iPhone·iPad로 공유") { model?.exportMobilePackage() }
                .disabled(model?.transcript.isEmpty ?? true)
            Button("결과 폴더 열기") { model?.revealOutput() }
                .keyboardShortcut(shortcuts[.revealOutput].keyEquivalent, modifiers: shortcuts[.revealOutput].modifiers)
                .disabled(model == nil)
            Divider()
            Button("현재 작업 취소") { model?.cancel() }
                .keyboardShortcut(shortcuts[.cancelJob].keyEquivalent, modifiers: shortcuts[.cancelJob].modifiers)
                .disabled(model == nil)
        }
    }

    private var volumeStepPercent: Int {
        Int(((model?.volumeAdjustmentStep ?? 0.10) * 100).rounded())
    }
}
