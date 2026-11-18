import XCTest
import CryptoKit
@testable import loKEY

final class ChatCryptoTests: XCTestCase {
    private func pair() throws -> (ChatCrypto.SessionState, ChatCrypto.SessionState) {
        let a = ChatCrypto.generateIdentity(), b = ChatCrypto.generateIdentity()
        return (try ChatCrypto.makeSession(mine: a, theirPublic: b.publicKey.rawRepresentation),
                try ChatCrypto.makeSession(mine: b, theirPublic: a.publicKey.rawRepresentation))
    }

    func testRoundTripOutOfOrderAndReplay() throws {
        var (sa, sb) = try pair()
        let m1 = try ChatCrypto.seal(Data("one".utf8), state: &sa, from: "A", to: "B")
        let m2 = try ChatCrypto.seal(Data("two".utf8), state: &sa, from: "A", to: "B")
        let m3 = try ChatCrypto.seal(Data("three".utf8), state: &sa, from: "A", to: "B")
        XCTAssertEqual(String(data: try ChatCrypto.open(m1, state: &sb, from: "A", to: "B"), encoding: .utf8), "one")
        XCTAssertEqual(String(data: try ChatCrypto.open(m3, state: &sb, from: "A", to: "B"), encoding: .utf8), "three")
        XCTAssertEqual(String(data: try ChatCrypto.open(m2, state: &sb, from: "A", to: "B"), encoding: .utf8), "two")
        XCTAssertThrowsError(try ChatCrypto.open(m1, state: &sb, from: "A", to: "B"))
        XCTAssertThrowsError(try ChatCrypto.open(m2, state: &sb, from: "A", to: "B"))
    }

    func testTamperAndWrongSenderLeaveStateUntouched() throws {
        var (sa, sb) = try pair()
        let m = try ChatCrypto.seal(Data("x".utf8), state: &sa, from: "A", to: "B")
        var bad = m; bad[bad.count - 1] ^= 1
        let before = sb
        XCTAssertThrowsError(try ChatCrypto.open(bad, state: &sb, from: "A", to: "B"))
        XCTAssertEqual(sb, before)
        XCTAssertThrowsError(try ChatCrypto.open(m, state: &sb, from: "C", to: "B"))
        XCTAssertNoThrow(try ChatCrypto.open(m, state: &sb, from: "A", to: "B"))
    }

    func testReflectionAndStrangerFail() throws {
        var (sa, sb) = try pair()
        let m = try ChatCrypto.seal(Data("secret".utf8), state: &sa, from: "A", to: "B")
        XCTAssertThrowsError(try ChatCrypto.open(m, state: &sa, from: "B", to: "A"))   // отражение A->B обратно к A
        let stranger = ChatCrypto.generateIdentity()
        var se = try ChatCrypto.makeSession(mine: stranger, theirPublic: ChatCrypto.generateIdentity().publicKey.rawRepresentation)
        XCTAssertThrowsError(try ChatCrypto.open(m, state: &se, from: "A", to: "B"))
        _ = sb
    }

    func testSafetyNumberSymmetric() {
        let a = ChatCrypto.generateIdentity().publicKey.rawRepresentation, b = ChatCrypto.generateIdentity().publicKey.rawRepresentation
        XCTAssertEqual(ChatCrypto.safetyNumber(a, b), ChatCrypto.safetyNumber(b, a))
        XCTAssertNotEqual(ChatCrypto.safetyNumber(a, b), ChatCrypto.safetyNumber(a, ChatCrypto.generateIdentity().publicKey.rawRepresentation))
    }

    func testRecoveryWordsNormalizeNFC() {
        let composed = "\u{0439}"             // й
        let decomposed = "\u{0438}\u{0306}"   // и + бреве
        XCTAssertEqual(RecoveryWords.normalize([composed]), RecoveryWords.normalize([decomposed]))
    }

    func testKeyStoreLookupDistinguishesMissing() throws {
        let ks = InMemoryKeyStore()
        if case .missing = ks.lookup("nope") {} else { XCTFail("ожидали .missing") }
        _ = try ks.vaultKey(accountID: "acc")           // создаёт при отсутствии
        if case .found = ks.lookup("vault.key.acc") {} else { XCTFail("ожидали .found") }
    }
}
