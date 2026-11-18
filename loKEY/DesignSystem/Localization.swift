import SwiftUI

/// Языки интерфейса. Тексты в коде — по-русски и служат ключами для Localizable.strings (ru — базовый).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en, kk
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Как в системе"
        case .ru: return "Русский"
        case .en: return "English"
        case .kk: return "Қазақша"
        }
    }
    /// nil → системный язык
    var locale: Locale? { self == .system ? nil : Locale(identifier: rawValue) }
}

/// Строки, которые попадают в UI как `String` (а не как литерал в `Text("…")`).
func tr(_ ru: String) -> String { LKBundle.string(ru) }

/// Форматированная строка: ключ с %@ / %lld ищется в Localizable.strings, потом подставляются аргументы.
func trf(_ ru: String, _ args: CVarArg...) -> String { String(format: tr(ru), arguments: args) }

enum LKBundle {
    /// Локаль для дат/относительного времени: выбранный язык приложения или системная.
    static var uiLocale: Locale { language.locale ?? Locale.current }
    nonisolated(unsafe) static var language: AppLanguage = .system { didSet { install() } }
    nonisolated(unsafe) private static var installed = false

    /// Bundle выбранного языка; nil — работает системный выбор.
    static var override: Bundle? {
        switch language {
        case .system: return nil
        case .ru: return nil
        default:
            guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj") else { return nil }
            return Bundle(path: path)
        }
    }
    static var forceBase: Bool { language == .ru }

    /// Подменяем класс Bundle.main один раз: все `Text("…")`, `Label`, `Button` и `tr()` читают язык, выбранный в приложении.
    static func install() {
        guard !installed else { return }
        installed = true
        object_setClass(Bundle.main, LKLanguageBundle.self)
    }

    static func string(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
}

private final class LKLanguageBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if LKBundle.forceBase { return value ?? key }
        if let b = LKBundle.override { return b.localizedString(forKey: key, value: value, table: tableName) }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

// Строковые параметры (`Text(title)` с переменной типа String) тоже ищутся в Localizable.strings.
extension Text {
    init(_ s: String) { self.init(LocalizedStringKey(s)) }
}
