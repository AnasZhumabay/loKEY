import UIKit
import Security

struct SavedSignature: Identifiable {
    let id: String
    let image: UIImage
    let date: Date
}

/// Хранилище сохранённых подписей в Keychain (kSecClassGenericPassword, account = UUID).
final class SignatureStore {
    static let shared = SignatureStore()
    static let maxCount = 5
    private let service = "com.anasjumabay.lokey.signatures"

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    /// Новые первыми.
    func all() -> [SavedSignature] {
        var q = baseQuery()
        q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> SavedSignature? in
            guard let id = row[kSecAttrAccount as String] as? String,
                  let data = row[kSecValueData as String] as? Data,
                  let img = UIImage(data: data) else { return nil }
            return SavedSignature(id: id, image: img, date: row[kSecAttrCreationDate as String] as? Date ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    /// Сохраняет подпись; при переполнении удаляет самую старую.
    @discardableResult
    func add(_ image: UIImage) -> Bool {
        guard let data = Self.compactPNG(image) else { return false }
        let existing = all()
        if existing.count >= Self.maxCount {
            for old in existing.suffix(existing.count - Self.maxCount + 1) { delete(id: old.id) }
        }
        var q = baseQuery()
        q[kSecAttrAccount as String] = UUID().uuidString
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    func delete(id: String) {
        var q = baseQuery()
        q[kSecAttrAccount as String] = id
        SecItemDelete(q as CFDictionary)
    }

    /// PNG с прозрачностью, не шире 700 px (чтобы запись в Keychain оставалась небольшой).
    private static func compactPNG(_ image: UIImage) -> Data? {
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard px.width > 0, px.height > 0 else { return nil }
        let k = min(1, 700 / px.width)
        let target = CGSize(width: (px.width * k).rounded(), height: (px.height * k).rounded())
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = false
        return UIGraphicsImageRenderer(size: target, format: f).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }.pngData()
    }
}
