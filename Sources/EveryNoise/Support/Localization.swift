import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case ru, en

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ru: "Русский"
        case .en: "English"
        }
    }

    nonisolated static var systemDefault: AppLanguage {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ru") ? .ru : .en
    }
}

/// Язык интерфейса. Ключами словаря служат русские строки, поэтому в коде остаётся
/// читаемый текст, а недостающий перевод деградирует в него же.
@Observable
final class Localization {
    static let shared = Localization()

    nonisolated private static let key = "appLanguage"

    var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.key)
            Localization.active = language
        }
    }

    private init() { language = Localization.active }

    /// Читается из любого контекста, меняется только с главного актора. Инициализируется
    /// лениво из настроек, а не значением по умолчанию: первые записи журнала появляются
    /// раньше, чем кто-либо обратится к `shared`.
    nonisolated(unsafe) fileprivate static var active: AppLanguage = stored()

    nonisolated private static func stored() -> AppLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .systemDefault
    }
}

/// Перевод строки. Ключ — русский текст; для английского берётся значение из таблицы.
nonisolated func L(_ ru: String) -> String {
    Localization.active == .ru ? ru : (englishStrings[ru] ?? ru)
}

/// Перевод строки формата с подстановками.
nonisolated func L(_ ru: String, _ arguments: CVarArg...) -> String {
    String(format: L(ru), arguments: arguments)
}
