import AppKit
import Observation
import SwiftUI

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case openVideo, playPause, seekBackward, seekForward, volumeUp, volumeDown
    case toggleSimpleMode, toggleMiniViewer, toggleBottomPanel, toggleTranslucency, hideApp
    case startOrResume, refreshResults, exportSRT, revealOutput, cancelJob

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openVideo: "영상 열기"
        case .playPause: "재생/일시 정지"
        case .seekBackward: "10초 뒤로"
        case .seekForward: "10초 앞으로"
        case .volumeUp: "음량 크게"
        case .volumeDown: "음량 작게"
        case .toggleSimpleMode: "심플 모드 전환"
        case .toggleMiniViewer: "미니 뷰어 전환"
        case .toggleBottomPanel: "아래 결과 패널 전환"
        case .toggleTranslucency: "앱 반투명 모드 전환"
        case .hideApp: "앱 숨기기"
        case .startOrResume: "STT·번역 시작/재개"
        case .refreshResults: "결과 새로 고침"
        case .exportSRT: "SRT 내보내기"
        case .revealOutput: "결과 폴더 열기"
        case .cancelJob: "현재 작업 취소"
        }
    }

    var category: String {
        switch self {
        case .openVideo, .toggleSimpleMode, .toggleMiniViewer, .toggleBottomPanel, .toggleTranslucency, .hideApp: "앱·화면"
        case .playPause, .seekBackward, .seekForward, .volumeUp, .volumeDown: "재생"
        default: "STT·번역"
        }
    }
}

struct ShortcutDefinition: Codable, Hashable {
    let key: String
    let modifiersRawValue: Int

    init(_ key: String, _ modifiers: EventModifiers = []) {
        self.key = key
        modifiersRawValue = modifiers.rawValue
    }

    var modifiers: EventModifiers { EventModifiers(rawValue: modifiersRawValue) }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "left": .leftArrow
        case "right": .rightArrow
        case "up": .upArrow
        case "down": .downArrow
        case "space": .space
        case "return": .return
        case "tab": .tab
        default: KeyEquivalent(key.first ?? "?")
        }
    }

    var displayText: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let keyText = switch key {
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        case "space": "Space"
        case "return": "↩"
        case "tab": "⇥"
        default: key.uppercased()
        }
        text += keyText
        return text
    }

    static func from(event: NSEvent) -> ShortcutDefinition? {
        let key: String
        switch event.keyCode {
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        case 49: key = "space"
        case 36: key = "return"
        case 48: key = "tab"
        default:
            guard let value = event.charactersIgnoringModifiers?.lowercased(),
                  value.count == 1,
                  value.unicodeScalars.first.map({ !CharacterSet.controlCharacters.contains($0) }) == true else { return nil }
            key = value
        }
        var modifiers: EventModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        return ShortcutDefinition(key, modifiers)
    }
}

@MainActor
@Observable
final class ShortcutSettings {
    private static let storageKey = "VideoLingo.keyboardShortcuts.v1"
    private(set) var values: [ShortcutAction: ShortcutDefinition]
    var message = ""

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ShortcutAction: ShortcutDefinition].self, from: data) {
            values = Self.defaults.merging(decoded) { _, saved in saved }
        } else {
            values = Self.defaults
        }
    }

    subscript(action: ShortcutAction) -> ShortcutDefinition {
        values[action] ?? Self.defaults[action]!
    }

    func assign(_ shortcut: ShortcutDefinition, to action: ShortcutAction) {
        if let conflict = values.first(where: { $0.key != action && $0.value == shortcut })?.key {
            let format = NSLocalizedString("%@은(는) ‘%@’에서 사용 중입니다.", comment: "")
            message = String(format: format, shortcut.displayText, NSLocalizedString(conflict.title, comment: ""))
            return
        }
        values[action] = shortcut
        let format = NSLocalizedString("‘%@’ 단축키를 %@으로 저장했습니다.", comment: "")
        message = String(format: format, NSLocalizedString(action.title, comment: ""), shortcut.displayText)
        save()
    }

    func reset() {
        values = Self.defaults
        message = NSLocalizedString("모든 단축키를 기본값으로 복원했습니다.", comment: "")
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static let defaults: [ShortcutAction: ShortcutDefinition] = [
        .openVideo: ShortcutDefinition("o", .command),
        .playPause: ShortcutDefinition("space"),
        .seekBackward: ShortcutDefinition("left"),
        .seekForward: ShortcutDefinition("right"),
        .volumeUp: ShortcutDefinition("up"),
        .volumeDown: ShortcutDefinition("down"),
        .toggleSimpleMode: ShortcutDefinition("s", [.command, .shift]),
        .toggleMiniViewer: ShortcutDefinition("m", [.command, .shift]),
        .toggleBottomPanel: ShortcutDefinition("b", [.command, .shift]),
        .toggleTranslucency: ShortcutDefinition("t", [.command, .shift]),
        .hideApp: ShortcutDefinition("q", .shift),
        .startOrResume: ShortcutDefinition("return", .command),
        .refreshResults: ShortcutDefinition("r", [.command, .shift]),
        .exportSRT: ShortcutDefinition("e", .command),
        .revealOutput: ShortcutDefinition("o", [.command, .shift]),
        .cancelJob: ShortcutDefinition(".", .command)
    ]
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: ShortcutDefinition
    let onChange: (ShortcutDefinition) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> RecorderControl {
        let control = RecorderControl()
        control.onShortcut = context.coordinator.onChange
        control.shortcut = shortcut
        return control
    }

    func updateNSView(_ control: RecorderControl, context: Context) {
        context.coordinator.onChange = onChange
        control.onShortcut = context.coordinator.onChange
        control.shortcut = shortcut
    }

    @MainActor
    final class Coordinator {
        var onChange: (ShortcutDefinition) -> Void
        init(onChange: @escaping (ShortcutDefinition) -> Void) { self.onChange = onChange }
    }
}

final class RecorderControl: NSView {
    var shortcut = ShortcutDefinition("?") { didSet { needsDisplay = true } }
    var onShortcut: ((ShortcutDefinition) -> Void)?
    private var recording = false
    private var keyMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 118, height: 28) }

    override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.recording else { return event }
                self.accept(event)
                return nil
            }
        }
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        removeKeyMonitor()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        accept(event)
    }

    private func accept(_ event: NSEvent) {
        guard recording, let value = ShortcutDefinition.from(event: event) else { NSSound.beep(); return }
        recording = false
        removeKeyMonitor()
        onShortcut?(value)
        window?.makeFirstResponder(nil)
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
        let value = recording ? NSLocalizedString("새 단축키 입력…", comment: "") : shortcut.displayText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = value.size(withAttributes: attributes)
        value.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

struct WindowModeAccessor: NSViewRepresentable {
    let mini: Bool
    let opacity: Double

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.apply(mini: mini, to: window)
            context.coordinator.apply(opacity: opacity, to: window)
        }
    }

    @MainActor
    final class Coordinator {
        private var normalFrame: NSRect?
        private var appliedMini: Bool?
        private var appliedOpacity: Double?

        func apply(mini: Bool, to window: NSWindow) {
            guard appliedMini != mini else { return }
            appliedMini = mini
            if mini {
                normalFrame = window.frame
                window.level = .floating
                window.collectionBehavior.insert(.fullScreenAuxiliary)
                window.minSize = NSSize(width: 360, height: 240)
                var frame = window.frame
                frame.origin.y = frame.maxY - 360
                frame.size = NSSize(width: 520, height: 360)
                window.setFrame(frame, display: true, animate: true)
            } else {
                window.level = .normal
                window.collectionBehavior.remove(.fullScreenAuxiliary)
                window.minSize = NSSize(width: 1_050, height: 680)
                if let normalFrame { window.setFrame(normalFrame, display: true, animate: true) }
            }
        }

        func apply(opacity: Double, to window: NSWindow) {
            guard appliedOpacity != opacity else { return }
            appliedOpacity = opacity
            window.animator().alphaValue = CGFloat(opacity)
        }
    }
}
