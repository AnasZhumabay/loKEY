// ═══════════════════════════════════════════════════════════════════════════
//  SEAM · локальное зашифрованное хранение (клиентское, бэкенд не нужен)
//  HistoryStore — история чата по собеседникам; SessionPersistence — снимок аккаунта;
//  CasesCache — офлайн-кэш кейсов. Файлы: AES-GCM(32-байтный ключ хранилища аккаунта),
//  атомарная запись, защита .completeUnlessOpen, исключены из бэкапа.
// ═══════════════════════════════════════════════════════════════════════════
import Foundation

/// Минимальный снимок аккаунта для быстрого старта без сети.
struct AccountSnapshot: Codable, Equatable, Sendable {
    var accountId: String
    var email: String
    var username: String
    var savedAt: Date
}

protocol HistoryStore: Sendable {
    /// contactId → непрозрачный блоб истории.
    func load(accountId: String) async throws -> [String: Data]
    func save(accountId: String, contactId: String, _ blob: Data) async throws
    func wipe(accountId: String) async throws
}

protocol SessionPersistence: Sendable {
    func save(_ snapshot: AccountSnapshot) throws
    func load() throws -> AccountSnapshot?
    func clear() throws
}

protocol CasesCache: Sendable {
    func save(_ cases: [CaseRecordDTO], accountId: String) throws
    func load(accountId: String) throws -> [CaseRecordDTO]?
    func clear(accountId: String) throws
}

// MARK: - Файловые реализации

struct FileHistoryStore: HistoryStore {
    private let box: EncryptedFileBox
    private struct Entry: Codable { var contactId: String; var blob: Data }

    init(key: Data, baseDirectory: URL? = nil) throws {
        box = try EncryptedFileBox(key: key, folder: "history", baseDirectory: baseDirectory)
    }
    private func dir(_ accountId: String) -> URL { box.root.appendingPathComponent(EncryptedFileBox.fileName(accountId), isDirectory: true) }
    private func aad(_ accountId: String) -> Data { Data("lokey.history|\(accountId)".utf8) }

    func load(accountId: String) async throws -> [String: Data] {
        let d = dir(accountId)
        guard let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { return [:] }
        var out: [String: Data] = [:]
        for f in files where f.pathExtension == "enc" {
            // Один битый файл не должен ронять всю загрузку (иначе следующая запись затёрла бы остальные): пропускаем его.
            guard let plain = (try? box.read(f, aad: aad(accountId))) ?? nil,
                  let e = try? JSONDecoder().decode(Entry.self, from: plain) else { continue }
            out[e.contactId] = e.blob
        }
        return out
    }

    func save(accountId: String, contactId: String, _ blob: Data) async throws {
        let plain = try JSONEncoder().encode(Entry(contactId: contactId, blob: blob))
        try box.write(plain, to: dir(accountId).appendingPathComponent(EncryptedFileBox.fileName(contactId) + ".enc"), aad: aad(accountId))
    }

    func wipe(accountId: String) async throws { box.remove(dir(accountId)) }
}

struct FileSessionPersistence: SessionPersistence {
    private let box: EncryptedFileBox
    private let aad = Data("lokey.session".utf8)
    init(key: Data, baseDirectory: URL? = nil) throws {
        box = try EncryptedFileBox(key: key, folder: "session", baseDirectory: baseDirectory)
    }
    private var url: URL { box.root.appendingPathComponent("account.enc") }

    func save(_ snapshot: AccountSnapshot) throws {
        try box.write(try LKCoding.encoder.encode(snapshot), to: url, aad: aad)
    }
    func load() throws -> AccountSnapshot? {
        guard let plain = try box.read(url, aad: aad) else { return nil }
        guard let s = try? LKCoding.decoder.decode(AccountSnapshot.self, from: plain) else { throw SeamStoreError.corrupted }
        return s
    }
    func clear() throws { box.remove(url) }
}

struct FileCasesCache: CasesCache {
    private let box: EncryptedFileBox
    init(key: Data, baseDirectory: URL? = nil) throws {
        box = try EncryptedFileBox(key: key, folder: "cases", baseDirectory: baseDirectory)
    }
    private func url(_ accountId: String) -> URL { box.root.appendingPathComponent(EncryptedFileBox.fileName(accountId) + ".enc") }
    private func aad(_ accountId: String) -> Data { Data("lokey.cases|\(accountId)".utf8) }

    func save(_ cases: [CaseRecordDTO], accountId: String) throws {
        try box.write(try LKCoding.encoder.encode(cases), to: url(accountId), aad: aad(accountId))
    }
    func load(accountId: String) throws -> [CaseRecordDTO]? {
        guard let plain = try box.read(url(accountId), aad: aad(accountId)) else { return nil }
        guard let c = try? LKCoding.decoder.decode([CaseRecordDTO].self, from: plain) else { throw SeamStoreError.corrupted }
        return c
    }
    func clear(accountId: String) throws { box.remove(url(accountId)) }
}
