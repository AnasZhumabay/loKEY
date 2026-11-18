// Хранилище напоминаний. В напоминаниях есть имена файлов и кейсов, поэтому на диске только AES-GCM
// (ключ устройства `vault.key.device`, как у снимка сессии и кэша кейсов).
import Foundation

protocol ReminderStore: Sendable {
    func load() async throws -> [DocumentReminder]
    func save(_ reminders: [DocumentReminder]) async throws
}

actor InMemoryReminderStore: ReminderStore {
    private var items: [DocumentReminder]
    init(_ items: [DocumentReminder] = []) { self.items = items }
    func load() async throws -> [DocumentReminder] { items }
    func save(_ reminders: [DocumentReminder]) async throws { items = reminders }
}

struct EncryptedReminderStore: ReminderStore {
    private let keys: KeyStore
    private let baseDirectory: URL?
    private static let aad = Data("lokey.reminders.v1".utf8)

    init(keys: KeyStore = KeychainKeyStore(), baseDirectory: URL? = nil) {
        self.keys = keys; self.baseDirectory = baseDirectory
    }

    private func box() throws -> EncryptedFileBox {
        let k = try keys.vaultKey(accountID: "device")
        return try EncryptedFileBox(key: k.withUnsafeBytes { Data($0) }, folder: "reminders", baseDirectory: baseDirectory)
    }
    private func url(_ b: EncryptedFileBox) -> URL { b.root.appendingPathComponent("reminders.bin") }

    func load() async throws -> [DocumentReminder] {
        let b = try box()
        guard let plain = try b.read(url(b), aad: Self.aad) else { return [] }
        return try JSONDecoder().decode([DocumentReminder].self, from: plain)
    }
    func save(_ reminders: [DocumentReminder]) async throws {
        let b = try box()
        try b.write(try JSONEncoder().encode(reminders), to: url(b), aad: Self.aad)
    }
}
