import XCTest
@testable import loKEY

private final class FakeCenter: ReminderNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    var state: ReminderAuthState = .granted
    var added: [(id: String, body: String, fire: DateComponents)] = []
    var removed: [String] = []
    func requestAuthorization() async -> Bool { state = .granted; return true }
    func authorizationState() async -> ReminderAuthState { state }
    func add(identifier: String, title: String, body: String, fire: DateComponents) async throws {
        lock.lock(); added.removeAll { $0.id == identifier }; added.append((identifier, body, fire)); lock.unlock()
    }
    func pendingIdentifiers() async -> [String] { lock.lock(); defer { lock.unlock() }; return added.map(\.id) }
    func remove(identifiers: [String]) async {
        lock.lock(); added.removeAll { identifiers.contains($0.id) }; removed += identifiers; lock.unlock()
    }
}

final class RemindersTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC") ?? .current; return c
    }()
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h)) ?? Date.distantPast
    }
    private var now: Date { date(2026, 11, 18, 12) }

    // MARK: Парсер

    func testParserTable() {
        let cases: [(String, Date?)] = [
            ("Паспорт. Действителен до 12.05.2030", date(2030, 5, 12)),
            ("срок действия: 01/03/28", date(2028, 3, 1)),
            ("Valid until 2029-07-31", date(2029, 7, 31)),
            ("Date of expiry 5-6-2031", date(2031, 6, 5)),
            ("Дата выдачи 01.01.2020, действителен до 01.01.2030", date(2030, 1, 1)),
            ("Дата рождения 12.05.2030", nil),            // нет слова про срок
            ("Просто дата 12.05.2030", nil),
            ("действителен до 31.02.2030", nil),          // несуществующая дата
            ("действителен до 12.05.2070", nil),          // дальше +30 лет
            ("действителен до 12.05.2020", nil),          // старше -1 года
            ("valid until 01.11.2026", date(2026, 11, 1)) // просрочен меньше года назад
        ]
        for (text, expected) in cases {
            XCTAssertEqual(ExpiryDateParser.expiry(in: text, now: now, calendar: cal), expected, text)
        }
    }

    func testSanityBounds() {
        XCTAssertTrue(ExpiryDateParser.isSane(date(2026, 11, 18), now: now, calendar: cal))
        XCTAssertTrue(ExpiryDateParser.isSane(date(2025, 11, 19), now: now, calendar: cal))
        XCTAssertFalse(ExpiryDateParser.isSane(date(2025, 11, 10), now: now, calendar: cal))
        XCTAssertTrue(ExpiryDateParser.isSane(date(2056, 11, 18), now: now, calendar: cal))
        XCTAssertFalse(ExpiryDateParser.isSane(date(2056, 11, 20), now: now, calendar: cal))
    }

    func testKindClassification() {
        XCTAssertEqual(ReminderKind.classify("Загранпаспорт.pdf"), .passport)
        XCTAssertEqual(ReminderKind.classify("Страховой полис"), .insurance)
        XCTAssertEqual(ReminderKind.classify("random"), .other)
    }

    // MARK: Планировщик

    func testPlannerIdentifiersAndTimes() {
        let r = DocumentReminder(id: "abc", fileName: "x", expiresOn: date(2027, 1, 31))
        let plan = ReminderPlanner.plan([r], now: now, calendar: cal)
        XCTAssertEqual(plan.map(\.identifier), ["lokey.reminder.abc.30", "lokey.reminder.abc.7", "lokey.reminder.abc.1"])
        XCTAssertEqual(plan.map(\.fireDate), [date(2027, 1, 1, 9), date(2027, 1, 24, 9), date(2027, 1, 30, 9)])
    }

    func testPlannerSkipsPastAndDisabled() {
        let soon = DocumentReminder(id: "s", fileName: "x", expiresOn: date(2026, 11, 25))   // 30 прошло, 7 = 18.11 09:00 прошло
        let plan = ReminderPlanner.plan([soon], now: now, calendar: cal)
        XCTAssertEqual(plan.map(\.identifier), ["lokey.reminder.s.1"])
        var off = soon; off.enabled = false
        XCTAssertTrue(ReminderPlanner.plan([off], now: now, calendar: cal).isEmpty)
    }

    func testPlannerCapsPending() {
        let many = (0..<40).map { DocumentReminder(id: "\($0)", fileName: "x", expiresOn: date(2028, 1, 1).addingTimeInterval(Double($0) * 86_400)) }
        XCTAssertEqual(ReminderPlanner.plan(many, now: now, calendar: cal).count, ReminderPlanner.maxPending)
    }

    func testNotificationTextHasNoPersonalData() {
        XCTAssertEqual(ReminderPlanner.body, "Срок документа истекает, откройте loKEY")
    }

    // MARK: Сервис

    private func makeService(_ center: FakeCenter, store: ReminderStore = InMemoryReminderStore()) -> ReminderServiceImpl {
        let repo = VaultRepositoryImpl(api: MockBackend.makeServices(latency: 0...0), keys: InMemoryKeyStore(), seedDemo: false, persistence: false)
        let n = now
        return ReminderServiceImpl(repo: repo, notifier: center, store: store, now: { n }, calendar: cal)
    }

    func testScheduleReplacesAndRespectsPermission() async {
        let center = FakeCenter()
        let svc = makeService(center)
        await svc.add(DocumentReminder(id: "p", fileName: "Секретный паспорт", expiresOn: date(2027, 6, 1)))
        XCTAssertEqual(center.added.count, 3)
        XCTAssertFalse(center.added.contains { $0.body.contains("паспорт") })
        await svc.schedule()
        XCTAssertEqual(center.added.count, 3, "повторное планирование заменяет, а не дублирует")
        await svc.remove(id: "p")
        XCTAssertTrue(center.added.isEmpty)

        center.state = .denied
        await svc.add(DocumentReminder(id: "q", fileName: "x", expiresOn: date(2027, 6, 1)))
        XCTAssertTrue(center.added.isEmpty)
    }

    func testEncryptedStoreRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EncryptedReminderStore(keys: InMemoryKeyStore(), baseDirectory: dir)
        let r = DocumentReminder(id: "z", fileName: "Паспорт Иванов", expiresOn: date(2030, 1, 1))
        try await store.save([r])
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [r])
        let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        for f in files where !f.hasDirectoryPath {
            let raw = (try? Data(contentsOf: f)) ?? Data()
            XCTAssertNil(raw.range(of: Data("Иванов".utf8)), "на диске нет открытого текста")
        }
    }
}
