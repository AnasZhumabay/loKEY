import Foundation
import UserNotifications

actor ReminderServiceImpl: ReminderService {
    private let repo: VaultRepository
    private let notifier: ReminderNotificationCenter
    private let store: ReminderStore
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    init(repo: VaultRepository, center: UNUserNotificationCenter = .current(), now: @escaping @Sendable () -> Date = Date.init,
         store: ReminderStore = AppConfig.useMocks ? InMemoryReminderStore() : EncryptedReminderStore(),
         calendar: Calendar = .current) {
        self.repo = repo; self.notifier = SystemReminderCenter(center: center)
        self.store = store; self.now = now; self.calendar = calendar
    }

    /// Для тестов: подмена центра уведомлений.
    init(repo: VaultRepository, notifier: ReminderNotificationCenter, store: ReminderStore,
         now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current) {
        self.repo = repo; self.notifier = notifier; self.store = store; self.now = now; self.calendar = calendar
    }

    private var suspended = false

    func clearAll() async {
        suspended = false
        try? await store.save([])
        let pending = await notifier.pendingIdentifiers().filter { $0.hasPrefix(ReminderPlanner.idPrefix) }
        await notifier.remove(identifiers: pending)
    }
    func setSuspended(_ on: Bool) async {
        suspended = on
        await schedule()
    }

    func list() async -> [DocumentReminder] {
        if suspended { return [] }
        return ((try? await store.load()) ?? []).sorted { $0.expiresOn < $1.expiresOn }
    }

    func add(_ reminder: DocumentReminder) async {
        guard !suspended else { return }
        var all = await list()
        all.removeAll { $0.id == reminder.id }
        all.append(reminder)
        try? await store.save(all)
        await schedule()
    }
    func update(_ reminder: DocumentReminder) async { await add(reminder) }
    func remove(id: String) async {
        guard !suspended else { return }
        var all = await list()
        all.removeAll { $0.id == id }
        try? await store.save(all)
        await schedule()
    }

    func scan() async -> [DocumentReminder] {
        guard !suspended else { return [] }
        let today = now()
        guard let cases = try? await repo.listCases() else { return [] }
        var found: [DocumentReminder] = []
        for c in cases where c.isUnlocked {
            guard let files = try? await repo.listFiles(caseID: c.id) else { continue }
            for f in files where f.deletedAt == nil {
                let text = [f.name, f.note ?? "", f.ocr ?? ""].joined(separator: "\n")
                guard let date = ExpiryDateParser.expiry(in: text, now: today, calendar: calendar) else { continue }
                found.append(DocumentReminder(id: "auto-\(f.id)", fileId: f.id, caseId: c.id, caseName: c.name, fileName: f.name,
                                              kind: ReminderKind.classify(text), expiresOn: date, source: .auto))
            }
        }
        var all = await list()
        var result: [DocumentReminder] = []
        for var r in found {
            if let old = all.first(where: { $0.id == r.id }) {
                r.enabled = old.enabled; r.notifyDaysBefore = old.notifyDaysBefore
                if old.source == .manual { continue }   // дату, исправленную вручную, не перетираем
            }
            all.removeAll { $0.id == r.id }
            all.append(r); result.append(r)
        }
        try? await store.save(all)
        await schedule()
        return result.sorted { $0.expiresOn < $1.expiresOn }
    }

    func schedule() async {
        let all = await list()
        let pending = await notifier.pendingIdentifiers().filter { $0.hasPrefix(ReminderPlanner.idPrefix) }
        await notifier.remove(identifiers: pending)
        guard await notifier.authorizationState() == .granted else { return }
        let body = LKBundle.string(ReminderPlanner.body)
        for p in ReminderPlanner.plan(all, now: now(), calendar: calendar) {
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: p.fireDate)
            try? await notifier.add(identifier: p.identifier, title: ReminderPlanner.title, body: body, fire: comps)
        }
    }

    func requestAuthorization() async -> Bool {
        let ok = await notifier.requestAuthorization()
        if ok { await schedule() }
        return ok
    }
    func authorizationState() async -> ReminderAuthState { await notifier.authorizationState() }
}
