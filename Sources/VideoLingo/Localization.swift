import Foundation
import Observation
import SwiftUI

/// 앱에서 지원하는 UI 언어입니다.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case korean
    case english

    var id: String { rawValue }

    /// UserDefaults에 저장되고 번들 로딩에 사용하는 언어 코드입니다. (system은 nil)
    var localeCode: String? {
        switch self {
        case .system: nil
        case .korean: "ko"
        case .english: "en"
        }
    }

    /// 설정 화면에 표시할 이름입니다. (해당 언어 자체 표기)
    var displayName: String {
        switch self {
        case .system: String(localized: "시스템 언어")
        case .korean: "한국어"
        case .english: "English"
        }
    }
}

/// 앱 전역 UI 언어를 관리합니다. 설정에서 선택한 언어로 런타임에 즉시 전환합니다.
@MainActor
@Observable
final class LocalizationManager {
    static let shared = LocalizationManager()

    var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
            Bundle.setPreferredLanguage(language.localeCode)
        }
    }

    private static let storageKey = "appLanguage"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        language = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
        Bundle.setPreferredLanguage(language.localeCode)
    }

    /// 날짜·숫자 서식과 SwiftUI 텍스트 조회에 사용할 로케일입니다.
    var locale: Locale {
        switch language {
        case .system: .autoupdatingCurrent
        case .korean: Locale(identifier: "ko")
        case .english: Locale(identifier: "en")
        }
    }
}

// MARK: - 런타임 번들 언어 교체

nonisolated(unsafe) private var preferredLanguageBundleKey: UInt8 = 0

/// 메인 번들의 문자열 조회를 가로채, 선택한 언어의 .lproj에서 문자열을 돌려주는 번들 하위 클래스입니다.
private final class PreferredLanguageBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let bundle = objc_getAssociatedObject(self, &preferredLanguageBundleKey) as? Bundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {
    /// 메인 번들을 지정한 언어(.lproj)로 고정합니다. code가 nil이면 시스템 기본 동작으로 되돌립니다.
    static func setPreferredLanguage(_ code: String?) {
        object_setClass(Bundle.main, PreferredLanguageBundle.self)
        let bundle = code
            .flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .flatMap { Bundle(path: $0) }
        objc_setAssociatedObject(Bundle.main, &preferredLanguageBundleKey, bundle, .OBJC_ASSOCIATION_RETAIN)
    }
}
