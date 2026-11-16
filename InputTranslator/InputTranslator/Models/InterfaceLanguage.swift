import Foundation

nonisolated enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case brazilianPortuguese = "pt-BR"
    case arabic = "ar"

    static let defaultChoice: Self = .system

    var id: Self { self }

    var title: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .french: "Français"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .brazilianPortuguese: "Português (Brasil)"
        case .arabic: "العربية"
        }
    }

    var resolved: Self {
        guard self == .system else { return self }
        let supported = [Self.english] + Self.allCases.filter { $0 != .system && $0 != .english }
        let preferred = Bundle.preferredLocalizations(
            from: supported.map(\.rawValue), forPreferences: Locale.preferredLanguages
        ).first
        return preferred.flatMap(Self.init(rawValue:)) ?? .english
    }
}

nonisolated enum L10n {
    static let preferenceKey = "interfaceLanguage"

    static var language: InterfaceLanguage {
        let choice = UserDefaults.standard.string(forKey: preferenceKey).flatMap(InterfaceLanguage.init(rawValue:))
        return (choice ?? .defaultChoice).resolved
    }

    static var locale: Locale { Locale(identifier: language.rawValue) }

    private static let bundles: [InterfaceLanguage: Bundle] = Dictionary(
        uniqueKeysWithValues: InterfaceLanguage.allCases.compactMap { language in
            guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (language, bundle)
        }
    )

    static func text(_ key: String, _ arguments: String...) -> String {
        render(key, arguments: arguments)
    }

    static func render(_ key: String, arguments: [String]) -> String {
        let selected = language
        let fallback = bundles[.english]?.localizedString(forKey: key, value: key, table: "Interface") ?? key
        let value = bundles[selected]?.localizedString(forKey: key, value: fallback, table: "Interface")
            ?? (selected == .simplifiedChinese ? key : fallback)
        guard !arguments.isEmpty else { return value }
        return String(format: value, locale: Locale(identifier: selected.rawValue), arguments: arguments)
    }
}

struct LocalizedMessage {
    let key: String
    private let arguments: () -> [String]

    init(_ key: String, _ arguments: String...) {
        self.key = key
        self.arguments = { arguments }
    }

    init(_ key: String, arguments: @escaping () -> [String]) {
        self.key = key
        self.arguments = arguments
    }

    var text: String { L10n.render(key, arguments: arguments()) }
}
