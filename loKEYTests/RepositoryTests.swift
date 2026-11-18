import XCTest
@testable import loKEY

final class RepositoryTests: XCTestCase {
    private var repo: VaultRepositoryImpl!
    private var keys: InMemoryKeyStore!

    override func setUp() async throws {
        keys = InMemoryKeyStore()
        let api = MockBackend.makeServices(latency: 0...0)
        MockBackend.Hooks.setLatencyEnabled(false)
        repo = VaultRepositoryImpl(api: api, keys: keys, seedDemo: false)
        _ = try await repo.login(identifier: "tester", password: "secret1")
    }

    private func makeCase(_ name: String = "Тест") async throws -> NewCaseResult {
        try await repo.createCase(name: name, icon: .document, level: .standard)
    }

    private func add(_ caseID: String, _ text: String = "hello", name: String = "f.pdf") async throws -> VaultFile {
        try await repo.addFile(caseID: caseID, name: name, kind: .pdf, data: Data(text.utf8), note: nil, progress: { _ in })
    }

    func testCreateCase() async throws {
        let r = try await makeCase()
        XCTAssertTrue(r.vaultCase.isUnlocked)
        XCTAssertEqual(r.recoveryWords.count, 12)
        XCTAssertEqual(r.keyString.split(separator: "-").count, 8)
        XCTAssertEqual(r.vaultCase.id, r.vaultCase.id.lowercased())
        let list = try await repo.listCases()
        XCTAssertEqual(list.map(\.name), ["Тест"])
        XCTAssertTrue(list[0].isRecoverable)
    }

    func testLoginFlows() async throws {
        let api = MockBackend.makeServices(latency: 0...0)
        let r = VaultRepositoryImpl(api: api, keys: InMemoryKeyStore(), seedDemo: false)
        do { _ = try await r.login(identifier: "x", password: "wrong-password"); XCTFail() } catch { XCTAssertEqual(error as? VaultError, .notAuthenticated) }
        guard case .mfaRequired(let ch) = try await r.login(identifier: "mfa-user", password: "secret1") else { return XCTFail() }
        do { _ = try await r.verifyMFA(challengeId: ch, code: "000000"); XCTFail() } catch { XCTAssertEqual(error as? VaultError, .mfaInvalid) }
        _ = try await r.verifyMFA(challengeId: ch, code: "123456")
    }

    func testAddAndOpenFile() async throws {
        let c = try await makeCase()
        var stages: [UploadProgress.Stage] = []
        let lock = NSLock()
        let f = try await repo.addFile(caseID: c.vaultCase.id, name: "Паспорт", kind: .pdf, data: Data("содержимое".utf8), note: "n") { p in
            lock.lock(); if stages.last != p.stage { stages.append(p.stage) }; lock.unlock()
        }
        XCTAssertEqual(stages, [.encrypting, .uploading, .verifying, .done])
        XCTAssertEqual(f.name, "Паспорт")
        let data = try await repo.openFile(id: f.id)
        XCTAssertEqual(String(data: data, encoding: .utf8), "содержимое")
        let files = try await repo.listFiles(caseID: c.vaultCase.id)
        XCTAssertEqual(files.map(\.name), ["Паспорт"])
        XCTAssertEqual(files.first?.note, "n")
    }

    func testLockedCaseRejectsFiles() async throws {
        let c = try await makeCase()
        await repo.lockCase(id: c.vaultCase.id)
        do { _ = try await repo.listFiles(caseID: c.vaultCase.id); XCTFail() } catch { XCTAssertEqual(error as? VaultError, .notUnlocked) }
    }

    func testUnlockWithKeyStringAndFile() async throws {
        let c = try await makeCase()
        let id = c.vaultCase.id
        await repo.lockAll()
        try await repo.unlockCase(id: id, method: .keyString(c.keyString.lowercased()))
        await repo.lockCase(id: id)
        try await repo.unlockCase(id: id, method: .keyFile(c.keyFileData))
        do { try await repo.unlockCase(id: id, method: .keyString("abc")); XCTFail() } catch { XCTAssertEqual(error as? VaultError, .invalidKeyFormat) }
    }

    func testBiometricsUnlock() async throws {
        let c = try await makeCase()
        await repo.lockAll()
        try await repo.unlockCase(id: c.vaultCase.id, method: .biometrics)
        let list = try await repo.listCases()
        XCTAssertTrue(list[0].isUnlocked)
    }

    func testWrongKeyFiveTimesLocksOut() async throws {
        let c = try await makeCase()
        let id = c.vaultCase.id
        await repo.lockAll()
        let wrong = KeyFormat.format(KeyFormat.generateSecret())
        for left in [4, 3, 2, 1] {
            do { try await repo.unlockCase(id: id, method: .keyString(wrong)); XCTFail() }
            catch { XCTAssertEqual(error as? VaultError, .wrongKey(attemptsLeft: left)) }
        }
        do { try await repo.unlockCase(id: id, method: .keyString(wrong)); XCTFail() }
        catch { guard case .lockedOut(let until)? = error as? VaultError else { return XCTFail() }; XCTAssertGreaterThan(until, Date().addingTimeInterval(200)) }
        let st = await repo.unlockStatus(caseID: id)
        XCTAssertEqual(st.attemptsLeft, 0); XCTAssertNotNil(st.lockedUntil)
        // даже верный ключ в блокировке не принимается
        do { try await repo.unlockCase(id: id, method: .keyString(c.keyString)); XCTFail() }
        catch { guard case .lockedOut? = error as? VaultError else { return XCTFail() } }
    }

    func testSuccessResetsAttempts() async throws {
        let c = try await makeCase()
        await repo.lockAll()
        do { try await repo.unlockCase(id: c.vaultCase.id, method: .keyString(KeyFormat.format(KeyFormat.generateSecret()))) } catch {}
        let before = await repo.unlockStatus(caseID: c.vaultCase.id)
        XCTAssertEqual(before.attemptsLeft, 4)
        try await repo.unlockCase(id: c.vaultCase.id, method: .keyString(c.keyString))
        let after = await repo.unlockStatus(caseID: c.vaultCase.id)
        XCTAssertEqual(after.attemptsLeft, 5)
    }

    func testTamperedBlobFailsIntegrity() async throws {
        let c = try await makeCase()
        let f = try await add(c.vaultCase.id, "important data to protect")
        await MockBackend.Hooks.tamper(fileId: f.id)
        do { _ = try await repo.openFile(id: f.id); XCTFail() }
        catch { XCTAssertEqual(error as? VaultError, .integrityFailed(fileID: f.id)) }
    }

    func testMoveFiles() async throws {
        let a = try await makeCase("A"), b = try await makeCase("B")
        let f = try await add(a.vaultCase.id, "moving", name: "m.pdf")
        try await repo.moveFiles(ids: [f.id], toCaseID: b.vaultCase.id)
        let inA = try await repo.listFiles(caseID: a.vaultCase.id)
        let inB = try await repo.listFiles(caseID: b.vaultCase.id)
        XCTAssertTrue(inA.isEmpty)
        XCTAssertEqual(inB.map(\.name), ["m.pdf"])
        let data = try await repo.openFile(id: inB[0].id)
        XCTAssertEqual(String(data: data, encoding: .utf8), "moving")
        let trash = try await repo.listTrash()
        XCTAssertEqual(trash.count, 1)
    }

    func testMoveRequiresBothUnlocked() async throws {
        let a = try await makeCase("A"), b = try await makeCase("B")
        let f = try await add(a.vaultCase.id)
        await repo.lockCase(id: b.vaultCase.id)
        do { try await repo.moveFiles(ids: [f.id], toCaseID: b.vaultCase.id); XCTFail() } catch { XCTAssertEqual(error as? VaultError, .notUnlocked) }
    }

    func testTrashRestorePurge() async throws {
        let c = try await makeCase()
        let f = try await add(c.vaultCase.id)
        try await repo.trashFiles(ids: [f.id])
        let listed = try await repo.listFiles(caseID: c.vaultCase.id)
        XCTAssertTrue(listed.isEmpty)
        var trash = try await repo.listTrash()
        XCTAssertEqual(trash.map(\.id), [f.id]); XCTAssertNotNil(trash[0].deletedAt)
        XCTAssertEqual(trash[0].name, "f.pdf")
        try await repo.restoreFile(id: f.id)
        let restored = try await repo.listFiles(caseID: c.vaultCase.id)
        XCTAssertEqual(restored.count, 1)
        try await repo.trashFiles(ids: [f.id])
        try await repo.purgeFile(id: f.id)
        trash = try await repo.listTrash()
        XCTAssertTrue(trash.isEmpty)
    }

    func testQuotaExceeded() async throws {
        let c = try await makeCase()
        await MockBackend.Hooks.setLimit(bytes: 100)
        do { _ = try await add(c.vaultCase.id, String(repeating: "x", count: 200)); XCTFail() }
        catch { XCTAssertEqual(error as? VaultError, .quotaExceeded(limitBytes: 100)) }
    }

    func testUpdateFileAndFavorites() async throws {
        let c = try await makeCase()
        let f = try await add(c.vaultCase.id)
        let u = try await repo.updateFile(id: f.id, name: "new.pdf", note: "заметка", favorite: true, offline: true)
        XCTAssertEqual(u.name, "new.pdf"); XCTAssertTrue(u.favorite); XCTAssertTrue(u.offline)
        let fav = try await repo.favoriteFiles()
        XCTAssertEqual(fav.map(\.id), [f.id])
        await repo.lockAll()
        let favLocked = try await repo.favoriteFiles()
        XCTAssertTrue(favLocked.isEmpty)
    }

    func testRecoveryByWords() async throws {
        let c = try await makeCase()
        await repo.lockAll()
        do { try await repo.recoverCase(id: c.vaultCase.id, words: Array(c.recoveryWords.reversed()) + ["дом"]); XCTFail() }
        catch { XCTAssertEqual(error as? VaultError, .recoveryFailed) }
        try await repo.recoverCase(id: c.vaultCase.id, words: c.recoveryWords)
        let list = try await repo.listCases()
        XCTAssertTrue(list[0].isUnlocked)
    }

    func testUpdateAndPurgeCase() async throws {
        let c = try await makeCase()
        let u = try await repo.updateCase(id: c.vaultCase.id, name: "Новое", icon: .wallet, level: .critical, favorite: true)
        XCTAssertEqual(u.name, "Новое"); XCTAssertEqual(u.level, .critical); XCTAssertTrue(u.favorite)
        try await repo.purgeCase(id: c.vaultCase.id)
        let list = try await repo.listCases()
        XCTAssertTrue(list.isEmpty)
        XCTAssertNil(keys.caseSecret(c.vaultCase.id))
    }

    func testStorageAndAudit() async throws {
        let c = try await makeCase("Док")
        _ = try await add(c.vaultCase.id)
        await repo.lockCase(id: c.vaultCase.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        let u = try await repo.storageUsage()
        XCTAssertGreaterThan(u.usedBytes, 0)
        XCTAssertEqual(u.perCase.first?.name, "Док")
        let log = try await repo.auditLog(limit: 20)
        XCTAssertTrue(log.contains { $0.kind == .caseCreated && $0.caseName == "Док" })
    }
}
