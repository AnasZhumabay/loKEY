import SwiftUI

/// Пункты «степени защиты»: показываются в Настройках и плашкой на главной.
struct SecurityItem: Identifiable {
    enum Fix { case faceID, mfa, backupEmail, autoLock, keysSaved, hideNames }
    var id: String
    var title: String
    var hint: String
    var icon: String
    var done: Bool
    var fix: Fix
}

extension AppStore {
    var securityItems: [SecurityItem] {
        [
            .init(id: "faceid", title: tr("Face ID для кейсов"), hint: tr("Ключи открываются лицом"), icon: "faceid", done: faceIDEnabled, fix: .faceID),
            .init(id: "mfa", title: tr("Двухфакторный вход"), hint: tr("Защита аккаунта вторым кодом"), icon: "lock.shield", done: account?.mfaEnabled ?? false, fix: .mfa),
            .init(id: "backup", title: tr("Запасной email"), hint: tr("Чтобы вернуть доступ к аккаунту"), icon: "envelope", done: !(account?.backupEmail ?? "").isEmpty, fix: .backupEmail),
            .init(id: "autolock", title: tr("Автоблокировка до 5 минут"), hint: tr("Кейсы закрываются сами"), icon: "timer", done: autoLockMinutes <= 5, fix: .autoLock),
            .init(id: "keys", title: tr("Ключи и 12 слов сохранены"), hint: tr("Без них доступ не вернуть"), icon: "key.fill", done: keysSaved, fix: .keysSaved),
            .init(id: "hide", title: tr("Названия скрыты в виджетах"), hint: tr("Никто не увидит кейсы с экрана"), icon: "eye.slash", done: hideNamesInWidgets, fix: .hideNames),
        ]
    }
    var securityScore: Double {
        let items = securityItems
        return Double(items.filter(\.done).count) / Double(max(items.count, 1))
    }
    func applyFix(_ fix: SecurityItem.Fix) {
        switch fix {
        case .faceID: faceIDEnabled = true
        case .autoLock: autoLockMinutes = 5
        case .keysSaved: keysSaved = true
        case .hideNames: hideNamesInWidgets = true
        case .mfa, .backupEmail: break   // нужен отдельный экран, выполняется в Настройках
        }
    }
}
