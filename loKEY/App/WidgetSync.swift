import Foundation
import WidgetKit
import ActivityKit

/// Публикует снимок состояния для виджетов (App Group). Вызывается часто — сама ограничивает частоту.
enum WidgetSync {
    private static var lastReload = Date.distantPast
    private static var trailingScheduled = false
    private static var lastShape: [WidgetSnapshot.Item]?

    static func publish(cases: [VaultCase], secondsLeft: Int?, hideNames: Bool, limitBytes: Int64? = nil, force: Bool = false) {
        let open = cases.filter(\.isUnlocked)
        let items = cases.map {
            WidgetSnapshot.Item(name: hideNames ? nil : $0.name, level: $0.level.rawValue, isOpen: $0.isUnlocked)
        }
        let snap = WidgetSnapshot(openCount: open.count, total: cases.count, items: items,
                                  usedBytes: cases.reduce(0) { $0 + $1.bytes }, limitBytes: limitBytes, hideNames: hideNames,
                                  secondsLeft: open.isEmpty ? nil : secondsLeft, updatedAt: Date())
        let changed = items != lastShape
        let due = Date().timeIntervalSince(lastReload) >= 5
        guard changed || due || force else { return }
        // Пишем в UserDefaults только когда можем и перезагрузить таймлайны (раз в 5 с).
        if due || force {
            snap.save()
            lastShape = items
            lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        } else if !trailingScheduled {
            trailingScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                trailingScheduled = false
                snap.save()
                lastShape = items
                lastReload = Date()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}

/// Live Activity / Dynamic Island с таймером автоблокировки.
@MainActor
enum LiveActivityController {
    private static var activity: Activity<LoKEYTimerAttributes>?
    private static var lastUpdate = Date.distantPast
    private static var totalSeconds = 0
    private static var lastOpenCount = 0

    static func sync(openCaseNames: [String], secondsLeft: Int?) {
        guard #available(iOS 16.2, *) else { return }
        guard let left = secondsLeft, !openCaseNames.isEmpty else {
            end()
            return
        }
        if left > totalSeconds { totalSeconds = left }
        let countChanged = openCaseNames.count != lastOpenCount
        guard activity == nil || countChanged || Date().timeIntervalSince(lastUpdate) >= 10 else { return }
        lastUpdate = Date()
        lastOpenCount = openCaseNames.count
        // Названия скрываем, если включена настройка (тот же ключ, что в Prefs.hideNamesInWidgets).
        let hide = UserDefaults.standard.bool(forKey: "hideNamesInWidgets")
        if hide { lastUpdate = .distantPast }
        let title = hide ? "" : (openCaseNames.count == 1 ? openCaseNames[0] : openCaseNames.joined(separator: ", "))
        let state = LoKEYTimerAttributes.ContentState(
            endsAt: Date().addingTimeInterval(TimeInterval(left)), totalSeconds: max(totalSeconds, left, 1),
            title: title, openCount: openCaseNames.count, isWarning: left <= 30)
        let content = ActivityContent(state: state, staleDate: state.endsAt.addingTimeInterval(5))
        if let a = activity {
            Task { await a.update(content) }
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            activity = try? Activity.request(attributes: LoKEYTimerAttributes(startedAt: Date()), content: content)
        }
    }

    private static func end() {
        totalSeconds = 0
        lastOpenCount = 0
        lastUpdate = .distantPast
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
