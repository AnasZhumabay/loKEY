import XCTest
import CryptoKit
@testable import loKEY

final class CryptoTests: XCTestCase {
    func testSealOpenRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let plain = Data("секретный файл".utf8)
        let sealed = try CryptoService.seal(plain, key: key)
        XCTAssertEqual(sealed.count, plain.count + CryptoService.sealOverhead)
        XCTAssertEqual(try CryptoService.open(sealed, key: key), plain)
    }

    func testTamperedCiphertextFails() throws {
        let key = SymmetricKey(size: .bits256)
        var sealed = try CryptoService.seal(Data(repeating: 7, count: 64), key: key)
        sealed[sealed.count / 2] ^= 0x01
        XCTAssertThrowsError(try CryptoService.open(sealed, key: key))
    }

    func testWrongKeyFails() throws {
        let sealed = try CryptoService.seal(Data([1, 2, 3]), key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try CryptoService.open(sealed, key: SymmetricKey(size: .bits256)))
    }

    func testHKDFDeterministic() {
        let secret = Data(repeating: 9, count: 20)
        let a = CryptoService.caseKey(fromSecret: secret).withUnsafeBytes { Data($0) }
        let b = CryptoService.caseKey(fromSecret: secret).withUnsafeBytes { Data($0) }
        let c = CryptoService.caseKey(fromSecret: Data(repeating: 8, count: 20)).withUnsafeBytes { Data($0) }
        XCTAssertEqual(a, b); XCTAssertEqual(a.count, 32); XCTAssertNotEqual(a, c)
    }

    func testSHA256Hex() {
        XCTAssertEqual(CryptoService.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(CryptoService.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testKeyFormatRoundTrip() throws {
        let secret = KeyFormat.generateSecret()
        let s = KeyFormat.format(secret)
        XCTAssertEqual(s.count, 39)
        XCTAssertEqual(s.split(separator: "-").count, 8)
        XCTAssertTrue(s.split(separator: "-").allSatisfy { $0.count == 4 })
        XCTAssertFalse(s.contains(where: { "ILOU".contains($0) }))
        XCTAssertEqual(try KeyFormat.parse(s), secret)
    }

    func testKeyParseIsTolerant() throws {
        let secret = KeyFormat.generateSecret()
        let s = KeyFormat.format(secret)
        XCTAssertEqual(try KeyFormat.parse(s.lowercased()), secret)
        XCTAssertEqual(try KeyFormat.parse(s.replacingOccurrences(of: "-", with: " ")), secret)
        XCTAssertEqual(try KeyFormat.parse("  " + s.replacingOccurrences(of: "-", with: "") + " "), secret)
        // O→0, I/L→1
        XCTAssertEqual(try KeyFormat.parse("OOOO-0000-1111-IIII-LLLL-1111-0000-OOOO"), try KeyFormat.parse("0000-0000-1111-1111-1111-1111-0000-0000"))
    }

    func testKeyParseRejectsGarbage() {
        for bad in ["", "ABC", "7F3K-QX92", String(repeating: "U", count: 32), String(repeating: "?", count: 32), "7F3K-QX92-1M8D-A41Z-H6TP-2WRC-9VBN-E05J-AAAA"] {
            XCTAssertThrowsError(try KeyFormat.parse(bad)) { XCTAssertEqual($0 as? VaultError, .invalidKeyFormat) }
        }
    }

    func testKeyFile() throws {
        let secret = KeyFormat.generateSecret()
        let data = KeyFormat.keyFileData(caseID: "abc", secret: secret)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["case"] as? String, "abc")
        let parsed = try KeyFormat.parseKeyFile(data)
        XCTAssertEqual(parsed.caseID, "abc"); XCTAssertEqual(parsed.secret, secret)
        XCTAssertThrowsError(try KeyFormat.parseKeyFile(Data("not json".utf8)))
    }

    func testRecoveryWordsList() {
        XCTAssertEqual(RecoveryWords.list.count, 256)
        XCTAssertEqual(Set(RecoveryWords.list).count, 256)
        XCTAssertEqual(RecoveryWords.generate().count, 12)
    }

    func testRecoveryWrapUnwrap() throws {
        let secret = KeyFormat.generateSecret()
        let words = RecoveryWords.generate()
        let wrapped = try CryptoService.wrapSecret(secret, words: words)
        XCTAssertEqual(try CryptoService.unwrapSecret(wrapped, words: words), secret)
        XCTAssertEqual(try CryptoService.unwrapSecret(wrapped, words: words.map { $0.uppercased() }), secret)
        var other = words; other[0] = RecoveryWords.list.first { $0 != words[0] } ?? "x"
        XCTAssertThrowsError(try CryptoService.unwrapSecret(wrapped, words: other))
    }

    func testKeyCheckDiffersPerKey() {
        let a = CryptoService.keyCheck(for: CryptoService.caseKey(fromSecret: Data(repeating: 1, count: 20)))
        let b = CryptoService.keyCheck(for: CryptoService.caseKey(fromSecret: Data(repeating: 2, count: 20)))
        XCTAssertNotEqual(a, b); XCTAssertEqual(a.count, 64)
    }

    func testInMemoryKeyStore() throws {
        let ks = InMemoryKeyStore()
        let k1 = try ks.vaultKey(accountID: "u1")
        XCTAssertEqual(k1.withUnsafeBytes { Data($0) }, try ks.vaultKey(accountID: "u1").withUnsafeBytes { Data($0) })
        try ks.setCaseSecret(Data([1]), caseID: "c"); XCTAssertEqual(ks.caseSecret("c"), Data([1]))
        ks.removeCaseSecret("c"); XCTAssertNil(ks.caseSecret("c"))
    }
}
