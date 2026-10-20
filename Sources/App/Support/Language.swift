import Foundation

/// The notch speaks Russian or English: the one picked in the menu, or else whichever of the
/// two comes first in the system's preferred languages (English if neither is there).
enum Language: String, CaseIterable {
    case ru, en

    static let key = "language"

    private(set) static var current = resolve()

    /// nil follows the system.
    static var choice: Language? {
        get { UserDefaults.standard.string(forKey: key).flatMap(Language.init(rawValue:)) }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: key)
            current = resolve()
        }
    }

    private static func resolve() -> Language {
        if let choice { return choice }
        for preferred in Locale.preferredLanguages {
            if preferred.hasPrefix("ru") { return .ru }
            if preferred.hasPrefix("en") { return .en }
        }
        return .en
    }
}

/// The text in the language the notch speaks.
func tr(_ ru: String, _ en: String) -> String {
    Language.current == .ru ? ru : en
}

/// "1 действие", "3 действия", "5 действий" / "1 action", "3 actions".
func actionsText(_ n: Int) -> String {
    tr("\(n) " + plural(n, "действие", "действия", "действий"), n == 1 ? "1 action" : "\(n) actions")
}
