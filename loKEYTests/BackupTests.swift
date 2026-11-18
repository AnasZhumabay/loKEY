import XCTest
@testable import loKEY

private final class FakeBackupAPI: BackupAPI, @unchecked Sendable {
    var store: [String: (BackupInfoDTO, Data)] = [:]
    func listBackups() async throws -> [BackupInfoDTO] { store.values.map(\.0) }
    func upload(info: BackupInfoDTO, data: Data, sha256: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.5); store[info.id] = (info, data); progress(1)
    }
    func download(id: String) async throws -> Data { store[id]?.1 ?? Data() }
    func delete(id: String) async throws { store[id] = nil }
}

final class BackupTests: XCTestCase {
    private var repo: VaultRepositoryImpl!
    private var tmp: URL!
    private var api: FakeBackupAPI!
    private var svc: BackupServiceImpl!
    private let pass = "correct horse battery 42"

    override func setUp() async throws {
        let services = MockBackend.makeServices(latency: 0...0)
        MockBackend.Hooks.setLatencyEnabled(false)
        repo = VaultRepositoryImpl(api: services, keys: InMemoryKeyStore(), seedDemo: false)
        _ = try await repo.login(identifier: "tester", password: "secret1")
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bk-\(UUID().uuidString)")
        api = FakeBackupAPI()
        let store = LocalFolderBackupStore(directory: tmp.appendingPathComponent("cloud"))
        svc = BackupServiceImpl(repo: repo, backupAPI: api, events: UnavailableSecurityEventAPI(), cloud: store,
                                local: LocalFolderBackupStore(directory: tmp.appendingPathComponent("local")),
                                kdfRounds: 1000, defaults: UserDefaults(suiteName: "bk-\(UUID().uuidString)") ?? .standard)
        let c = try await repo.createCase(name: "Паспорт", icon: .document, level: .standard)
        _ = try await repo.addFile(caseID: c.vaultCase.id, name: "a.pdf", kind: .pdf, data: Data("secret-body".utf8), note: "n", progress: { _ in })
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmp) }

    func testRoundTripLocal() async throws {
        let s = try await svc.createBackup(destination: .localFile, passphrase: pass) { _ in }
        let list = await svc.listBackups()
        XCTAssertEqual(list.count, 1)
        let r = try await svc.restore(s, passphrase: pass) { _ in }
        XCTAssertEqual(r.restoredCases, 1); XCTAssertEqual(r.restoredFiles, 1)
        let cases = try await repo.listCases()
        XCTAssertEqual(cases.count, 2)
        let lastDate = await svc.lastBackupDate
        XCTAssertNotNil(lastDate)
    }

    func testServerRoundTripAndDelete() async throws {
        let s = try await svc.createBackup(destination: .server, passphrase: pass) { _ in }
        let r = try await svc.restore(s, passphrase: pass) { _ in }
        XCTAssertEqual(r.restoredFiles, 1)
        try await svc.delete(s)
        XCTAssertTrue(api.store.isEmpty)
    }

    func testArchiveHasNoPlaintext() async throws {
        let s = try await svc.createBackup(destination: .localFile, passphrase: pass) { _ in }
        let data = try Data(contentsOf: XCTUnwrap(s.fileURL))
        XCTAssertNil(data.range(of: Data("secret-body".utf8)))
        XCTAssertNil(data.range(of: Data("Паспорт".utf8)))
    }

    func testWrongPassphraseFails() async throws {
        let s = try await svc.createBackup(destination: .localFile, passphrase: pass) { _ in }
        do { _ = try await svc.restore(s, passphrase: "wrong passphrase 123") { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? BackupError, .wrongPassphraseOrCorrupted) }
    }

    func testTamperedArchiveFails() async throws {
        let s = try await svc.createBackup(destination: .localFile, passphrase: pass) { _ in }
        var data = try Data(contentsOf: XCTUnwrap(s.fileURL))
        data[data.count - 5] ^= 0xFF
        do { _ = try await svc.restore(archive: data, passphrase: pass) { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? BackupError, .wrongPassphraseOrCorrupted) }
    }

    func testFormatVersionCheck() async throws {
        let s = try await svc.createBackup(destination: .localFile, passphrase: pass) { _ in }
        var data = try Data(contentsOf: XCTUnwrap(s.fileURL))
        data[5] = 9
        do { _ = try await svc.restore(archive: data, passphrase: pass) { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? BackupError, .unsupportedVersion(9)) }
        do { _ = try await svc.restore(archive: Data("nope".utf8), passphrase: pass) { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? BackupError, .notABackup) }
    }

    func testWeakPassphraseRejected() async {
        do { _ = try await svc.createBackup(destination: .localFile, passphrase: "short") { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? BackupError, .weakPassphrase) }
    }

    func testProgressMonotonic() async throws {
        let box = ProgressBox()
        _ = try await svc.createBackup(destination: .server, passphrase: pass) { box.add($0) }
        let v = box.values
        XCTAssertEqual(v.last, 1)
        XCTAssertEqual(v, v.sorted())
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let l = NSLock(); private var a: [Double] = []
    func add(_ v: Double) { l.lock(); a.append(v); l.unlock() }
    var values: [Double] { l.lock(); defer { l.unlock() }; return a }
}
