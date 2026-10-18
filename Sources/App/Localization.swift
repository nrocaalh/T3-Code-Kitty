import Foundation
import Combine
import KittyCore

enum AppLanguage: String, CaseIterable {
    case es
    case en
}

@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: KittyDefaults.appLanguage)
            current = L10n.bundle(for: language) ?? fallback
        }
    }

    private var current: Bundle
    private let fallback: Bundle

    private init() {
        fallback = Bundle.main
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: KittyDefaults.appLanguage).flatMap(AppLanguage.init(rawValue:))
        let resolved = stored ?? L10n.systemLanguage()
        language = resolved
        current = L10n.bundle(for: resolved) ?? fallback
    }

    private static func systemLanguage() -> AppLanguage {
        for pref in Locale.preferredLanguages {
            if pref.hasPrefix("en") { return .en }
            if pref.hasPrefix("es") { return .es }
        }
        return .es
    }

    private static func bundle(for lang: AppLanguage) -> Bundle? {
        guard let path = Bundle.main.path(forResource: lang.rawValue, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    func t(_ key: String) -> String {
        current.localizedString(forKey: key, value: key, table: nil)
    }

    func p(_ key: String, _ count: Int) -> String {
        let sub = count == 1 ? "\(key).one" : "\(key).other"
        let template = t(sub)
        return template.replacingOccurrences(of: "%d", with: "\(count)")
    }
}
