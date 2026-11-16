import SwiftUI

/// Languages the interface ships in. English is the default.
public enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case vietnamese = "vi"

    /// Shown in the language picker; always in the language itself.
    public var title: String { self == .english ? "English" : "Tiếng Việt" }
}

/// The language choice. Root views observe it and rebuild (`.id(language)`) when it changes, so
/// every `tr(...)` below them is evaluated again.
@MainActor
public final class LanguageSettings: ObservableObject {
    public static let shared = LanguageSettings()

    @Published public var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: L10n.key)
            L10n.current = language
        }
    }

    private init() { language = L10n.current }
}

enum L10n {
    static let key = "app_language"
    /// Read from any thread by `tr`, written on the main thread only; a one-byte enum, so a stale
    /// read during a switch is harmless (the views rebuild right after).
    nonisolated(unsafe) static var current: AppLanguage =
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .english
}

/// Picks the string for the current language. Both versions sit side by side at the call site, so a
/// string can never exist in one language only. Call it when the text is needed (in `body`, in a
/// computed property) — never store the result in a `static let`, or it stops following the setting.
public func tr(_ english: String, _ vietnamese: String) -> String {
    L10n.current == .vietnamese ? vietnamese : english
}
