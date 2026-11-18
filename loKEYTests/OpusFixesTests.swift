import XCTest
@testable import loKEY

private actor ReminderSpy: ReminderService {
    var clearCount = 0
    var suspended = false
    func scan() async -> [DocumentReminder] { [] }
    func list() async -> [DocumentReminder] { [] }
    func add(_ reminder: DocumentReminder) async {}
    func update(_ reminder: DocumentReminder) async {}
    func remove(id: String) async {}
    func schedule() async {}
    func requestAuthorization() async -> Bool { true }
    func authorizationState() async -> ReminderAuthState { .granted }
    func clearAll() async { clearCount += 1 }
    func setSuspended(_ s: Bool) async { suspended = s }
}

/// Исправления по независимой проверке: приманка (перезапуск, выход), резервные копии, общие кейсы, попытки, история.
final class OpusFixesTests: XCTestCase {
    private func repo(_ api: APIServices, _ keys: KeyStore, login: Bool = true) async throws -> VaultRepositoryImpl {
        let r = VaultRepositoryImpl(api: api, keys: keys, seedDemo: false, persistence: false, duressRounds: 1_000)
        if login { _ = try await r.login(identifier: "tester", password: "secret1") }
        return r
    }
    private func services() -> APIServices {
        MockBackend.Hooks.setLatencyEnabled(false)
        return MockBackend.makeServices(latency: 0...0)
    }

    // MARK: 1. Приманка переживает перезапуск, выход не стирает настоящее

    func testDecoySurvivesRestartAndExitNeedsRealLogin() async throws {
        let api = services(); let keys = InMemoryKeyStore()
        let a = try await repo(api, keys)
        let real = try await a.createCase(name: "Паспорт", icon: .document, level: .critical)
        try await a.setDuressPIN("483920")
        let entered = await a.unlockAppWithDuress(pin: "483920")
        XCTAssertTrue(entered)

        // «Перезапуск»: новый репозиторий с тем же Keychain
        let b = try await repo(api, keys, login: false)
        let acc = await b.restoreSession()
        XCTAssertNotNil(acc)
        let decoy = await b.isDecoy
        XCTAssertTrue(decoy)
        let snap = await b.offlineSnapshot()
        XCTAssertNil(snap)
        let names = Set(try await b.listCases().map(\.name))
        XCTAssertEqual(names, ["Рецепты", "Рабочее"])

        // Выход из приманки: настоящая серверная сессия жива, данные на месте, но тихо не восстанавливаются
        try await b.logout()
        let serverSession = await api.auth.restoreSession()
        XCTAssertNotNil(serverSession)
        let c = try await repo(api, keys, login: false)
        let after = await c.restoreSession()
        XCTAssertNil(after)
        let notDecoy = await c.isDecoy
        XCTAssertFalse(notDecoy)
        let serverCases = try await api.cases.list()
        XCTAssertTrue(serverCases.contains { $0.id == real.vaultCase.id })

        // Настоящий вход снимает запрет
        _ = try await c.login(identifier: "tester", password: "secret1")
        let d = try await repo(api, keys, login: false)
        let restored = await d.restoreSession()
        XCTAssertEqual(restored?.username == "me", false)
        let stillNotDecoy = await d.isDecoy
        XCTAssertFalse(stillNotDecoy)
    }

    // MARK: 2. signOut в приманке не стирает настоящие напоминания

    @MainActor func testSignOutInDecoyDoesNotClearReminders() async throws {
        let api = services(); let keys = InMemoryKeyStore()
        let r = try await repo(api, keys)
        try await r.setDuressPIN("483920")
        let spy = ReminderSpy()
        let chat = ChatRepositoryImpl(api: api.chat, keys: InMemoryKeyStore(), persist: false)
        let store = AppStore(repo: r, chat: chat, reminders: spy)
        let ok = await store.enterDuress(pin: "483920")
        XCTAssertTrue(ok)
        let susp = await spy.suspended
        XCTAssertTrue(susp)
        await store.signOut()
        let n = await spy.clearCount
        XCTAssertEqual(n, 0)
        XCTAssertEqual(store.phase, .signedOut)

        // Обычный выход чистит
        let r2 = try await repo(services(), InMemoryKeyStore())
        let spy2 = ReminderSpy()
        let store2 = AppStore(repo: r2, chat: ChatRepositoryImpl(api: services().chat, keys: InMemoryKeyStore(), persist: false), reminders: spy2)
        await store2.signOut()
        let n2 = await spy2.clearCount
        XCTAssertEqual(n2, 1)
    }

    // MARK: 3. Резервные копии в приманке

    func testBackupUnavailableInDecoy() async throws {
        let api = services(); let keys = InMemoryKeyStore()
        let r = try await repo(api, keys)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("op-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let local = LocalFolderBackupStore(directory: tmp.appendingPathComponent("local"))
        let svc = BackupServiceImpl(repo: r, backupAPI: api.backup, events: UnavailableSecurityEventAPI(),
                                    cloud: LocalFolderBackupStore(directory: tmp.appendingPathComponent("cloud")), local: local,
                                    kdfRounds: 1000, defaults: UserDefaults(suiteName: "op-\(UUID().uuidString)") ?? .standard)
        _ = try await r.createCase(name: "X", icon: .document, level: .standard)
        _ = try await svc.createBackup(destination: .localFile, passphrase: "correct horse battery 42") { _ in }
        let real = await svc.listBackups()
        XCTAssertEqual(real.count, 1)
        let last = await svc.lastBackupDate
        XCTAssertNotNil(last)

        try await r.setDuressPIN("483920")
        _ = await r.unlockAppWithDuress(pin: "483920")
        let list = await svc.listBackups()
        XCTAssertTrue(list.isEmpty)
        let lastD = await svc.lastBackupDate
        XCTAssertNil(lastD)
        do { _ = try await svc.createBackup(destination: .localFile, passphrase: "correct horse battery 42") { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? BackupError, .unavailable) }
        do { try await svc.delete(real[0]); XCTFail() } catch { XCTAssertEqual(error as? BackupError, .unavailable) }
        // настоящая копия не тронута
        let files = (try? await local.list()) ?? []
        XCTAssertEqual(files.count, 1)
    }

    // MARK: 4. Общие кейсы в приманке

    func testSharedInvitesHiddenInDecoy() async throws {
        let api = services(); let keys = InMemoryKeyStore()
        let r = try await repo(api, keys)
        let chat = ChatRepositoryImpl(api: api.chat, keys: InMemoryKeyStore(), persist: false)
        try await chat.configure(accountID: "me-id", username: "me", historyStore: nil)
        let svc = SharedCaseServiceImpl(repo: r, chat: chat, api: DemoSharedCaseAPI(base: MockSharedCaseAPI(me: "me-id"), me: "me-id"),
                                        agreement: DemoKeyAgreement(myID: "me-id"), keys: InMemoryKeyStore(),
                                        defaults: UserDefaults(suiteName: "op-\(UUID().uuidString)") ?? .standard)
        let before = try await svc.pendingInvites()
        XCTAssertFalse(before.isEmpty)
        try await r.setDuressPIN("483920")
        _ = await r.unlockAppWithDuress(pin: "483920")
        let after = try await svc.pendingInvites()
        XCTAssertTrue(after.isEmpty)
        do { try await svc.accept(inviteId: before[0].id); XCTFail() } catch { XCTAssertEqual(error as? SharedCaseError, .notReady) }
    }

    // MARK: 6 и 9. Попытки подбора

    func testSharedUnlockAndForeignKeyFileDoNotCountAttempts() async throws {
        let api = services(); let keys = InMemoryKeyStore()
        let r = try await repo(api, keys)
        let a = try await r.createCase(name: "A", icon: .document, level: .standard)
        let b = try await r.createCase(name: "B", icon: .document, level: .standard)
        await r.lockAll()
        let start = await r.unlockStatus(caseID: a.vaultCase.id).attemptsLeft
        // чужой ключ-файл: отказ без попытки
        do { try await r.unlockCase(id: a.vaultCase.id, method: .keyFile(b.keyFileData)); XCTFail() }
        catch { XCTAssertEqual(error as? VaultError, .invalidKeyFormat) }
        // мусорный файл: тоже без попытки
        do { try await r.unlockCase(id: a.vaultCase.id, method: .keyFile(Data("x".utf8))); XCTFail() } catch {}
        // секрет из «приглашения» неверный: не попытка
        for _ in 0..<10 {
            do { try await r.unlockSharedCase(id: a.vaultCase.id, secret: KeyFormat.generateSecret()); XCTFail() } catch {}
        }
        let left = await r.unlockStatus(caseID: a.vaultCase.id).attemptsLeft
        XCTAssertEqual(left, start)
        // верный секрет открывает
        try await r.unlockSharedCase(id: a.vaultCase.id, secret: try KeyFormat.parseKeyFile(a.keyFileData).secret)
        let unlocked = try await r.listCases().first { $0.id == a.vaultCase.id }?.isUnlocked
        XCTAssertEqual(unlocked, true)
    }

    // MARK: 7. Битый файл истории

    func testHistoryLoadSkipsCorruptedFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileHistoryStore(key: Data(repeating: 7, count: 32), baseDirectory: dir)
        try await store.save(accountId: "acc", contactId: "c1", Data("one".utf8))
        try await store.save(accountId: "acc", contactId: "c2", Data("two".utf8))
        let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "enc" }
        XCTAssertEqual(files.count, 2)
        try Data("garbage".utf8).write(to: files[0])
        let loaded = try await store.load(accountId: "acc")
        XCTAssertEqual(loaded.count, 1)
    }

    // MARK: 11. Правила безопасности в Domain

    func testSecurityRules() {
        XCTAssertEqual(SecurityRules.duressPINLength, 6)
        XCTAssertTrue(SecurityRules.isDuressPINFormatValid("483920"))
        XCTAssertFalse(SecurityRules.isDuressPINFormatValid("48392"))
        XCTAssertFalse(SecurityRules.isDuressPINFormatValid("48392a"))
        XCTAssertEqual(DuressPIN.length, SecurityRules.duressPINLength)
        XCTAssertLessThan(SecurityRules.passphraseStrength("abc"), SecurityRules.passphraseStrength("Correct-Horse-Battery-42!"))
    }
}
