import XCTest
import CryptoKit
@testable import loKEY

final class SeamsTests: XCTestCase {
    private var tmp: URL!
    private let key = Data(repeating: 7, count: 32)

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("seams-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func allFiles() -> [URL] {
        let e = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: [.isRegularFileKey])
        return (e?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    func testHistoryRoundTripAndWipe() async throws {
        let s = try FileHistoryStore(key: key, baseDirectory: tmp)
        try await s.save(accountId: "a1", contactId: "bob", Data("привет".utf8))
        try await s.save(accountId: "a1", contactId: "eve", Data([1, 2, 3]))
        let loaded = try await s.load(accountId: "a1")
        XCTAssertEqual(loaded["bob"], Data("привет".utf8))
        XCTAssertEqual(loaded.count, 2)
        // в файле нет открытого текста
        for f in allFiles() { XCTAssertNil(try Data(contentsOf: f).range(of: Data("привет".utf8))) }
        let other = try await s.load(accountId: "a2")
        XCTAssertTrue(other.isEmpty)
        try await s.wipe(accountId: "a1")
        let after = try await s.load(accountId: "a1")
        XCTAssertTrue(after.isEmpty)
    }

    func testHistoryTamperAndWrongKey() async throws {
        let s = try FileHistoryStore(key: key, baseDirectory: tmp)
        try await s.save(accountId: "a1", contactId: "bob", Data("x".utf8))
        let f = try XCTUnwrap(allFiles().first)
        var raw = try Data(contentsOf: f); raw[raw.count / 2] ^= 0xFF; try raw.write(to: f)
        // Битый файл пропускается (не роняет всю загрузку и не ведёт к перезаписи остальных): правка пункта 7 проверки.
        let tampered = try await s.load(accountId: "a1")
        XCTAssertTrue(tampered.isEmpty)
        let wrong = try FileHistoryStore(key: Data(repeating: 9, count: 32), baseDirectory: tmp)
        let wrongLoaded = try await wrong.load(accountId: "a1")
        XCTAssertTrue(wrongLoaded.isEmpty)
    }

    func testBadKeyLength() {
        XCTAssertThrowsError(try FileHistoryStore(key: Data(count: 16), baseDirectory: tmp))
    }

    func testSessionPersistence() throws {
        let p = try FileSessionPersistence(key: key, baseDirectory: tmp)
        XCTAssertNil(try p.load())
        let snap = AccountSnapshot(accountId: "a1", email: "a@b.c", username: "anna", savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try p.save(snap)
        XCTAssertEqual(try p.load(), snap)
        let f = try XCTUnwrap(allFiles().first)
        var raw = try Data(contentsOf: f); raw[raw.count - 1] ^= 1; try raw.write(to: f)
        XCTAssertThrowsError(try p.load())
        try p.clear()
        XCTAssertNil(try p.load())
    }

    func testCasesCache() throws {
        let c = try FileCasesCache(key: key, baseDirectory: tmp)
        let raw = try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CaseRecordDTO", withExtension: "json")))
        let rec = try LKCoding.decoder.decode(CaseRecordDTO.self, from: raw)
        try c.save([rec], accountId: "a1")
        XCTAssertEqual(try c.load(accountId: "a1"), [rec])
        XCTAssertNil(try c.load(accountId: "a2"))
        let f = try XCTUnwrap(allFiles().first)
        var d = try Data(contentsOf: f); d[5] ^= 0x10; try d.write(to: f)
        XCTAssertThrowsError(try c.load(accountId: "a1"))
        try c.clear(accountId: "a1")
        XCTAssertNil(try c.load(accountId: "a1"))
    }

    func testBuiltinCryptoEngine() throws {
        let e = BuiltinCryptoEngine()
        let a = e.generateIdentity(), b = e.generateIdentity()
        var sa = try e.establishSession(identity: a, peerPublic: b.publicKey)
        var sb = try e.establishSession(identity: b, peerPublic: a.publicKey)
        let r1 = try e.seal(Data("hi".utf8), session: sa, from: "a", to: "b"); sa = r1.session
        let r2 = try e.open(r1.ciphertext, session: sb, from: "a", to: "b"); sb = r2.session
        XCTAssertEqual(r2.plain, Data("hi".utf8))
        XCTAssertThrowsError(try e.open(r1.ciphertext, session: sb, from: "a", to: "b"))
        XCTAssertEqual(e.safetyNumber(mine: a.publicKey, theirs: b.publicKey), e.safetyNumber(mine: b.publicKey, theirs: a.publicKey))
        XCTAssertFalse(e.supportsGroups)
    }

    func testLocalFolderBackupStore() async throws {
        let s = LocalFolderBackupStore(directory: tmp.appendingPathComponent("Backups"))
        try await s.write(name: "b1.lkb", data: Data([1, 2, 3]))
        let r = try await s.read(name: "b1.lkb")
        XCTAssertEqual(r, Data([1, 2, 3]))
        let l = try await s.list()
        XCTAssertEqual(l.map(\.name), ["b1.lkb"])
        do { try await s.write(name: "../x", data: Data()); XCTFail() } catch { XCTAssertEqual(error as? CloudBackupError, .invalidName) }
        try await s.delete(name: "b1.lkb")
        do { _ = try await s.read(name: "b1.lkb"); XCTFail() } catch { XCTAssertEqual(error as? CloudBackupError, .notFound) }
    }

    func testICloudStoreDoesNotCrash() async {
        let s = ICloudDriveBackupStore()
        _ = s.isAvailable
        _ = try? await s.list()   // без entitlement — .unavailable, без падения
    }

    func testMockV13Services() async throws {
        let svc = MockBackend.makeServices()
        let sec = svc.securityEvents
        try await sec.report(SecurityEventDTO(kind: .caseWiped, caseId: "c", at: Date(), deviceName: nil))
        let shared = svc.sharedCases
        try await shared.invite(caseId: "c", inviteeUserId: "u2", wrappedKeyForInvitee: Data([1]), role: .viewer)
        let inv = try await shared.listInvites()
        XCTAssertEqual(inv.count, 1)
        let m = try await shared.accept(inviteId: inv[0].id)
        XCTAssertEqual(m.status, .active)
        let info = BackupInfoDTO(id: "b", createdAt: Date(), sizeBytes: 1, sha256: "h", deviceName: "d", appVersion: "1", formatVersion: 1)
        do { try await svc.backup.upload(info: info, data: Data([1]), sha256: "bad", progress: { _ in }); XCTFail() } catch { XCTAssertEqual(error as? APIError, .integrityFailed) }
    }
}
