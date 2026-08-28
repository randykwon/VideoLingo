import AppKit
import Observation
import SwiftUI

/// 앱 외형(라이트/다크/시스템)
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var displayName: String {
        switch self {
        case .system: String(localized: "시스템")
        case .light: String(localized: "라이트")
        case .dark: String(localized: "다크")
        }
    }
}

/// 앱 강조 색. .system은 사용자의 macOS 강조 색을 그대로 씁니다.
enum AccentTheme: String, CaseIterable, Identifiable, Sendable {
    case system, blue, purple, pink, red, orange, green, teal, graphite
    var id: String { rawValue }

    var color: Color? {
        switch self {
        case .system: nil
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        case .graphite: .gray
        }
    }

    /// 설정 화면 미리보기용 스와치 색(시스템은 accentColor로 표시)
    var swatch: Color { color ?? .accentColor }

    var displayName: String {
        switch self {
        case .system: String(localized: "시스템 기본")
        case .blue: String(localized: "파랑")
        case .purple: String(localized: "보라")
        case .pink: String(localized: "분홍")
        case .red: String(localized: "빨강")
        case .orange: String(localized: "주황")
        case .green: String(localized: "초록")
        case .teal: String(localized: "청록")
        case .graphite: String(localized: "그래파이트")
        }
    }
}

/// 컨트롤 밀도(여백감)
enum InterfaceDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable, compact
    var id: String { rawValue }

    var controlSize: ControlSize {
        switch self {
        case .comfortable: .regular
        case .compact: .small
        }
    }

    var displayName: String {
        switch self {
        case .comfortable: String(localized: "보통")
        case .compact: String(localized: "컴팩트")
        }
    }
}

/// 앱 전역 UI 스타일(외형·강조색·밀도)을 관리합니다. 설정에서 바꾸면 즉시 반영됩니다.
@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "themeAppearance") }
    }
    var accent: AccentTheme {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "themeAccent") }
    }
    var density: InterfaceDensity {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "themeDensity") }
    }
    /// 왼쪽 사이드바와 하단 결과 패널을 vibrancy 머티리얼로 만들어 뒤 배경이 은은히 비치게 합니다.
    var translucent: Bool {
        didSet { UserDefaults.standard.set(translucent, forKey: "themeTranslucent") }
    }
    /// 영상 위에 표시하는 재생 자막 색상입니다. sRGB 성분으로 저장해 앱 전체 창에 즉시 공유합니다.
    var subtitleColor: Color {
        didSet { Self.saveSubtitleColor(subtitleColor) }
    }

    /// 영상 위 자막의 불투명도입니다. 반투명하게 두면 자막이 화면을 덜 가립니다.
    var subtitleOpacity: Double {
        didSet { UserDefaults.standard.set(subtitleOpacity, forKey: "subtitleOpacity") }
    }

    /// 반투명 상태인지 여부와 한 번에 전환하는 헬퍼입니다.
    var subtitleTranslucent: Bool { subtitleOpacity < 0.99 }

    func toggleSubtitleTranslucency() {
        subtitleOpacity = subtitleTranslucent ? 1 : 0.6
    }

    private init() {
        appearance = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "themeAppearance") ?? "") ?? .system
        accent = AccentTheme(rawValue: UserDefaults.standard.string(forKey: "themeAccent") ?? "") ?? .system
        density = InterfaceDensity(rawValue: UserDefaults.standard.string(forKey: "themeDensity") ?? "") ?? .comfortable
        translucent = UserDefaults.standard.bool(forKey: "themeTranslucent")
        subtitleColor = Self.loadSubtitleColor()
        subtitleOpacity = (UserDefaults.standard.object(forKey: "subtitleOpacity") as? Double)
            .map { min(1, max(0.35, $0)) } ?? 1
    }

    var colorScheme: ColorScheme? { appearance.colorScheme }
    var accentColor: Color? { accent.color }
    var controlSize: ControlSize { density.controlSize }

    func apply(_ preset: ThemePreset) {
        appearance = preset.appearance
        accent = preset.accent
        density = preset.density
        translucent = preset.translucent
    }

    func resetSubtitleColor() {
        subtitleColor = .white
    }

    private static func loadSubtitleColor() -> Color {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "subtitleColorRed") != nil else { return .white }
        return Color(
            red: defaults.double(forKey: "subtitleColorRed"),
            green: defaults.double(forKey: "subtitleColorGreen"),
            blue: defaults.double(forKey: "subtitleColorBlue"),
            opacity: defaults.object(forKey: "subtitleColorAlpha") == nil ? 1 : defaults.double(forKey: "subtitleColorAlpha")
        )
    }

    private static func saveSubtitleColor(_ color: Color) {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
        let defaults = UserDefaults.standard
        defaults.set(converted.redComponent, forKey: "subtitleColorRed")
        defaults.set(converted.greenComponent, forKey: "subtitleColorGreen")
        defaults.set(converted.blueComponent, forKey: "subtitleColorBlue")
        defaults.set(converted.alphaComponent, forKey: "subtitleColorAlpha")
    }
}

/// 외형·강조색·밀도·반투명을 한 번에 적용하는 명명된 프리셋.
enum ThemePreset: String, CaseIterable, Identifiable, Sendable {
    case standard, minimal, vivid, darkFocus, glass
    var id: String { rawValue }

    var appearance: AppearanceMode {
        switch self {
        case .standard, .vivid, .glass: .system
        case .minimal: .light
        case .darkFocus: .dark
        }
    }
    var accent: AccentTheme {
        switch self {
        case .standard, .glass: .system
        case .minimal: .graphite
        case .vivid: .purple
        case .darkFocus: .blue
        }
    }
    var density: InterfaceDensity {
        self == .minimal ? .compact : .comfortable
    }
    var translucent: Bool { self == .glass }

    var displayName: String {
        switch self {
        case .standard: String(localized: "기본")
        case .minimal: String(localized: "미니멀")
        case .vivid: String(localized: "선명")
        case .darkFocus: String(localized: "다크 포커스")
        case .glass: String(localized: "글래스")
        }
    }

    var symbol: String {
        switch self {
        case .standard: "circle.lefthalf.filled"
        case .minimal: "square"
        case .vivid: "paintpalette"
        case .darkFocus: "moon.stars"
        case .glass: "square.on.square.dashed"
        }
    }
}

/// NSVisualEffectView를 SwiftUI 배경으로 사용해 뒤 배경이 비치는 vibrancy를 줍니다.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.state = .active
    }
}
