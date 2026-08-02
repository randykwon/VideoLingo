import SwiftUI

@main
struct VideoLingoApp: App {
    @State private var model = AppModel()
    @State private var shortcuts = ShortcutSettings()
    @AppStorage("simpleMode") private var isSimpleMode = false
    @AppStorage("miniViewer") private var isMiniViewer = false
    @AppStorage("hideTranscriptPanel") private var hideTranscriptPanel = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(shortcuts)
                .frame(minWidth: isMiniViewer ? 360 : 1_050, minHeight: isMiniViewer ? 240 : 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("영상 열기…") { model.openVideo() }
                    .keyboardShortcut(shortcuts[.openVideo].keyEquivalent, modifiers: shortcuts[.openVideo].modifiers)
            }
            CommandMenu("재생 제어") {
                Button("재생/일시 정지") { model.togglePlayback() }
                    .keyboardShortcut(shortcuts[.playPause].keyEquivalent, modifiers: shortcuts[.playPause].modifiers)
                    .disabled(model.mediaURL == nil)
                Button("10초 뒤로") { model.seekVideo(by: -10) }
                    .keyboardShortcut(shortcuts[.seekBackward].keyEquivalent, modifiers: shortcuts[.seekBackward].modifiers)
                    .disabled(model.mediaURL == nil)
                Button("10초 앞으로") { model.seekVideo(by: 10) }
                    .keyboardShortcut(shortcuts[.seekForward].keyEquivalent, modifiers: shortcuts[.seekForward].modifiers)
                    .disabled(model.mediaURL == nil)
                Divider()
                Button("음량 크게") { model.adjustVolume(by: 0.1) }
                    .keyboardShortcut(shortcuts[.volumeUp].keyEquivalent, modifiers: shortcuts[.volumeUp].modifiers)
                    .disabled(model.mediaURL == nil)
                Button("음량 작게") { model.adjustVolume(by: -0.1) }
                    .keyboardShortcut(shortcuts[.volumeDown].keyEquivalent, modifiers: shortcuts[.volumeDown].modifiers)
                    .disabled(model.mediaURL == nil)
            }
            CommandMenu("보기") {
                Button("심플 모드 전환") { isSimpleMode.toggle() }
                    .keyboardShortcut(shortcuts[.toggleSimpleMode].keyEquivalent, modifiers: shortcuts[.toggleSimpleMode].modifiers)
                Button("미니 뷰어 전환") { isMiniViewer.toggle() }
                    .keyboardShortcut(shortcuts[.toggleMiniViewer].keyEquivalent, modifiers: shortcuts[.toggleMiniViewer].modifiers)
                Button("아래 결과 패널 전환") { hideTranscriptPanel.toggle() }
                    .keyboardShortcut(shortcuts[.toggleBottomPanel].keyEquivalent, modifiers: shortcuts[.toggleBottomPanel].modifiers)
                Divider()
                Button(model.translucentMode ? "반투명 모드 해제" : "반투명 모드 사용") {
                    model.toggleTranslucentMode()
                }
                .keyboardShortcut(shortcuts[.toggleTranslucency].keyEquivalent, modifiers: shortcuts[.toggleTranslucency].modifiers)
                Button("앱 숨기기") { model.hideApplication() }
                    .keyboardShortcut(shortcuts[.hideApp].keyEquivalent, modifiers: shortcuts[.hideApp].modifiers)
            }
            CommandMenu("STT·번역") {
                Button("시작/재개") { model.startOrResume() }
                    .keyboardShortcut(shortcuts[.startOrResume].keyEquivalent, modifiers: shortcuts[.startOrResume].modifiers)
                    .disabled(!model.canStart)
                Button("결과 새로 고침") { model.refreshResults() }
                    .keyboardShortcut(shortcuts[.refreshResults].keyEquivalent, modifiers: shortcuts[.refreshResults].modifiers)
                Button("SRT 내보내기") { model.exportSRT() }
                    .keyboardShortcut(shortcuts[.exportSRT].keyEquivalent, modifiers: shortcuts[.exportSRT].modifiers)
                Button("결과 폴더 열기") { model.revealOutput() }
                    .keyboardShortcut(shortcuts[.revealOutput].keyEquivalent, modifiers: shortcuts[.revealOutput].modifiers)
                Divider()
                Button("현재 작업 취소") { model.cancel() }
                    .keyboardShortcut(shortcuts[.cancelJob].keyEquivalent, modifiers: shortcuts[.cancelJob].modifiers)
            }
        }
        Settings {
            SettingsView()
                .environment(model)
                .environment(shortcuts)
        }
    }
}
