// PIN «под принуждением»: хранится только как соль + PBKDF2-хэш, открытый PIN не сохраняется нигде.
import Foundation
import CryptoKit

struct DuressPINRecord: Codable, Equatable, Sendable {
    var salt: Data
    var rounds: Int
    var hash: Data
}

enum DuressPIN {
    static let length = SecurityRules.duressPINLength
    static let defaultRounds = 150_000

    static func isFormatValid(_ pin: String) -> Bool {
        SecurityRules.isDuressPINFormatValid(pin)
    }

    /// Слишком простые PIN (000000, 123456…) подобрать легче всего: такие не принимаем.
    static func isTooSimple(_ pin: String) -> Bool {
        let d = pin.compactMap { $0.wholeNumberValue }
        guard d.count == length else { return true }
        if Set(d).count == 1 { return true }
        let up = zip(d, d.dropFirst()).allSatisfy { $1 - $0 == 1 }
        let down = zip(d, d.dropFirst()).allSatisfy { $0 - $1 == 1 }
        return up || down
    }

    static func validate(_ pin: String) throws {
        guard isFormatValid(pin) else { throw VaultError.validation("PIN — ровно 6 цифр") }
        guard !isTooSimple(pin) else { throw VaultError.validation("Слишком простой PIN. Выберите другой") }
    }

    private static func derive(_ pin: String, salt: Data, rounds: Int) -> Data {
        CryptoService.pbkdf2(password: Data(pin.utf8), salt: salt, rounds: rounds).withUnsafeBytes { Data($0) }
    }

    static func make(pin: String, rounds: Int = defaultRounds) -> DuressPINRecord {
        let salt = CryptoService.randomBytes(16)
        return DuressPINRecord(salt: salt, rounds: rounds, hash: derive(pin, salt: salt, rounds: rounds))
    }

    static func verify(pin: String, record: DuressPINRecord) -> Bool {
        guard isFormatValid(pin), record.rounds > 0 else { return false }
        return constantTimeEqual(derive(pin, salt: record.salt, rounds: record.rounds), record.hash)
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

struct DuressPINStore: Sendable {
    let keys: KeyStore
    let rounds: Int
    init(keys: KeyStore, rounds: Int = DuressPIN.defaultRounds) { self.keys = keys; self.rounds = rounds }
    private var account: String { "duress.pin" }

    func load() -> DuressPINRecord? {
        guard let d = keys.read(account) else { return nil }
        return try? JSONDecoder().decode(DuressPINRecord.self, from: d)
    }
    func save(pin: String) throws {
        try DuressPIN.validate(pin)
        let d = try JSONEncoder().encode(DuressPIN.make(pin: pin, rounds: rounds))
        do { try keys.write(d, account: account) } catch { throw VaultError.server("Не удалось сохранить PIN в связке ключей") }
    }
    func clear() { keys.delete(account) }
    var isSet: Bool { load() != nil }
    func matches(_ pin: String) -> Bool { load().map { DuressPIN.verify(pin: pin, record: $0) } ?? false }
}
