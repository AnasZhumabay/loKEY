// Общий помощник для файловых хранилищ: AES-GCM + атомарная запись + защита файла + исключение из бэкапа.
import Foundation
import CryptoKit

enum SeamStoreError: Error, Equatable, Sendable {
    case badKey          // ключ не 32 байта
    case corrupted       // тег не сошёлся / файл повреждён / подменён
    case io(String)
}

struct EncryptedFileBox: Sendable {
    let keyData: Data
    let root: URL

    /// `key` — ровно 32 байта (ключ хранилища аккаунта). `root` по умолчанию Application Support/loKEY/<folder>.
    init(key: Data, folder: String, baseDirectory: URL? = nil) throws {
        guard key.count == 32 else { throw SeamStoreError.badKey }
        self.keyData = key
        let base = baseDirectory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
        self.root = base.appendingPathComponent("loKEY", isDirectory: true).appendingPathComponent(folder, isDirectory: true)
    }

    private var symKey: SymmetricKey { SymmetricKey(data: keyData) }

    func ensureDirectory(_ dir: URL) throws {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var d = dir
            var v = URLResourceValues(); v.isExcludedFromBackup = true
            try? d.setResourceValues(v)
        } catch { throw SeamStoreError.io(error.localizedDescription) }
    }

    func write(_ plain: Data, to url: URL, aad: Data) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        guard let combined = (try? AES.GCM.seal(plain, using: symKey, authenticating: aad))?.combined else { throw SeamStoreError.io("seal") }
        do {
            try combined.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            var u = url
            var v = URLResourceValues(); v.isExcludedFromBackup = true
            try? u.setResourceValues(v)
        } catch { throw SeamStoreError.io(error.localizedDescription) }
    }

    func read(_ url: URL, aad: Data) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let raw = try? Data(contentsOf: url) else { throw SeamStoreError.io("read") }
        guard let box = try? AES.GCM.SealedBox(combined: raw),
              let plain = try? AES.GCM.open(box, using: symKey, authenticating: aad) else { throw SeamStoreError.corrupted }
        return plain
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Безопасное имя файла из произвольного id.
    static func fileName(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
