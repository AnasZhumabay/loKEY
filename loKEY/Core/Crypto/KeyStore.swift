import Foundation
import CryptoKit
import Security
import LocalAuthentication

enum KeyStoreError: Error { case failed(OSStatus) }

/// Результат чтения: «записи нет» и «не удалось прочитать» — разные вещи (например, устройство заблокировано).
/// Новый ключ создавать можно ТОЛЬКО при `.missing`, иначе перезапишем настоящий и потеряем данные.
enum KeyLookup { case found(Data), missing, failed(OSStatus) }

/// Как защищён секрет кейса в связке ключей.
/// `.standard` — доступен, пока телефон разблокирован (прежнее поведение).
/// `.biometric` — доступ только после Face ID / Touch ID (или кода-пароля как запасной вариант), тип этого устройства.
enum KeyStoreAccessPolicy: String, Codable, Equatable, Sendable { case standard, biometric }

/// Какой ACL выбрать для `.biometric` на этом устройстве. Чистая функция, чтобы её можно было проверить тестом.
enum KeyStoreACLChoice: Equatable, Sendable {
    case biometryCurrentSet     // Face ID / Touch ID; при смене набора лиц секрет в связке недоступен (откроет ключ или 12 слов)
    case userPresence           // биометрии нет — код-пароль устройства
    case none                   // ни биометрии, ни код-пароля: ACL создать нельзя, остаётся `.standard`

    static func choose(biometryAvailable: Bool, passcodeAvailable: Bool) -> KeyStoreACLChoice {
        if biometryAvailable { return .biometryCurrentSet }
        if passcodeAvailable { return .userPresence }
        return .none
    }
}

/// Хранилище мелких секретов на устройстве.
protocol KeyStore: Sendable {
    func read(_ account: String) -> Data?
    func lookup(_ account: String) -> KeyLookup
    func write(_ data: Data, account: String) throws
    func delete(_ account: String)
    func deleteAll()
    /// Чтение с уже пройденной проверкой (`LAContext`): один запрос Face ID на несколько секретов.
    func lookup(_ account: String, context: LAContext?) -> KeyLookup
    /// Есть ли запись. НЕ читает значение и не вызывает Face ID.
    func exists(_ account: String) -> Bool
    /// Записывает с нужной защитой. Возвращает фактически применённую (если ACL недоступен, будет `.standard`).
    @discardableResult func write(_ data: Data, account: String, policy: KeyStoreAccessPolicy) throws -> KeyStoreAccessPolicy
}

extension KeyStore {
    func lookup(_ account: String) -> KeyLookup { read(account).map { .found($0) } ?? .missing }
    func lookup(_ account: String, context: LAContext?) -> KeyLookup { lookup(account) }
    func exists(_ account: String) -> Bool {
        if case .missing = lookup(account) { return false }
        return true
    }
    @discardableResult func write(_ data: Data, account: String, policy: KeyStoreAccessPolicy) throws -> KeyStoreAccessPolicy {
        try write(data, account: account); return .standard
    }
    /// Ключ хранилища аккаунта: запечатывает CaseHeader. Создаётся при первом обращении.
    func vaultKey(accountID: String) throws -> SymmetricKey {
        let name = "vault.key.\(accountID)"
        switch lookup(name) {
        case .found(let d):
            guard d.count == 32 else { throw KeyStoreError.failed(errSecDecode) }
            return SymmetricKey(data: d)
        case .failed(let s):
            throw KeyStoreError.failed(s)
        case .missing:
            let d = CryptoService.randomBytes(32)
            try write(d, account: name)
            return SymmetricKey(data: d)
        }
    }
    func caseSecret(_ caseID: String) -> Data? { read("case.secret.\(caseID)") }
    func setCaseSecret(_ secret: Data, caseID: String) throws {
        try write(secret, account: "case.secret.\(caseID)")
        delete(Self.policyMarker(caseID))      // обычная запись: метка биометрии больше не верна
    }
    func removeCaseSecret(_ caseID: String) { delete("case.secret.\(caseID)"); delete(Self.policyMarker(caseID)) }

    // MARK: Защита секрета кейса (ACL)
    fileprivate static func policyMarker(_ caseID: String) -> String { "case.policy.\(caseID)" }
    /// Какая защита у секрета сейчас. Нет метки — значит запись старая, без ACL.
    func caseSecretPolicy(_ caseID: String) -> KeyStoreAccessPolicy {
        read(Self.policyMarker(caseID)) == Data("b".utf8) ? .biometric : .standard
    }
    func hasCaseSecret(_ caseID: String) -> Bool { exists("case.secret.\(caseID)") }
    /// Записывает секрет с политикой. Возвращает применённую (может быть `.standard`, если биометрии/код-пароля нет).
    @discardableResult
    func setCaseSecret(_ secret: Data, caseID: String, policy: KeyStoreAccessPolicy) throws -> KeyStoreAccessPolicy {
        let applied = try write(secret, account: "case.secret.\(caseID)", policy: policy)
        try? write(Data((applied == .biometric ? "b" : "s").utf8), account: Self.policyMarker(caseID))
        return applied
    }
    /// Ленивая миграция: секрет без ACL (старая версия) перезаписывается с ACL. Возвращает итоговую политику.
    /// Секрет уже в руках у вызывающего (его только что проверили), поэтому «прочитать старый» здесь не нужно.
    @discardableResult
    func migrateCaseSecret(_ secret: Data, caseID: String, to target: KeyStoreAccessPolicy) -> KeyStoreAccessPolicy {
        let current = hasCaseSecret(caseID) ? caseSecretPolicy(caseID) : nil
        if current == target { return target }
        if target == .standard, current != nil { return current ?? .standard }   // понижать защиту автоматически не нужно
        return (try? setCaseSecret(secret, caseID: caseID, policy: target)) ?? (current ?? .standard)
    }
}

struct KeychainKeyStore: KeyStore {
    let service: String
    init(service: String = "com.lokey.keystore") { self.service = service }

    private func query(_ account: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    /// Контекст «без интерфейса»: записи с ACL не вызывают Face ID и не блокируют поток, а просто возвращают ошибку.
    private static func silentContext() -> LAContext {
        let c = LAContext(); c.interactionNotAllowed = true; return c
    }

    func read(_ account: String) -> Data? {
        if case .found(let d) = lookup(account) { return d }
        return nil
    }

    func lookup(_ account: String) -> KeyLookup { lookup(account, context: Self.silentContext()) }

    /// `context` с уже пройденной проверкой — тогда Face ID не спросят второй раз. Вызывать вне главного потока.
    func lookup(_ account: String, context: LAContext?) -> KeyLookup {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext as String] = context ?? Self.silentContext()
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecSuccess, let d = out as? Data { return .found(d) }
        if st == errSecItemNotFound { return .missing }
        return .failed(st)
    }

    /// Атомарно: сначала обновляем существующую запись, и только если её нет, добавляем. Без «удалить, потом добавить».
    func write(_ data: Data, account: String) throws {
        let upd = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if upd == errSecSuccess { return }
        guard upd == errSecItemNotFound else { throw KeyStoreError.failed(upd) }
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.failed(status) }
    }

    func exists(_ account: String) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext as String] = Self.silentContext()
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        return st == errSecSuccess || st == errSecInteractionNotAllowed
    }

    /// ACL для секрета: биометрия текущего набора лиц, иначе код-пароль; нет ни того ни другого — nil (будет `.standard`).
    static func makeAccessControl() -> SecAccessControl? {
        let ctx = LAContext()
        var e1: NSError?, e2: NSError?
        let choice = KeyStoreACLChoice.choose(
            biometryAvailable: ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e1),
            passcodeAvailable: ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &e2))
        let flags: SecAccessControlCreateFlags
        switch choice {
        case .biometryCurrentSet: flags = .biometryCurrentSet
        case .userPresence: flags = .userPresence
        case .none: return nil
        }
        return SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, flags, nil)
    }

    @discardableResult
    func write(_ data: Data, account: String, policy: KeyStoreAccessPolicy) throws -> KeyStoreAccessPolicy {
        guard policy == .biometric, let acl = Self.makeAccessControl() else {
            try write(data, account: account); return .standard
        }
        // Атрибут доступа у существующей записи не поменять — пересоздаём, но без окна, когда секрета нет нигде:
        // сначала кладём новую запись под временным именем, и только потом заменяем старую.
        let tmp = account + ".rewrite"
        func addWithACL(_ acct: String) -> Bool {
            var q = query(acct)
            q[kSecValueData as String] = data
            q[kSecAttrAccessControl as String] = acl
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }
        SecItemDelete(query(tmp) as CFDictionary)
        guard addWithACL(tmp) else {
            // ACL недоступен (например, симулятор без код-пароля): обновляем старую запись на месте, ничего не удаляя.
            try write(data, account: account); return .standard
        }
        SecItemDelete(query(account) as CFDictionary)
        if addWithACL(account) { SecItemDelete(query(tmp) as CFDictionary); return .biometric }
        // Не вышло: пробуем обычную запись; если и она не удалась, копия под временным именем сохраняется.
        try write(data, account: account)
        SecItemDelete(query(tmp) as CFDictionary)
        return .standard
    }

    func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
    func deleteAll() { SecItemDelete(query(nil) as CFDictionary) }
}

final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var applied: [String: KeyStoreAccessPolicy] = [:]
    /// Имитирует устройство с/без биометрии и код-пароля (для тестов выбора политики и отката).
    let supportsBiometricACL: Bool
    init(supportsBiometricACL: Bool = true) { self.supportsBiometricACL = supportsBiometricACL }
    /// Для тестов: какая политика реально применена к записи.
    func appliedPolicy(_ account: String) -> KeyStoreAccessPolicy? { lock.lock(); defer { lock.unlock() }; return applied[account] }
    func write(_ data: Data, account: String, policy: KeyStoreAccessPolicy) throws -> KeyStoreAccessPolicy {
        let a: KeyStoreAccessPolicy = (policy == .biometric && supportsBiometricACL) ? .biometric : .standard
        lock.lock(); items[account] = data; applied[account] = a; lock.unlock()
        return a
    }
    func read(_ account: String) -> Data? { lock.lock(); defer { lock.unlock() }; return items[account] }
    func write(_ data: Data, account: String) throws { lock.lock(); items[account] = data; applied[account] = .standard; lock.unlock() }
    func delete(_ account: String) { lock.lock(); items[account] = nil; applied[account] = nil; lock.unlock() }
    func deleteAll() { lock.lock(); items.removeAll(); applied.removeAll(); lock.unlock() }
}
