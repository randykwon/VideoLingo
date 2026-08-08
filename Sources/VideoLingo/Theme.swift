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

    private init() {
        appearance = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "themeAppearance") ?? "") ?? .system
        accent = AccentTheme(rawValue: UserDefaults.standard.string(forKey: "themeAccent") ?? "") ?? .system
        density = InterfaceDensity(rawValue: UserDefaults.standard.string(forKey: "themeDensity") ?? "") ?? .comfortable
    }

    var colorScheme: ColorScheme? { appearance.colorScheme }
    var accentColor: Color? { accent.color }
    var controlSize: ControlSize { density.controlSize }
}
