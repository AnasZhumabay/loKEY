import XCTest
@testable import loKEY

// MARK: - Тестовая «сеть» и вспомогательные типы

private actor FakeChatNet {
    var users: [String: ChatUserDTO] = [:]
    var box: [String: [ChatEnvelopeDTO]] = [:]
    var seen = Set<String>()
    func register(_ u: ChatUserDTO) { users[u.id] = u }
    func find(_ id: String) throws -> ChatUserDTO { guard let u = users[id] else { throw APIError.notFound }; return u }
    func send(_ e: ChatEnvelopeDTO) { if seen.insert(e.id).inserted { box[e.recipientId, default: []].append(e) } }
    func fetch(_ me: String) -> [ChatEnvelopeDTO] { box[me] ?? [] }
    func ack(_ me: String, _ ids: [String]) { box[me]?.removeAll { ids.contains($0.id) } }
}

private struct FakeChatAPI: ChatAPI {
    let net: FakeChatNet; let me: String; let username: String
    func registerIdentity(publicKey: Data) async throws -> ChatUserDTO {
        let u = ChatUserDTO(id: me, username: username, identityKey: publicKey); await net.register(u); return u
    }
    func findUser(id: String) async throws -> ChatUserDTO { try await net.find(id) }
    func send(_ envelope: ChatEnvelopeDTO) async throws { await net.send(envelope) }
    func fetch(limit: Int) async throws -> [ChatEnvelopeDTO] { await net.fetch(me) }
    func acknowledge(ids: [String]) async throws { await net.ack(me, ids) }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func set(_ d: Date) { lock.lock(); t = d; lock.unlock() }
}

private final class CountingEngine: CryptoEngine, @unchecked Sendable {
    private let inner = BuiltinCryptoEngine()
    private let lock = NSLock()
    private(set) var sealed = 0, opened = 0, established = 0
    var name: String { "counting" }
    var supportsGroups: Bool { false }
    func generateIdentity() -> CryptoIdentity { inner.generateIdentity() }
    func establishSession(identity: CryptoIdentity, peerPublic: Data) throws -> Data {
        lock.lock(); established += 1; lock.unlock(); return try inner.establishSession(identity: identity, peerPublic: peerPublic)
    }
    func seal(_ plain: Data, session: Data, from: String, to: String) throws -> (ciphertext: Data, session: Data) {
        lock.lock(); sealed += 1; lock.unlock(); return try inner.seal(plain, session: session, from: from, to: to)
    }
    func open(_ ciphertext: Data, session: Data, from: String, to: String) throws -> (plain: Data, session: Data) {
        lock.lock(); opened += 1; lock.unlock(); return try inner.open(ciphertext, session: session, from: from, to: to)
    }
    func safetyNumber(mine: Data, theirs: Data) -> String { inner.safetyNumber(mine: mine, theirs: theirs) }
}

final class ChatFeaturesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("chatfeat-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func makeRepo(_ id: String, net: FakeChatNet, clock: TestClock, keys: KeyStore = InMemoryKeyStore(), persist: Bool = false,
                          engine: CryptoEngine = BuiltinCryptoEngine(), store: HistoryStore? = nil) async throws -> ChatRepositoryImpl {
        let r = ChatRepositoryImpl(api: FakeChatAPI(net: net, me: id, username: id), keys: keys, persist: persist, engine: engine,
                                   historyStore: store, clock: { clock.now })
        try await r.configure(accountID: id, username: id)
        return r
    }

    /// Алиса (a) добавляет Боба (b) по приглашению; Боб подхватит Алису при первой синхронизации.
    private func makePair(clock: TestClock, engineA: CryptoEngine = BuiltinCryptoEngine()) async throws -> (ChatRepositoryImpl, ChatRepositoryImpl) {
        let net = FakeChatNet()
        let b = try await makeRepo("b", net: net, clock: clock)
        let a = try await makeRepo("a", net: net, clock: clock, engine: engineA)
        _ = try await a.addContact(invite: try await b.myInvite().string)
        return (a, b)
    }

    // MARK: Исчезающие сообщения

    func testSenderExpiryWithInjectedClock() async throws {
        let clock = TestClock(t0)
        let (a, _) = try await makePair(clock: clock)
        let m = try await a.send(text: "hi", attachment: nil, sticker: nil, replyTo: nil, options: .ttl(30), to: "b")
        XCTAssertEqual(m.expiresAt, t0.addingTimeInterval(30))
        let early = await a.expireDue(now: t0.addingTimeInterval(29))
        XCTAssertEqual(early, 0)
        let late = await a.expireDue(now: t0.addingTimeInterval(31))
        XCTAssertEqual(late, 1)
        let left = await a.messages(contactID: "b")
        XCTAssertTrue(left.isEmpty, "следов быть не должно")
    }

    func testReceiverTimerStartsOnFirstDisplay() async throws {
        let clock = TestClock(t0)
        let (a, b) = try await makePair(clock: clock)
        _ = try await a.send(text: "секрет", attachment: nil, sticker: nil, replyTo: nil, options: .ttl(30), to: "b")
        let added = await b.sync()
        XCTAssertEqual(added, 1)
        let got = await b.messages(contactID: "a")
        let m = try XCTUnwrap(got.first)
        XCTAssertEqual(m.ttl, 30)
        XCTAssertNil(m.expiresAt, "до показа таймер не идёт")
        let none = await b.expireDue(now: t0.addingTimeInterval(10_000))
        XCTAssertEqual(none, 0)
        clock.set(t0.addingTimeInterval(100))
        await b.messageShown(ids: [m.id], contactID: "a")
        let afterShown = await b.messages(contactID: "a")
        let shown = try XCTUnwrap(afterShown.first)
        XCTAssertEqual(shown.expiresAt, t0.addingTimeInterval(130))
        let beforeEnd = await b.expireDue(now: t0.addingTimeInterval(129))
        XCTAssertEqual(beforeEnd, 0)
        let afterEnd = await b.expireDue(now: t0.addingTimeInterval(131))
        XCTAssertEqual(afterEnd, 1)
    }

    func testChatDefaultTimerSyncsWithSystemLine() async throws {
        let clock = TestClock(t0)
        let (a, b) = try await makePair(clock: clock)
        await a.setDisappear(3600, contactID: "b")
        let mine = await a.messages(contactID: "b")
        XCTAssertEqual(mine.last?.system, .disappear(seconds: 3600))
        XCTAssertEqual(mine.last?.text, "Исчезающие сообщения: 1 час")
        _ = await b.sync()
        let theirs = await b.messages(contactID: "a")
        XCTAssertEqual(theirs.last?.system, .disappear(seconds: 3600))
        let c = await b.contact(id: "a")
        XCTAssertEqual(c?.disappearAfter, 3600)
        // обычное сообщение берёт таймер чата; override перекрывает
        let m1 = try await a.send(text: "x", attachment: nil, sticker: nil, replyTo: nil, to: "b")
        XCTAssertEqual(m1.ttl, 3600)
        let m2 = try await a.send(text: "y", attachment: nil, sticker: nil, replyTo: nil, options: .ttl(nil), to: "b")
        XCTAssertNil(m2.ttl)
        XCTAssertNil(m2.expiresAt)
    }

    // MARK: Постоянная история

    func testHistoryPersistsAndExpiryRemovesFromDisk() async throws {
        let clock = TestClock(t0)
        let key = Data(repeating: 7, count: 32)
        let store = try FileHistoryStore(key: key, baseDirectory: tmp)
        let keys = InMemoryKeyStore()
        let net = FakeChatNet()
        let b = try await makeRepo("b", net: net, clock: clock)
        let a1 = try await makeRepo("a", net: net, clock: clock, keys: keys, persist: true, store: store)
        _ = try await a1.addContact(invite: try await b.myInvite().string)
        _ = try await a1.send(text: "останется", attachment: nil, sticker: nil, replyTo: nil, to: "b")
        _ = try await a1.send(text: "исчезнет", attachment: nil, sticker: nil, replyTo: nil, options: .ttl(30), to: "b")

        // «перезапуск»: новый репозиторий, те же ключи и хранилище
        let a2 = try await makeRepo("a", net: net, clock: clock, keys: keys, persist: true, store: store)
        let restored = await a2.messages(contactID: "b")
        XCTAssertEqual(restored.map(\.text), ["останется", "исчезнет"])
        // на диске нет открытого текста
        let files = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        XCTAssertFalse(files.isEmpty)
        for f in files { XCTAssertNil(try Data(contentsOf: f).range(of: Data("останется".utf8))) }

        // истечение стирает и с диска
        clock.set(t0.addingTimeInterval(60))
        let n = await a2.expireDue(now: clock.now)
        XCTAssertEqual(n, 1)
        let a3 = try await makeRepo("a", net: net, clock: TestClock(t0), keys: keys, persist: true, store: store)
        let after = await a3.messages(contactID: "b")
        XCTAssertEqual(after.map(\.text), ["останется"])
    }

    func testHistoryStoreAttachedLaterOnSecondConfigure() async throws {
        let clock = TestClock(t0)
        let store = try FileHistoryStore(key: Data(repeating: 3, count: 32), baseDirectory: tmp)
        let keys = InMemoryKeyStore()
        let net = FakeChatNet()
        let b = try await makeRepo("b", net: net, clock: clock)
        let a = try await makeRepo("a", net: net, clock: clock, keys: keys, persist: true)
        _ = try await a.addContact(invite: try await b.myInvite().string)
        try await a.configure(accountID: "a", username: "a", historyStore: store)    // подключили хранилище уже после входа
        _ = try await a.send(text: "сохранить", attachment: nil, sticker: nil, replyTo: nil, to: "b")
        let loaded = try await store.load(accountId: "a")
        XCTAssertNotNil(loaded["b"])
    }

    // MARK: Не пересылать

    func testNoForwardPayloadEncoding() throws {
        var p = ChatPayload(t: "x"); p.nf = true
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(p), encoding: .utf8))
        XCTAssertTrue(json.contains("\"nf\":true"))
        XCTAssertEqual(try JSONDecoder().decode(ChatPayload.self, from: JSONEncoder().encode(p)).nf, true)
        // старый клиент: поля нет — значит, пересылать можно
        let old = Data(#"{"v":1,"t":"hi"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ChatPayload.self, from: old).nf)
        let plain = ChatPayload(t: "x")
        XCTAssertFalse(try XCTUnwrap(String(data: JSONEncoder().encode(plain), encoding: .utf8)).contains("nf"))
    }

    func testNoForwardEndToEnd() async throws {
        let clock = TestClock(t0)
        let (a, b) = try await makePair(clock: clock)
        let sent = try await a.send(text: "", attachment: ChatAttachment(name: "p.pdf", bytes: 3, data: Data([1, 2, 3])), sticker: nil, replyTo: nil,
                                    options: .ttl(nil, noForward: true), to: "b")
        XCTAssertTrue(sent.noForward); XCTAssertFalse(sent.canForward)
        _ = await b.sync()
        let received = await b.messages(contactID: "a")
        let got = try XCTUnwrap(received.first)
        XCTAssertTrue(got.noForward); XCTAssertFalse(got.canForward)
        XCTAssertEqual(got.attachment?.data, Data([1, 2, 3]))
    }

    // MARK: Сверка по QR

    func testVerifyCodecRoundTripAndCompare() throws {
        let sn = "12345 67890 11111 22222"
        let s = ChatVerifyCodec.encode(myID: "a", theirID: "b", safetyNumber: sn)
        XCTAssertTrue(s.hasPrefix("lokey://verify?"))
        let p = try XCTUnwrap(ChatVerifyCodec.decode(s))
        XCTAssertEqual(p.a, "a"); XCTAssertEqual(p.b, "b")
        XCTAssertEqual(ChatVerifyCodec.compare(p, myID: "b", theirID: "a", safetyNumber: sn), .match)
        // пробелы и переносы в коде не влияют
        XCTAssertEqual(ChatVerifyCodec.compare(p, myID: "b", theirID: "a", safetyNumber: "12345 67890\n11111 22222"), .match)
        XCTAssertEqual(ChatVerifyCodec.compare(p, myID: "b", theirID: "a", safetyNumber: "99999 67890 11111 22222"), .mismatch)
        XCTAssertEqual(ChatVerifyCodec.compare(p, myID: "b", theirID: "zzz", safetyNumber: sn), .wrongContact)
        XCTAssertNil(ChatVerifyCodec.decode("lokey://add?id=1&u=x&k=abc"))
        XCTAssertNil(ChatVerifyCodec.decode("https://example.com"))
        XCTAssertNil(ChatVerifyCodec.decode("lokey://verify?a=x&b=y"))
    }

    func testVerifyFlowMarksContactVerified() async throws {
        let clock = TestClock(t0)
        let (a, b) = try await makePair(clock: clock)
        _ = try await a.send(text: "hello", attachment: nil, sticker: nil, replyTo: nil, to: "b")
        _ = await b.sync()
        let before = await b.contact(id: "a")
        XCTAssertEqual(before?.verified, false)
        let qrOpt = await a.verificationQR(contactID: "b")
        let qrA = try XCTUnwrap(qrOpt)
        let ok = await b.verify(scanned: qrA, contactID: "a")
        XCTAssertEqual(ok, .match)
        let after = await b.contact(id: "a")
        XCTAssertEqual(after?.verified, true)
        // подделка хэша: отметка снимается
        var parsed = try XCTUnwrap(ChatVerifyCodec.decode(qrA)); parsed.h = "AAAA"
        var c = URLComponents(); c.scheme = "lokey"; c.host = "verify"
        c.queryItems = [.init(name: "a", value: parsed.a), .init(name: "b", value: parsed.b), .init(name: "h", value: parsed.h)]
        let forged = try XCTUnwrap(c.string)
        let bad = await b.verify(scanned: forged, contactID: "a")
        XCTAssertEqual(bad, .mismatch)
        let reset = await b.contact(id: "a")
        XCTAssertEqual(reset?.verified, false)
        let junk = await b.verify(scanned: "привет", contactID: "a")
        XCTAssertEqual(junk, .invalid)
    }

    // MARK: Движок шифрования

    func testInjectedEngineIsUsedAndWireFormatStaysCompatible() async throws {
        let clock = TestClock(t0)
        let engine = CountingEngine()
        let (a, b) = try await makePair(clock: clock, engineA: engine)    // у Боба встроенный движок
        XCTAssertGreaterThan(engine.established, 0)
        _ = try await a.send(text: "через движок", attachment: nil, sticker: nil, replyTo: nil, to: "b")
        XCTAssertEqual(engine.sealed, 1)
        _ = await b.sync()
        let got = await b.messages(contactID: "a")
        XCTAssertEqual(got.first?.text, "через движок")
    }

    // MARK: Группы (заглушка)

    func testGroupStubThrowsNotImplemented() async {
        let g = ChatGroupRepositoryStub()
        XCTAssertFalse(g.isSupported)
        do { _ = try await g.groups(); XCTFail("ожидали ошибку") } catch { XCTAssertEqual(error as? ChatError, .notImplemented) }
    }
}
