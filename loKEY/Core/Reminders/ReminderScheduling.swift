// Планирование локальных уведомлений. Планировщик — чистая функция; центр уведомлений скрыт за протоколом (для тестов).
import Foundation
import UserNotifications

struct PlannedNotification: Equatable, Sendable {
    var identifier: String
    var fireDate: Date
}

enum ReminderPlanner {
    static let idPrefix = "lokey.reminder."
    static let hour = 9
    /// iOS хранит не более 64 ожидающих уведомлений.
    static let maxPending = 60
    /// В тексте уведомления нет ни названий документов, ни личных данных.
    static let title = "loKEY"
    static let body = "Срок документа истекает, откройте loKEY"

    static func identifier(reminderID: String, days: Int) -> String { "\(idPrefix)\(reminderID).\(days)" }

    static func plan(_ reminders: [DocumentReminder], now: Date, calendar: Calendar) -> [PlannedNotification] {
        var out: [PlannedNotification] = []
        for r in reminders where r.enabled {
            let day = calendar.startOfDay(for: r.expiresOn)
            for n in Set(r.notifyDaysBefore).sorted() where n >= 0 {
                guard let d = calendar.date(byAdding: .day, value: -n, to: day),
                      let fire = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: d), fire > now else { continue }
                out.append(PlannedNotification(identifier: identifier(reminderID: r.id, days: n), fireDate: fire))
            }
        }
        return Array(out.sorted { $0.fireDate < $1.fireDate }.prefix(maxPending))
    }
}

protocol ReminderNotificationCenter: Sendable {
    func requestAuthorization() async -> Bool
    func authorizationState() async -> ReminderAuthState
    func add(identifier: String, title: String, body: String, fire: DateComponents) async throws
    func pendingIdentifiers() async -> [String]
    func remove(identifiers: [String]) async
}

struct SystemReminderCenter: ReminderNotificationCenter, @unchecked Sendable {
    let center: UNUserNotificationCenter

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
    func authorizationState() async -> ReminderAuthState {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .granted
        }
    }
    func add(identifier: String, title: String, body: String, fire: DateComponents) async throws {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: fire, repeats: false)
        try await center.add(UNNotificationRequest(identifier: identifier, content: c, trigger: trigger))
    }
    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }
    func remove(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
