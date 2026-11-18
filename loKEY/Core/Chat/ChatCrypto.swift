import Foundation
import CryptoKit

/// Криптография чата (клиентская). Схема «статический DH + симметричное храповое колесо»:
///  • identity = X25519; ключи цепочек = HKDF(DH(my, their)), по цепочке на каждое направление;
///  • каждое сообщение — новый ключ: mk = HMAC(ck, 0x01), ck' = HMAC(ck, 0x02), старые ключи стираются → forward secrecy;
///  • шифрование AES-256-GCM, AAD = [отправитель | получатель | счётчик]; пропущенные сообщения — до 200 ключей.
/// НЕ даёт post-compromise security (нет DH-храповика) и не заменяет аудит. Подробно — Docs/CHAT.md.
enum ChatCrypto {
    static let version = 1
    static let maxSkip = 200

    struct SessionState: Codable, Equatable {
        var sendKey: Data
        var sendIndex: UInt32
        var recvKey: Data
        var recvIndex: UInt32
        var skipped: [UInt32: Data]
    }

    enum Failure: Error { case badKey, malformed, tooFarAhead, replay, authFailed }

    static func generateIdentity() -> Curve25519.KeyAgreement.PrivateKey { .init() }

    /// Стартовое состояние. Обе стороны получают зеркальные цепочки: у кого публичный ключ «меньше», тот шлёт по первой.
    static func makeSession(mine: Curve25519.KeyAgreement.PrivateKey, theirPublic: Data) throws -> SessionState {
        guard let their = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirPublic) else { throw Failure.badKey }
        let secret = try mine.sharedSecretFromKeyAgreement(with: their)
        let myPub = mine.publicKey.rawRepresentation
        let (lo, hi) = myPub.lexicographicallyPrecedes(theirPublic) ? (myPub, theirPublic) : (theirPublic, myPub)
        let salt = Data(SHA256.hash(data: lo + hi))
        let okm = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("lokey.chat.v1".utf8), outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        let first = bytes.prefix(32), second = bytes.suffix(32)
        let iAmLow = myPub.lexicographicallyPrecedes(theirPublic)
        return SessionState(sendKey: Data(iAmLow ? first : second), sendIndex: 0,
                            recvKey: Data(iAmLow ? second : first), recvIndex: 0, skipped: [:])
    }

    private static func step(_ ck: Data) -> (mk: SymmetricKey, next: Data) {
        let key = SymmetricKey(data: ck)
        let mk = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: key)
        let next = HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: key)
        return (SymmetricKey(data: Data(mk)), Data(next))
    }

    private static func aad(from: String, to: String, n: UInt32) -> Data {
        var d = Data(from.utf8); d.append(0); d.append(contentsOf: Data(to.utf8)); d.append(0)
        withUnsafeBytes(of: n.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    static func seal(_ plain: Data, state: inout SessionState, from: String, to: String) throws -> Data {
        let n = state.sendIndex
        let (mk, next) = step(state.sendKey)
        let box = try AES.GCM.seal(plain, using: mk, authenticating: aad(from: from, to: to, n: n))
        state.sendKey = next; state.sendIndex = n &+ 1
        var out = Data(); withUnsafeBytes(of: n.bigEndian) { out.append(contentsOf: $0) }
        guard let combined = box.combined else { throw Failure.malformed }
        out.append(combined)
        return out
    }

    static func open(_ data: Data, state: inout SessionState, from: String, to: String) throws -> Data {
        guard data.count > 4 + 28 else { throw Failure.malformed }
        let n = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let body = data.dropFirst(4)
        let ad = aad(from: from, to: to, n: n)
        // пропущенное ранее сообщение
        if let key = state.skipped[n] {
            let plain = try decrypt(body, SymmetricKey(data: key), ad)
            state.skipped[n] = nil
            return plain
        }
        if n < state.recvIndex { throw Failure.replay }
        if n - state.recvIndex > UInt32(maxSkip) { throw Failure.tooFarAhead }
        var ck = state.recvKey, idx = state.recvIndex
        var newSkipped: [UInt32: Data] = [:]
        while idx < n {
            let (mk, next) = step(ck)
            newSkipped[idx] = mk.withUnsafeBytes { Data($0) }
            ck = next; idx += 1
        }
        let (mk, next) = step(ck)
        let plain = try decrypt(body, mk, ad)       // состояние меняем только после успешной проверки
        state.recvKey = next; state.recvIndex = n &+ 1
        for (k, v) in newSkipped { state.skipped[k] = v }
        if state.skipped.count > maxSkip * 2 { for k in state.skipped.keys.sorted().prefix(state.skipped.count - maxSkip) { state.skipped[k] = nil } }
        return plain
    }

    private static func decrypt(_ body: Data, _ key: SymmetricKey, _ ad: Data) throws -> Data {
        guard let box = try? AES.GCM.SealedBox(combined: body), let p = try? AES.GCM.open(box, using: key, authenticating: ad) else { throw Failure.authFailed }
        return p
    }

    /// 60 цифр кода безопасности: одинаковы у обоих собеседников, меняются при подмене любого ключа.
    static func safetyNumber(_ a: Data, _ b: Data) -> String {
        let (lo, hi) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        var digest = Data(SHA256.hash(data: Data("lokey.safety.v1".utf8) + lo + hi))
        digest += Data(SHA256.hash(data: digest))        // 64 байта
        var out = ""
        for g in 0..<12 {
            let chunk = digest[(g * 5)..<(g * 5 + 5)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            out += String(format: "%05d", Int(chunk % 100_000))
            if g < 11 { out += g % 4 == 3 ? "\n" : " " }
        }
        return out
    }
}
