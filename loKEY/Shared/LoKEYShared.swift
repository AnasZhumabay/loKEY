import Foundation
import ActivityKit

/// Идентификатор App Group — общий для приложения и виджетов.
enum LoKEYShared {
    static let appGroup = "group.com.anasjumabay.lokey"
    static let snapshotKey = "widget.snapshot.v1"
}

/// Снимок состояния для виджетов. Только названия, уровни и количество: никаких файлов и превью.
struct WidgetSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable {
        /// nil, если названия скрыты в настройках
        var name: String?
        /// SecurityLevel.rawValue: standard / sensitive / critical
        var level: String
        var isOpen: Bool
    }
    var openCount: Int
    var total: Int
    var items: [Item]
    var usedBytes: Int64
    /// Лимит тарифа в байтах; nil у старых снимков (виджет подставит 5 ГБ)
    var limitBytes: Int64? = nil
    var hideNames: Bool
    /// Секунд до автоблокировки на момент `updatedAt`; nil — ничего не открыто
    var secondsLeft: Int?
    var updatedAt: Date

    static let empty = WidgetSnapshot(openCount: 0, total: 0, items: [], usedBytes: 0,
                                      hideNames: false, secondsLeft: nil, updatedAt: Date())

    static func load() -> WidgetSnapshot {
        guard let d = UserDefaults(suiteName: LoKEYShared.appGroup)?.data(forKey: LoKEYShared.snapshotKey),
              let s = try? JSONDecoder().decode(WidgetSnapshot.self, from: d) else { return .empty }
        return s
    }

    func save() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: LoKEYShared.appGroup)?.set(d, forKey: LoKEYShared.snapshotKey)
    }
}

/// Live Activity: таймер автоблокировки открытых кейсов.
struct LoKEYTimerAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Когда сработает автоблокировка
        var endsAt: Date
        /// Полная длительность таймера, сек (для прогресс-бара)
        var totalSeconds: Int
        /// «Документы» или «2 кейса»; пустая строка — названия скрыты
        var title: String
        var openCount: Int
        var isWarning: Bool
    }
    var startedAt: Date
}
