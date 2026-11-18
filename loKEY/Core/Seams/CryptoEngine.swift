// ═══════════════════════════════════════════════════════════════════════════
//  SEAM · CryptoEngine — подменяемый движок E2EE-чата (клиентский, бэкенд не нужен)
//
//  Как подключить libsignal / MLS / другой движок:
//   1. Создайте `struct SignalCryptoEngine: CryptoEngine` (или MLS…) в этой папке.
//   2. Состояние сессии для приложения — ПРОЗРАЧНЫЕ байты (`Data`): движок сам
//      сериализует своё состояние (ratchet, ключи группы) и принимает/возвращает его.
//      Приложение лишь хранит эти байты (через HistoryStore/KeyStore).
//   3. Для групп верните `supportsGroups = true` и добавьте свои методы в расширение
//      (сейчас групповой протокол в этом seam не описан — это задел).
//   4. Замените `BuiltinCryptoEngine()` на свой движок там, где собирается AppEnvironment.
//  `name` попадает в метаданные, чтобы при смене движка старые сессии можно было мигрировать.
// ═══════════════════════════════════════════════════════════════════════════
import Foundation
import CryptoKit

/// Пара ключей личности в виде байтов (приватный хранит KeyStore, наружу не логируется).
struct CryptoIdentity: Equatable, Sendable {
    var privateKey: Data
    var publicKey: Data
}

enum CryptoEngineError: Error, Equatable, Sendable {
    case badKey, badSession, malformed, replay, authFailed
}

protocol CryptoEngine: Sendable {
    var name: String { get }
    var supportsGroups: Bool { get }

    func generateIdentity() -> CryptoIdentity
    /// Состояние сессии (непрозрачные байты) из своего приватного ключа и публичного ключа собеседника.
    func establishSession(identity: CryptoIdentity, peerPublic: Data) throws -> Data
    /// Шифрует; AAD связывает (from, to). Возвращает шифртекст и ОБНОВЛЁННОЕ состояние сессии.
    func seal(_ plain: Data, session: Data, from: String, to: String) throws -> (ciphertext: Data, session: Data)
    /// Расшифровывает; состояние меняется только при успехе.
    func open(_ ciphertext: Data, session: Data, from: String, to: String) throws -> (plain: Data, session: Data)
    func safetyNumber(mine: Data, theirs: Data) -> String
}

/// Встроенный движок: тонкая обёртка над статическим `ChatCrypto` (X25519 + симметричное храповое колесо + AES-GCM).
struct BuiltinCryptoEngine: CryptoEngine {
    var name: String { "builtin-x25519-ratchet-v\(ChatCrypto.version)" }
    var supportsGroups: Bool { false }

    init() {}

    func generateIdentity() -> CryptoIdentity {
        let k = ChatCrypto.generateIdentity()
        return CryptoIdentity(privateKey: k.rawRepresentation, publicKey: k.publicKey.rawRepresentation)
    }

    func establishSession(identity: CryptoIdentity, peerPublic: Data) throws -> Data {
        guard let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identity.privateKey) else { throw CryptoEngineError.badKey }
        do {
            let state = try ChatCrypto.makeSession(mine: priv, theirPublic: peerPublic)
            return try JSONEncoder().encode(state)
        } catch { throw CryptoEngineError.badKey }
    }

    func seal(_ plain: Data, session: Data, from: String, to: String) throws -> (ciphertext: Data, session: Data) {
        var st = try decode(session)
        do {
            let ct = try ChatCrypto.seal(plain, state: &st, from: from, to: to)
            return (ct, try JSONEncoder().encode(st))
        } catch { throw CryptoEngineError.authFailed }
    }

    func open(_ ciphertext: Data, session: Data, from: String, to: String) throws -> (plain: Data, session: Data) {
        var st = try decode(session)
        do {
            let p = try ChatCrypto.open(ciphertext, state: &st, from: from, to: to)
            return (p, try JSONEncoder().encode(st))
        } catch let e as ChatCrypto.Failure {
            switch e {
            case .replay: throw CryptoEngineError.replay
            case .malformed, .tooFarAhead: throw CryptoEngineError.malformed
            case .badKey: throw CryptoEngineError.badKey
            case .authFailed: throw CryptoEngineError.authFailed
            }
        } catch { throw CryptoEngineError.authFailed }
    }

    func safetyNumber(mine: Data, theirs: Data) -> String { ChatCrypto.safetyNumber(mine, theirs) }

    private func decode(_ d: Data) throws -> ChatCrypto.SessionState {
        guard let s = try? JSONDecoder().decode(ChatCrypto.SessionState.self, from: d) else { throw CryptoEngineError.badSession }
        return s
    }
}
