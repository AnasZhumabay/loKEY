import Foundation
import CryptoKit
import CommonCrypto

enum CryptoError: Error, Equatable {
    case sealFailed
    case authenticationFailed
    case malformed
}

/// Вся криптография приложения: AES-256-GCM, HKDF-SHA256, SHA-256, PBKDF2-HMAC-SHA256.
enum CryptoService {
    static let caseKeyInfo = Data("lokey.case.v1".utf8)
    static let checkPrefix = Data("lokey.check".utf8)
    /// 12 байт nonce + 16 байт тега
    static let sealOverhead = 28

    static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    // MARK: AES-256-GCM (формат combined: nonce ‖ ciphertext ‖ tag)
    static func seal(_ plain: Data, key: SymmetricKey) throws -> Data {
        do {
            guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw CryptoError.sealFailed }
            return combined
        } catch { throw CryptoError.sealFailed }
    }

    static func open(_ combined: Data, key: SymmetricKey) throws -> Data {
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: key)
        } catch { throw CryptoError.authenticationFailed }
    }

    // MARK: Ключ кейса
    /// HKDF-SHA256 от 20-байтного секрета кейса → 32-байтный ключ.
    static func caseKey(fromSecret secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(),
                               info: caseKeyInfo, outputByteCount: 32)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256(«lokey.check» + ключ кейса), hex — лежит в CaseHeader.keyCheck.
    static func keyCheck(for key: SymmetricKey) -> String {
        sha256Hex(checkPrefix + key.withUnsafeBytes { Data($0) })
    }

    // MARK: PBKDF2 и обёртка секрета фразой восстановления
    static var defaultRounds: Int {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || env["LOKEY_FAST_KDF"] != nil {
            return 20_000
        }
        return 600_000
    }

    static func pbkdf2(password: Data, salt: Data, rounds: Int) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        password.withUnsafeBytes { pw in
            salt.withUnsafeBytes { s in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.bindMemory(to: Int8.self).baseAddress, password.count,
                    s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                    &out, out.count)
            }
        }
        return SymmetricKey(data: out)
    }

    private static func phraseData(_ words: [String]) -> Data {
        Data(RecoveryWords.normalize(words).joined(separator: " ").utf8)
    }

    /// Формат: salt(16) ‖ rounds(UInt32 BE) ‖ AES-GCM(secret). Сервер расшифровать не может.
    static func wrapSecret(_ secret: Data, words: [String], rounds: Int? = nil) throws -> Data {
        let r = rounds ?? defaultRounds
        let salt = randomBytes(16)
        let kek = pbkdf2(password: phraseData(words), salt: salt, rounds: r)
        var rb = UInt32(r).bigEndian
        return salt + Data(bytes: &rb, count: 4) + (try seal(secret, key: kek))
    }

    static func unwrapSecret(_ wrapped: Data, words: [String]) throws -> Data {
        guard wrapped.count > 20 + sealOverhead else { throw CryptoError.malformed }
        let salt = wrapped.prefix(16)
        let r = wrapped.subdata(in: 16..<20).reduce(0) { ($0 << 8) | Int($1) }
        guard (1_000...5_000_000).contains(r) else { throw CryptoError.malformed }
        let kek = pbkdf2(password: phraseData(words), salt: Data(salt), rounds: r)
        return try open(wrapped.dropFirst(20), key: kek)
    }
}
