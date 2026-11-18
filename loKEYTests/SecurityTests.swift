import XCTest
@testable import loKEY

/// Политика доступа к секретам, экстренное стирание, режим «под принуждением», поиск и локальное хранение.
final class SecurityTests: XCTestCase {
    private func makeRepo(keys: KeyStore = InMemoryKeyStore(), api: APIServices? = nil, persistence: Bool? = false,
                          dir: URL? = nil, policy: KeyStoreAccessPolicy? = nil) async throws -> (VaultRepositoryImpl, APIServices, KeyStore) {
        let api = api ?? MockBackend.makeServices(latency: 0...0)
        MockBackend.Hooks.setLatencyEnabled(false)
        let repo = VaultRepositoryImpl(api: api, keys: keys, seedDemo: false, secretPolicy: policy, persistence: persistence,
                                       persistenceDirectory: dir, duressRounds: 1_000)
        _ = try await repo.login(identifier: "tester", password: "secret1")
        return (repo, api, keys)
    }
    private func wrongKey() -> String { KeyFormat.format(KeyFormat.generateSecret()) }

    // MARK: Политика секретов

    func testACLChoice() {
        XCTAssertEqual(KeyStoreACLChoice.choose(biometryAvailable: true, passcodeAvailable: true), .biometryCurrentSet)
        XCTAssertEqual(KeyStoreACLChoice.choose(biometryAvailable: false, passcodeAvailable: true), .userPresence)
        XCTAssertEqual(KeyStoreACLChoice.choose(biometryAvailable: false, passcodeAvailable: false), .none)
    }

    func testSetSecretAppliesPolicyAndFallsBack() throws {
        let ok = InMemoryKeyStore(supportsBiometricACL: true)
        XCTAssertEqual(try ok.setCaseSecret(Data([1, 2]), caseID: "a", policy: .biometric), .biometric)
        XCTAssertEqual(ok.caseSecretPolicy("a"), .biometric)
        // Симулятор/устройство без биометрии и код-пароля: не падаем, остаётся обычная запись.
        let none = InMemoryKeyStore(supportsBiometricACL: false)
        XCTAssertEqual(try none.setCaseSecret(Data([1, 2]), caseID: "a", policy: .biometric), .standard)
        XCTAssertEqual(none.caseSecretPolicy("a"), .standard)
        XCTAssertEqual(none.caseSecret("a"), Data([1, 2]))
    }

    func testLazyMigrationRewritesLegacySecret() throws {
        let ks = InMemoryKeyStore()
        try ks.setCaseSecret(Data([7, 7]), caseID: "c")                       // старая запись: без ACL и без метки
        XCTAssertEqual(ks.caseSecretPolicy("c"), .standard)
        XCTAssertEqual(ks.migrateCaseSecret(Data([7, 7]), caseID: "c", to: .biometric), .biometric)
        XCTAssertEqual(ks.appliedPolicy("case.secret.c"), .biometric)
        XCTAssertEqual(ks.caseSecret("c"), Data([7, 7]))
        // повторно ничего не меняет
        XCTAssertEqual(ks.migrateCaseSecret(Data([7, 7]), caseID: "c", to: .biometric), .biometric)
    }

    func testMigrationKeepsStandardWhenBiometryUnavailable() throws {
        let ks = InMemoryKeyStore(supportsBiometricACL: false)
        try ks.setCaseSecret(Data([5]), caseID: "c")
        XCTAssertEqual(ks.migrateCaseSecret(Data([5]), caseID: "c", to: .biometric), .standard)
        XCTAssertEqual(ks.caseSecret("c"), Data([5]))                          // секрет не потерян
    }

    func testRemoveSecretClearsPolicyMarker() throws {
        let ks = InMemoryKeyStore()
        try ks.setCaseSecret(Data([1]), caseID: "x", policy: .biometric)
        ks.removeCaseSecret("x")
        XCTAssertFalse(ks.hasCaseSecret("x"))
        XCTAssertEqual(ks.caseSecretPolicy("x"), .standard)
    }

    func testUnlockMigratesLegacySecretInRepository() async throws {
        let (repo, _, keys) = try await makeRepo(policy: .biometric)
        let c = try await repo.createCase(name: "Мигр", icon: .key, level: .standard)
        let id = c.vaultCase.id
        // имитируем кейс, созданный старой версией: секрет без ACL
        try keys.setCaseSecret(KeyFormat.parseKeyFile(c.keyFileData).secret, caseID: id)
        XCTAssertEqual(keys.caseSecretPolicy(id), .standard)
        await repo.lockAll()
        try await repo.unlockCase(id: id, method: .keyString(c.keyString))
        XCTAssertEqual(keys.caseSecretPolicy(id), .biometric)
    }

    // MARK: Счётчик попыток и стирание

    func testAttemptDecision() {
        let off = WipePolicy.off
        XCTAssertEqual(AttemptDecision.after(failures: 1, policy: off, lockEvery: 5), .wrong(attemptsLeft: 4))
        XCTAssertEqual(AttemptDecision.after(failures: 5, policy: off, lockEvery: 5), .lock)
        let on = WipePolicy(enabled: true, maxAttempts: 8)
        XCTAssertEqual(AttemptDecision.after(failures: 5, policy: on, lockEvery: 5), .lock)
        XCTAssertEqual(AttemptDecision.after(failures: 6, policy: on, lockEvery: 5), .wrong(attemptsLeft: 2))
        XCTAssertEqual(AttemptDecision.after(failures: 8, policy: on, lockEvery: 5), .wipe)
        XCTAssertEqual(WipePolicy(enabled: true, maxAttempts: 99).clamped.maxAttempts, 10)
        XCTAssertEqual(WipePolicy(enabled: true, maxAttempts: 0).clamped.maxAttempts, 3)
    }

    func testTrackerPersistsInKeyStoreAndResets() {
        let ks = InMemoryKeyStore()
        let t1 = AttemptTracker(keys: ks)
        t1.recordFailure("c"); t1.recordFailure("c")
        XCTAssertEqual(AttemptTracker(keys: ks).state("c").failures, 2)        // «после перезапуска»
        t1.reset("c")
        XCTAssertEqual(AttemptTracker(keys: ks).state("c").failures, 0)
    }

    func testWipeAfterNWrongAttempts() async throws {
        let (repo, api, keys) = try await makeRepo()
        await repo.setWipePolicy(WipePolicy(enabled: true, maxAttempts: 3))
        let c = try await repo.createCase(name: "Секрет", icon: .key, level: .critical)
        let id = c.vaultCase.id
        await repo.lockAll()
        for left in [2, 1] {
            do { try await repo.unlockCase(id: id, method: .keyString(wrongKey())); XCTFail() }
            catch { XCTAssertEqual(error as? VaultError, .wrongKey(attemptsLeft: left)) }
        }
        let st = await repo.unlockStatus(caseID: id)
        XCTAssertEqual(st.attemptsLeft, 1)
        do { try await repo.unlockCase(id: id, method: .keyString(wrongKey())); XCTFail() }
        catch { XCTAssertEqual(error as? VaultError, .localKeyWiped) }
        XCTAssertNil(keys.caseSecret(id))
        XCTAssertFalse(keys.hasCaseSecret(id))
        // кейс остался на сервере; Face ID без локального ключа больше не работает
        do { try await repo.unlockCase(id: id, method: .biometrics); XCTFail() }
        catch { XCTAssertEqual(error as? VaultError, .biometricsFailed) }
        // ...а по ключу и по 12 словам открывается
        try await repo.unlockCase(id: id, method: .keyString(c.keyString))
        await repo.lockAll()
        try await repo.recoverCase(id: id, words: c.recoveryWords)
        try await Task.sleep(nanoseconds: 150_000_000)
        let events = await (api.securityEvents as? MockSecurityEventAPI)?.all() ?? []
        XCTAssertTrue(events.contains { $0.kind == .caseWiped && $0.caseId == id })
    }

    func testWipeOffKeepsLockBehaviourAndCounterSurvivesRelaunch() async throws {
        let (repo, api, keys) = try await makeRepo()
        let c = try await repo.createCase(name: "К", icon: .key, level: .standard)
        let id = c.vaultCase.id
        await repo.lockAll()
        for _ in 0..<2 { do { try await repo.unlockCase(id: id, method: .keyString(wrongKey())) } catch {} }
        // «перезапуск»: новый репозиторий с тем же Keychain
        let (repo2, _, _) = try await makeRepo(keys: keys, api: api)
        let st = await repo2.unlockStatus(caseID: id)
        XCTAssertEqual(st.attemptsLeft, 3)
        try await repo2.unlockCase(id: id, method: .keyString(c.keyString))
        let after = await repo2.unlockStatus(caseID: id)
        XCTAssertEqual(after.attemptsLeft, 5)                                // успех сбрасывает
    }

    func testWipePolicyPersistsAndIsClamped() async throws {
        let (repo, api, keys) = try await makeRepo()
        let initial = await repo.wipePolicy
        XCTAssertEqual(initial, .off)
        await repo.setWipePolicy(WipePolicy(enabled: true, maxAttempts: 50))
        let (repo2, _, _) = try await makeRepo(keys: keys, api: api)
        let p = await repo2.wipePolicy
        XCTAssertEqual(p, WipePolicy(enabled: true, maxAttempts: 10))
    }

    // MARK: Режим «под принуждением»

    func testDuressPINValidationAndHashing() async throws {
        let (repo, _, keys) = try await makeRepo()
        for bad in ["123", "12345a", "000000", "123456", "654321"] {
            do { try await repo.setDuressPIN(bad); XCTFail(bad) } catch { XCTAssertTrue(error is VaultError) }
        }
        try await repo.setDuressPIN("483920")
        let enabled = await repo.duressEnabled
        XCTAssertTrue(enabled)
        let stored = try XCTUnwrap(keys.read("duress.pin"))
        XCTAssertNil(String(decoding: stored, as: UTF8.self).range(of: "483920"))   // открытого PIN нет
        try await repo.setDuressPIN(nil)
        let off = await repo.duressEnabled
        XCTAssertFalse(off)
    }

    func testDuressOpensDecoyAndLeavesRealDataUntouched() async throws {
        let (repo, api, keys) = try await makeRepo()
        let real = try await repo.createCase(name: "Паспорт и счета", icon: .document, level: .critical)
        _ = try await repo.addFile(caseID: real.vaultCase.id, name: "Настоящий файл", kind: .pdf, data: Data("real".utf8), note: nil, progress: { _ in })
        try await repo.setDuressPIN("483920")
        let wrong = await repo.unlockAppWithDuress(pin: "111222")
        XCTAssertFalse(wrong)
        let ok = await repo.unlockAppWithDuress(pin: "483920")
        XCTAssertTrue(ok)

        let cases = try await repo.listCases()
        XCTAssertEqual(Set(cases.map(\.name)), ["Рецепты", "Рабочее"])
        XCTAssertFalse(cases.contains { $0.id == real.vaultCase.id })
        let files = try await repo.listFiles(caseID: cases[0].id)
        XCTAssertFalse(files.isEmpty)
        XCTAssertFalse(files.contains { $0.name == "Настоящий файл" })
        // реальный кейс из приманки недоступен
        do { _ = try await repo.listFiles(caseID: real.vaultCase.id); XCTFail() } catch {}
        // запись в приманку жива только в памяти
        let added = try await repo.addFile(caseID: cases[0].id, name: "Заметка", kind: .note, data: Data("x".utf8), note: nil, progress: { _ in })
        let opened = try await repo.openFile(id: added.id)
        XCTAssertEqual(opened, Data("x".utf8))
        // реальные данные на сервере не тронуты
        let serverFiles = try await api.files.list(caseId: real.vaultCase.id)
        XCTAssertEqual(serverFiles.count, 1)
        XCTAssertNotNil(keys.caseSecret(real.vaultCase.id))
        // настройки «под принуждением» в приманке не раскрываются
        let dEnabled = await repo.duressEnabled
        XCTAssertFalse(dEnabled)
        // событие ушло тихо
        try await Task.sleep(nanoseconds: 150_000_000)
        let events = await (api.securityEvents as? MockSecurityEventAPI)?.all() ?? []
        XCTAssertTrue(events.contains { $0.kind == .duressUnlock })
        // выход из приманки возвращает реальный режим
        try await repo.logout()
        _ = try await repo.login(identifier: "tester", password: "secret1")
        let back = try await repo.listCases()
        XCTAssertEqual(back.map(\.id), [real.vaultCase.id])
    }

    func testDecoyIgnoresAccountChanges() async throws {
        let (repo, _, _) = try await makeRepo()
        try await repo.setDuressPIN("483920")
        _ = await repo.unlockAppWithDuress(pin: "483920")
        let before = try await repo.updateBackupEmail("evil@example.com")
        XCTAssertNil(before.backupEmail)
        let m = try await repo.setMFA(enabled: true, method: .sms)
        XCTAssertNil(m)
    }

    // MARK: Поиск

    private func file(_ id: String, _ name: String, note: String? = nil, ocr: String? = nil, case cid: String = "c1") -> VaultFile {
        VaultFile(id: id, caseID: cid, name: name, kind: .pdf, bytes: 1, note: note, favorite: false, offline: false, createdAt: Date(), deletedAt: nil, ocr: ocr)
    }
    private func vcase(_ id: String, _ name: String, open: Bool = true) -> VaultCase {
        VaultCase(id: id, name: name, icon: .document, level: .standard, favorite: false, fileCount: 0, bytes: 0, isUnlocked: open, updatedAt: Date(), isRecoverable: true)
    }

    func testSearchRanksNameBeforeOCRAndIsDiacriticInsensitive() {
        let long = String(repeating: "слово ", count: 30) + "ПАСПОРТ гражданина" + String(repeating: " текст", count: 30)
        let hits = FileSearch.hits(query: "паспорт", sources: [(vcase("c1", "Документы"), [
            file("f1", "Скан договора", ocr: long),
            file("f2", "Мой Паспорт"),
            file("f3", "Чек")])])
        XCTAssertEqual(hits.map(\.fileId), ["f2", "f1"])
        XCTAssertFalse(hits[0].matchedInOCR)
        XCTAssertTrue(hits[1].matchedInOCR)
        let snip = try? XCTUnwrap(hits[1].snippet)
        XCTAssertTrue(snip?.contains("ПАСПОРТ") ?? false)
        XCTAssertLessThanOrEqual(snip?.count ?? 999, 40 + "ПАСПОРТ".count + 40 + 2)
        XCTAssertTrue(snip?.hasPrefix("…") ?? false)
        // ё/е и регистр
        let yo = FileSearch.hits(query: "ЕЛКА", sources: [(vcase("c1", "К"), [file("f", "Ёлка.pdf")])])
        XCTAssertEqual(yo.count, 1)
        XCTAssertTrue(FileSearch.hits(query: "  ", sources: [(vcase("c1", "К"), [file("f", "a")])]).isEmpty)
    }

    func testSearchAllOnlyOpenCasesAndCountsLocked() async throws {
        let (repo, _, _) = try await makeRepo()
        let a = try await repo.createCase(name: "Открытый", icon: .document, level: .standard)
        let b = try await repo.createCase(name: "Закрытый", icon: .document, level: .standard)
        _ = try await repo.addFile(caseID: a.vaultCase.id, name: "Договор аренды", kind: .pdf, data: Data("1".utf8), note: "подпись", ocrText: "Арендатор обязуется", progress: { _ in })
        _ = try await repo.addFile(caseID: b.vaultCase.id, name: "Аренда секрет", kind: .pdf, data: Data("2".utf8), note: nil, ocrText: nil, progress: { _ in })
        await repo.lockCase(id: b.vaultCase.id)
        _ = try await repo.listCases()
        let hits = await repo.searchAll(query: "аренд")
        XCTAssertEqual(hits.map(\.fileName), ["Договор аренды"])
        XCTAssertTrue(hits[0].caseIsUnlocked)
        let ocrHits = await repo.searchAll(query: "АРЕНДАТОР")
        XCTAssertEqual(ocrHits.first?.matchedInOCR, true)
        let skipped = await repo.searchSkippedLockedCount()
        XCTAssertEqual(skipped, 1)
    }

    // MARK: Локальное хранение

    func testSessionAndCasesCacheSurviveAndLogoutClears() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lokey-sec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = InMemoryKeyStore()
        let (repo, api, _) = try await makeRepo(keys: keys, persistence: true, dir: dir)
        _ = try await repo.createCase(name: "В кэше", icon: .key, level: .standard)
        _ = try await repo.listCases()
        // «перезапуск»: новый репозиторий, тот же Keychain и каталог
        let repo2 = VaultRepositoryImpl(api: api, keys: keys, seedDemo: false, persistence: true, persistenceDirectory: dir)
        let snap = try await XCTUnwrapAsync(await repo2.offlineSnapshot())
        XCTAssertEqual(snap.email, "tester@demo.lokey")
        let cached = await repo2.cachedCases(for: snap)
        XCTAssertEqual(cached.map(\.name), ["В кэше"])
        XCTAssertFalse(cached[0].isUnlocked)
        let hs = await repo2.makeHistoryStore()
        XCTAssertNotNil(hs)
        // выход стирает снимок и кэш
        await repo.clearLocalPersistence(wipeChats: false)
        let gone = await repo2.offlineSnapshot()
        XCTAssertNil(gone)
        let cachedAfter = await repo2.cachedCases(for: snap)
        XCTAssertTrue(cachedAfter.isEmpty)
    }

    private func XCTUnwrapAsync<T>(_ v: @autoclosure () async -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        guard let x = await v() else { XCTFail("nil", file: file, line: line); throw CancellationError() }
        return x
    }
}
