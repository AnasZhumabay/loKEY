import Foundation

/// Страницы вступления. Чистая логика (без UI): порядок, пропуск и прогресс.
enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome, cipher, keys, words, chat, protection, final
    var id: Int { rawValue }
    /// Номер для accessibilityIdentifier `onboardingPage-<n>` (с единицы).
    var number: Int { rawValue + 1 }
    static var count: Int { allCases.count }

    /// «Пропустить» есть на страницах 1–5, кроме обязательной страницы про 12 слов.
    var canSkip: Bool { rawValue <= OnboardingPage.chat.rawValue && self != .words }
    var isLast: Bool { self == .final }
}

struct OnboardingFlow: Equatable {
    private(set) var page: OnboardingPage = .welcome

    var index: Int { page.rawValue }
    var isFirst: Bool { page == .welcome }
    var isLast: Bool { page.isLast }
    var canSkip: Bool { page.canSkip }
    /// 0…1, на первой странице уже не ноль.
    var progress: Double { Double(index + 1) / Double(OnboardingPage.count) }

    mutating func next() { if let p = OnboardingPage(rawValue: index + 1) { page = p } }
    mutating func back() { if let p = OnboardingPage(rawValue: index - 1) { page = p } }
    /// Пропуск не обходит страницу про 12 слов: с 1–3 ведёт к ней, с 5 — к финалу.
    mutating func skip() {
        guard canSkip else { return }
        page = page.rawValue < OnboardingPage.words.rawValue ? .words : .final
    }
    mutating func go(to index: Int) { if let p = OnboardingPage(rawValue: index) { page = p } }
}
