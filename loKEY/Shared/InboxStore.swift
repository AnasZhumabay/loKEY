import Foundation
import CryptoKit
import Security

extension LoKEYShared {
    static let keychainGroup = "Y8PGBLF73X.com.anasjumabay.lokey.shared"
}

/// Ошибки «Входящих» (сообщения на русском — показываются пользователю).
enum InboxError: LocalizedError {
    case containerUnavailable
    case itemTooLarge(limitMB: Int)
    case inboxFull(limitMB: Int)
    case keychain(OSStatus)
    case corrupted
    case notFound
    case io(String)

    var errorDescription: String? {
        switch self {
        case .containerUnavailable: return "Не удалось получить доступ к общему хранилищу loKEY."
        case .itemTooLarge(let mb): return "Файл слишком большой: максимум \(mb) МБ на один файл."
        case .inboxFull(let mb): return "«Входящие» переполнены (лимит \(mb) МБ). Перенесите файлы в кейс и повторите."
        case .keychain(let s): return "Не удалось получить ключ «Входящих» (код \(s))."
        case .corrupted: return "Файл во «Входящих» повреждён или не расшифровывается."
        case .notFound: return "Файл не найден во «Входящих»."
        case .io(let m): return "Ошибка записи: \(m)"
        }
    }
}

struct InboxItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// pdf | jpg | png | heic | video | note | other
    let kind: String
    let bytes: Int64
    let addedAt: Date
}

/// Входящие: шифртекст в App Group (`Inbox/<uuid>.blob` + `.meta`), ключ — в общей Keychain-группе.
/// Формат файла: AES.GCM combined (12 байт nonce + шифртекст + 16 байт тег). `.meta` — зашифрованный JSON
/// {name, kind, bytes, date}. Открытый текст на диск не попадает.
enum InboxStore {
    static let maxItemBytes = 25 * 1024 * 1024
    static let maxTotalBytes = 100 * 1024 * 1024
    private static let service = "com.anasjumabay.lokey.inbox"
    private static let account = "inbox-key-v1"

    private struct Meta: Codable { var name: String; var kind: String; var bytes: Int64; var date: Date }

    // MARK: Публичный API

    static func add(name: String, data: Data) throws {
        guard data.count <= maxItemBytes else { throw InboxError.itemTooLarge(limitMB: maxItemBytes >> 20) }
        let dir = try inboxDir()
        guard totalBlobBytes(dir) + Int64(data.count) <= Int64(maxTotalBytes) else {
            throw InboxError.inboxFull(limitMB: maxTotalBytes >> 20)
        }
        let key = try inboxKey()
        let meta = Meta(name: name, kind: kind(forName: name), bytes: Int64(data.count), date: Date())
        let id = UUID().uuidString
        let blobURL = dir.appendingPathComponent(id + ".blob")
        let metaURL = dir.appendingPathComponent(id + ".meta")
        do {
            let blob = try seal(data, key: key)
            let metaBlob = try seal(try JSONEncoder().encode(meta), key: key)
            try blob.write(to: blobURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            do {
                try metaBlob.write(to: metaURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            } catch {
                try? FileManager.default.removeItem(at: blobURL)
                throw error
            }
        } catch let e as InboxError { throw e } catch { throw InboxError.io(error.localizedDescription) }
    }

    static func list() throws -> [InboxItem] {
        let dir = try inboxDir()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let metas = files.filter { $0.pathExtension == "meta" }
        if metas.isEmpty { return [] }
        let key = try inboxKey()
        var out: [InboxItem] = []
        for url in metas {
            guard let raw = try? Data(contentsOf: url),
                  let json = try? unseal(raw, key: key),
                  let m = try? JSONDecoder().decode(Meta.self, from: json) else { continue }
            out.append(InboxItem(id: url.deletingPathExtension().lastPathComponent,
                                 name: m.name, kind: m.kind, bytes: m.bytes, addedAt: m.date))
        }
        return out.sorted { $0.addedAt > $1.addedAt }
    }

    static func open(_ id: String) throws -> Data {
        guard isValid(id) else { throw InboxError.notFound }
        let url = try inboxDir().appendingPathComponent(id + ".blob")
        guard let raw = try? Data(contentsOf: url) else { throw InboxError.notFound }
        return try unseal(raw, key: try inboxKey())
    }

    static func remove(_ id: String) {
        guard isValid(id), let dir = try? inboxDir() else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".blob"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".meta"))
    }

    static func pendingCount() -> Int {
        guard let dir = try? inboxDir(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        return files.filter { $0.pathExtension == "meta" }.count
    }

    static func kind(forName name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "jpg"
        case "png": return "png"
        case "heic", "heif": return "heic"
        case "pdf": return "pdf"
        case "mov", "mp4", "m4v": return "video"
        case "txt", "md": return "note"
        default: return "other"
        }
    }

    // MARK: Внутреннее

    private static func isValid(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    private static func inboxDir() throws -> URL {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LoKEYShared.appGroup) else {
            throw InboxError.containerUnavailable
        }
        let dir = base.appendingPathComponent("Inbox", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { throw InboxError.io(error.localizedDescription) }
        }
        return dir
    }

    private static func totalBlobBytes(_ dir: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "blob" }.reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw InboxError.corrupted }
        return combined
    }

    private static func unseal(_ raw: Data, key: SymmetricKey) throws -> Data {
        do { return try AES.GCM.open(try AES.GCM.SealedBox(combined: raw), using: key) }
        catch { throw InboxError.corrupted }
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: LoKEYShared.keychainGroup,
         kSecUseDataProtectionKeychain as String: true]
    }

    private static func inboxKey() throws -> SymmetricKey {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecSuccess {
            if let d = out as? Data, d.count == 32 { return SymmetricKey(data: d) }
            throw InboxError.corrupted   // не перезаписываем незнакомые данные
        }
        guard st == errSecItemNotFound else { throw InboxError.keychain(st) }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else { throw InboxError.keychain(errSecAllocate) }
        var add = baseQuery()
        add[kSecValueData as String] = Data(bytes)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let ast = SecItemAdd(add as CFDictionary, nil)
        if ast == errSecSuccess { return SymmetricKey(data: Data(bytes)) }
        if ast == errSecDuplicateItem {   // гонка app/extension: берём чужой ключ
            var out2: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out2) == errSecSuccess, let d = out2 as? Data, d.count == 32 {
                return SymmetricKey(data: d)
            }
        }
        throw InboxError.keychain(ast)
    }
}
