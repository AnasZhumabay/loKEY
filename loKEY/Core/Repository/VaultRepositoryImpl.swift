import Foundation
import CryptoKit
import LocalAuthentication
import UIKit

actor VaultRepositoryImpl: VaultRepository {
    static let maxAttempts = 5
    static let lockoutSeconds: TimeInterval = 300
    static let demoKeyFinance = "7F3K-QX92-LM8D-A41Z-H6TP-2WRC-9VBN-E05J"
    static let demoKeyHealth = "4M9R-TD7X-Q2HB-8CNA-5WZ1-K3PE-V6YF-J0GD"

    private let api: APIServices
    private let keys: KeyStore
    private let seedDemo: Bool
    private var seeded = false
    private var accountID: String?
    private var unlocked: [String: SymmetricKey] = [:]
    private var records: [String: CaseRecordDTO] = [:]
    private var headers: [String: CaseHeader] = [:]
    private var names: [String: CaseHeader] = [:]       // переживает purge — для журнала
    private var fileIndex: [String: FileRecordDTO] = [:]
    private var kdfRounds: Int?
    private let tracker: AttemptTracker
    private let wipeStore: WipePolicyStore
    private let duressStore: DuressPINStore
    private let secretPolicy: KeyStoreAccessPolicy
    private let persistenceEnabled: Bool
    private let persistenceDirectory: URL?
    /// Не nil — включён режим «под принуждением»: все вызовы обслуживает приманка, реальные данные не трогаются.
    private var decoy: DecoyVault?

    /// - secretPolicy: защита секретов кейсов в Keychain. По умолчанию `.biometric`; в DEBUG с моками (обход Face ID) — `.standard`.
    /// - persistence: хранить снимок сессии и кэш кейсов на диске. По умолчанию — только с настоящим Keychain (в тестах выключено).
    init(api: APIServices, keys: KeyStore = KeychainKeyStore(), seedDemo: Bool? = nil,
         secretPolicy: KeyStoreAccessPolicy? = nil, persistence: Bool? = nil, persistenceDirectory: URL? = nil,
         duressRounds: Int = DuressPIN.defaultRounds) {
        self.api = api
        self.keys = keys
        self.seedDemo = seedDemo ?? (AppConfig.useMocks && AppConfig.seedDemoData)
        self.tracker = AttemptTracker(keys: keys)
        self.wipeStore = WipePolicyStore(keys: keys)
        self.duressStore = DuressPINStore(keys: keys, rounds: duressRounds)
        self.secretPolicy = secretPolicy ?? (AppConfig.bypassBiometrics ? .standard : .biometric)
        self.persistenceEnabled = persistence ?? (keys is KeychainKeyStore)
        self.persistenceDirectory = persistenceDirectory
    }

    // MARK: Локальное хранение
    private func persistenceKey() -> Data? {
        guard persistenceEnabled, decoy == nil, let k = try? keys.vaultKey(accountID: "device") else { return nil }
        return k.withUnsafeBytes { Data($0) }
    }
    private func sessionStore() -> FileSessionPersistence? {
        persistenceKey().flatMap { try? FileSessionPersistence(key: $0, baseDirectory: persistenceDirectory) }
    }
    private func casesCache() -> FileCasesCache? {
        persistenceKey().flatMap { try? FileCasesCache(key: $0, baseDirectory: persistenceDirectory) }
    }
    private func saveSnapshot(_ a: AccountDTO) {
        try? sessionStore()?.save(AccountSnapshot(accountId: a.id, email: a.email, username: a.username, savedAt: Date()))
    }
    private func reportEvent(_ kind: SecurityEventKind, caseId: String?) {
        let api = self.api
        Task.detached { _ = try? await api.securityEvents.report(SecurityEventDTO(kind: kind, caseId: caseId, at: Date(), deviceName: nil)) }
    }

    // MARK: Утилиты
    private func mapped<T>(_ op: () async throws -> T) async throws -> T {
        do { return try await op() }
        catch let e as APIError { throw VaultError.from(e) }
        catch let e as VaultError { throw e }
        catch is CancellationError { throw CancellationError() }
        catch { throw VaultError.server("Внутренняя ошибка") }
    }
    private func newID() -> String { UUID().uuidString.lowercased() }
    private func json<T: Encodable>(_ v: T) throws -> Data { try LKCoding.encoder.encode(v) }
    private func unjson<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T { try LKCoding.decoder.decode(t, from: d) }

    private func vaultKey() async throws -> SymmetricKey {
        if accountID == nil { accountID = try await mapped { try await api.account.me().id } }
        guard let id = accountID else { throw VaultError.notAuthenticated }
        do { return try keys.vaultKey(accountID: id) } catch { throw VaultError.server("Не удалось получить доступ к связке ключей") }
    }
    private func header(of r: CaseRecordDTO) async throws -> CaseHeader? {
        let vk = try await vaultKey()
        guard let d = try? CryptoService.open(r.sealedHeader, key: vk), let h = try? unjson(CaseHeader.self, d) else { return nil }
        return h
    }
    private func vaultCase(_ r: CaseRecordDTO, _ h: CaseHeader?) -> VaultCase {
        VaultCase(id: r.id, name: h?.name ?? "Кейс с другого устройства", icon: h?.icon ?? .key, level: h?.level ?? .standard,
                  favorite: h?.favorite ?? false, fileCount: r.fileCount, bytes: r.storageBytes,
                  isUnlocked: unlocked[r.id] != nil, updatedAt: r.updatedAt, isRecoverable: r.recoveryWrappedKey != nil)
    }
    private func refreshRecords() async throws -> [CaseRecordDTO] {
        let list = try await mapped { try await api.cases.list() }
        for r in list {
            records[r.id] = r
            if let h = try await header(of: r) { headers[r.id] = h; names[r.id] = h }
        }
        if let aid = accountID { try? casesCache()?.save(list, accountId: aid) }
        return list
    }
    private func record(_ id: String, fresh: Bool = false) async throws -> CaseRecordDTO {
        if !fresh, let r = records[id] { return r }
        _ = try await refreshRecords()
        guard let r = records[id] else { throw VaultError.server("Кейс не найден") }
        return r
    }
    private func key(_ caseID: String) throws -> SymmetricKey {
        guard let k = unlocked[caseID] else { throw VaultError.notUnlocked }
        return k
    }
    private func fireAudit(_ kind: AuditKind, _ caseID: String?) async { _ = try? await api.audit.record(kind: kind, caseId: caseID) }
    private func fireAuditDetached(_ items: [(AuditKind, String?)]) {
        let api = self.api
        Task.detached { for (k, c) in items { _ = try? await api.audit.record(kind: k, caseId: c) } }
    }

    // MARK: Сессия
    /// Состояние приманки в Keychain: «active» — после перезапуска сразу поднимаем приманку; «exited» — вышли из приманки,
    /// настоящую сессию не восстанавливаем, пока не будет настоящего входа (email/пароль). Настоящие данные не трогаются.
    private static let decoyFlagAccount = "decoy.state"
    private func decoyFlag() -> String? { keys.read(Self.decoyFlagAccount).flatMap { String(data: $0, encoding: .utf8) } }
    private func setDecoyFlag(_ v: String?) {
        if let v { try? keys.write(Data(v.utf8), account: Self.decoyFlagAccount) } else { keys.delete(Self.decoyFlagAccount) }
    }
    var isDecoy: Bool { get async { decoy != nil } }

    func restoreSession() async -> AccountDTO? {
        switch decoyFlag() {
        case "active":
            if decoy == nil { decoy = DecoyVault() }
            // Настоящий сервер и кэш не трогаем; аккаунт-заглушка без настоящих данных.
            return AccountDTO(id: "decoy", email: "", username: "me", backupEmail: nil, mfaEnabled: false, createdAt: Date())
        case "exited":
            return nil
        default: break
        }
        let a = await api.auth.restoreSession()?.account
        accountID = a?.id
        if let a { saveSnapshot(a) }
        return a
    }
    func register(email: String, username: String, password: String) async throws -> AccountDTO {
        let s = try await mapped { try await api.auth.register(RegisterRequest(email: email, username: username, password: password)) }
        decoy = nil; setDecoyFlag(nil)
        accountID = s.account.id
        await seedIfNeeded()
        saveSnapshot(s.account)
        return s.account
    }
    func login(identifier: String, password: String) async throws -> LoginOutcome {
        let r = try await mapped { try await api.auth.login(LoginRequest(identifier: identifier, password: password)) }
        if let s = r.session {
            decoy = nil; setDecoyFlag(nil)
            accountID = s.account.id
            await seedIfNeeded()
            saveSnapshot(s.account)
            return .signedIn(s.account)
        }
        if let c = r.mfaChallengeId { return .mfaRequired(challengeId: c) }
        throw VaultError.server("Пустой ответ сервера")
    }
    func verifyMFA(challengeId: String, code: String) async throws -> AccountDTO {
        let s = try await mapped { try await api.auth.verifyMFA(MFAVerifyRequest(challengeId: challengeId, code: code)) }
        decoy = nil; setDecoyFlag(nil)
        accountID = s.account.id
        await seedIfNeeded()
        saveSnapshot(s.account)
        return s.account
    }
    func requestPasswordReset(email: String) async throws { try await mapped { try await api.auth.requestPasswordReset(email: email) } }
    func logout() async throws {
        // Счётчики неверных попыток НЕ сбрасываем: иначе выход и вход обнуляли бы защиту от перебора.
        unlocked.removeAll(); records.removeAll(); headers.removeAll(); fileIndex.removeAll()
        if decoy != nil {
            // Из приманки просто выходим; настоящая сессия и данные остаются нетронутыми, но без настоящего входа
            // (email/пароль) они не открываются: флаг «exited» запрещает тихое восстановление сессии.
            decoy = nil; accountID = nil; setDecoyFlag("exited")
            return
        }
        accountID = nil
        await clearLocalPersistence(wipeChats: false)
        try await mapped { try await api.auth.logout() }
    }

    // MARK: Аккаунт
    func updateBackupEmail(_ email: String?) async throws -> AccountDTO {
        // В приманке настоящий аккаунт не меняем.
        if decoy != nil { return try await mapped { try await api.account.me() } }
        return try await mapped { try await api.account.updateBackupEmail(email) }
    }
    func setMFA(enabled: Bool, method: MFAKind) async throws -> MFASetup? {
        if decoy != nil { return nil }
        let m: MFAMethod = method == .sms ? .sms : .authenticator
        guard let d = try await mapped({ try await api.account.setMFA(enabled: enabled, method: m) }) else { return nil }
        return MFASetup(kind: d.method == .sms ? .sms : .authenticator, otpauthUri: d.otpauthUri)
    }

    func storageUsage() async throws -> StorageUsage {
        if let d = decoy { return d.storageUsage() }
        let u = try await mapped { try await api.account.storageUsage() }
        if u.perCase.contains(where: { names[$0.caseId] == nil }) { _ = try? await refreshRecords() }
        return StorageUsage(usedBytes: u.usedBytes, limitBytes: u.limitBytes, perCase: u.perCase.map {
            CaseStorage(caseID: $0.caseId, name: names[$0.caseId]?.name ?? "Кейс", level: names[$0.caseId]?.level ?? .standard, bytes: $0.bytes)
        })
    }
    func auditLog(limit: Int) async throws -> [AuditEvent] {
        if let d = decoy { return d.auditLog(limit: limit) }
        let list = try await mapped { try await api.audit.list(limit: limit) }
        if list.contains(where: { $0.caseId != nil && names[$0.caseId!] == nil }) { _ = try? await refreshRecords() }
        return list.map { AuditEvent(id: $0.id, kind: $0.kind, caseName: $0.caseId.flatMap { names[$0]?.name }, deviceName: $0.deviceName, at: $0.at) }
    }

    // MARK: Кейсы
    func listCases() async throws -> [VaultCase] {
        if let d = decoy { return d.listCases() }
        let list = try await refreshRecords()
        let ids = Set(list.map(\.id))
        for id in unlocked.keys where !ids.contains(id) { unlocked[id] = nil }
        return list.map { vaultCase($0, headers[$0.id]) }
    }

    func createCase(name: String, icon: CaseIcon, level: SecurityLevel) async throws -> NewCaseResult {
        try await makeCase(name: name, icon: icon, level: level, secret: nil)
    }

    private func makeCase(name: String, icon: CaseIcon, level: SecurityLevel, secret: Data?) async throws -> NewCaseResult {
        if let d = decoy { return try d.createCase(name: name, icon: icon, level: level) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultError.validation("Введите название кейса") }
        let vk = try await vaultKey()
        let id = newID()
        let secret = secret ?? KeyFormat.generateSecret()
        let ck = CryptoService.caseKey(fromSecret: secret)
        let words = RecoveryWords.generate()
        let h = CaseHeader(name: trimmed, icon: icon, level: level, favorite: false, keyCheck: CryptoService.keyCheck(for: ck))
        let now = Date()
        let rec = CaseRecordDTO(id: id, sealedHeader: try CryptoService.seal(try json(h), key: vk),
                                recoveryWrappedKey: try CryptoService.wrapSecret(secret, words: words, rounds: kdfRounds),
                                fileCount: 0, storageBytes: 0, revision: 0, createdAt: now, updatedAt: now, deletedAt: nil)
        let created = try await mapped { try await api.cases.create(rec) }
        do { try keys.setCaseSecret(secret, caseID: id, policy: secretPolicy) } catch { throw VaultError.server("Не удалось сохранить ключ в связке ключей") }
        unlocked[id] = ck; records[id] = created; headers[id] = h; names[id] = h
        await fireAudit(.caseCreated, id)
        return NewCaseResult(vaultCase: vaultCase(created, h), keyString: KeyFormat.format(secret),
                             keyFileName: KeyFormat.keyFileName(for: trimmed), keyFileData: KeyFormat.keyFileData(caseID: id, secret: secret),
                             recoveryWords: words)
    }

    func updateCase(id: String, name: String?, icon: CaseIcon?, level: SecurityLevel?, favorite: Bool?) async throws -> VaultCase {
        if let d = decoy { return try d.updateCase(id: id, name: name, icon: icon, level: level, favorite: favorite) }
        var rec = try await record(id, fresh: true)
        guard var h = headers[id] else { throw VaultError.server("Кейс создан на другом устройстве") }
        if let name {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw VaultError.validation("Введите название кейса") }
            h.name = t
        }
        if let icon { h.icon = icon }
        if let level { h.level = level }
        if let favorite { h.favorite = favorite }
        let expected = rec.revision
        rec.sealedHeader = try CryptoService.seal(try json(h), key: try await vaultKey())
        let updated = try await mapped { try await api.cases.update(rec, expectedRevision: expected) }
        records[id] = updated; headers[id] = h; names[id] = h
        return vaultCase(updated, h)
    }

    func unlockStatus(caseID: String) async -> UnlockStatus {
        if decoy != nil { return UnlockStatus(attemptsLeft: Self.maxAttempts, lockedUntil: nil) }
        let wipe = wipeStore.load()
        var st = tracker.state(caseID)
        if let u = st.lockedUntil {
            if u > Date() { return UnlockStatus(attemptsLeft: 0, lockedUntil: u) }
            tracker.setLockedUntil(caseID, nil)
            // Со стиранием счётчик живёт до успешного открытия, иначе N больше 5 недостижимо.
            if !wipe.enabled { tracker.reset(caseID) }
            st = tracker.state(caseID)
        }
        let left = wipe.enabled ? wipe.clamped.maxAttempts - st.failures : Self.maxAttempts - st.failures
        return UnlockStatus(attemptsLeft: max(0, left), lockedUntil: nil)
    }

    func unlockCase(id: String, method: UnlockMethod) async throws {
        // В приманке любой формально верный способ открывает кейс: «ошибка» выдала бы подмену.
        if let d = decoy {
            if case .keyString(let s) = method, (try? KeyFormat.parse(s)) == nil, !DuressPIN.isFormatValid(s) { throw VaultError.invalidKeyFormat }
            try d.unlock(id: id); return
        }
        let wipe = wipeStore.load()
        if let u = tracker.state(id).lockedUntil {
            if u > Date() { throw VaultError.lockedOut(until: u) }
            tracker.setLockedUntil(id, nil)
            if !wipe.enabled { tracker.reset(id) }
        }
        let rec = try await record(id)
        let cached = headers[id]
        let loaded = cached == nil ? try await header(of: rec) : nil
        guard let h = cached ?? loaded else { throw VaultError.server("Кейс создан на другом устройстве") }
        let secret: Data
        switch method {
        case .biometrics:
            secret = try await biometricSecret(id, reason: "Открыть кейс loKEY")
        case .keyString(let s):
            secret = try KeyFormat.parse(s)
        case .keyFile(let d):
            let f = try KeyFormat.parseKeyFile(d)
            // Ключ-файл другого кейса — не попытка подбора: просто отказ (иначе чужой файл приводил бы к блокировке/стиранию).
            guard f.caseID == id else { throw VaultError.invalidKeyFormat }
            secret = f.secret
        }
        let ck = CryptoService.caseKey(fromSecret: secret)
        guard CryptoService.keyCheck(for: ck) == h.keyCheck else {
            let n = tracker.recordFailure(id).failures
            await fireAudit(.unlockFailed, id)
            switch AttemptDecision.after(failures: n, policy: wipe, lockEvery: Self.maxAttempts) {
            case .wipe:
                wipeLocal(caseID: id)
                reportEvent(.caseWiped, caseId: id)
                throw VaultError.localKeyWiped
            case .lock:
                let until = Date().addingTimeInterval(Self.lockoutSeconds)
                tracker.setLockedUntil(id, until)
                reportEvent(.tooManyAttempts, caseId: id)
                throw VaultError.lockedOut(until: until)
            case .wrong(let left):
                throw VaultError.wrongKey(attemptsLeft: left)
            }
        }
        tracker.reset(id)
        unlocked[id] = ck
        // Ленивая миграция: старый секрет без ACL перезаписывается с биометрической защитой (или создаётся, если его не было).
        keys.migrateCaseSecret(secret, caseID: id, to: secretPolicy)
        await fireAudit(.caseUnlocked, id)
    }

    func unlockSharedCase(id: String, secret: Data) async throws {
        if decoy != nil { throw VaultError.server("Недоступно") }
        let rec = try await record(id)
        let cached = headers[id]
        let loaded = cached == nil ? try await header(of: rec) : nil
        guard let h = cached ?? loaded else { throw VaultError.server("Кейс создан на другом устройстве") }
        let ck = CryptoService.caseKey(fromSecret: secret)
        guard CryptoService.keyCheck(for: ck) == h.keyCheck else { throw VaultError.wrongKey(attemptsLeft: Self.maxAttempts) }
        unlocked[id] = ck
        keys.migrateCaseSecret(secret, caseID: id, to: secretPolicy)
        await fireAudit(.caseUnlocked, id)
    }

    /// Стирает ЛОКАЛЬНЫЕ следы кейса: секрет в Keychain, расшифрованные данные в памяти, индекс файлов.
    /// Копия на сервере и восстановление по 12 словам остаются.
    private func wipeLocal(caseID id: String) {
        keys.removeCaseSecret(id)
        tracker.reset(id)
        unlocked[id] = nil; headers[id] = nil; names[id] = nil
        fileIndex = fileIndex.filter { $0.value.caseId != id }
    }

    private struct ContextBox: @unchecked Sendable { let ctx: LAContext }

    /// Секрет кейса из Keychain после проверки владельца. Один `LAContext` — один запрос Face ID.
    private func biometricSecret(_ id: String, reason: String, delay: Bool = true) async throws -> Data {
        let account = "case.secret.\(id)"
        if AppConfig.bypassBiometrics {
            if delay { try? await Task.sleep(nanoseconds: 900_000_000) }
            guard case .found(let s) = keys.lookup(account) else { throw VaultError.biometricsFailed }
            return s
        }
        guard keys.hasCaseSecret(id) else { throw VaultError.biometricsFailed }
        let ctx = LAContext()
        ctx.localizedReason = reason
        switch keys.caseSecretPolicy(id) {
        case .standard:
            // Старая запись без ACL: сначала проверяем владельца сами, потом (после успешного открытия) мигрируем.
            try await authenticateBiometrics(ctx, reason: reason)
            guard case .found(let s) = keys.lookup(account) else { throw VaultError.biometricsFailed }
            return s
        case .biometric:
            let ks = keys
            let box = ContextBox(ctx: ctx)
            // Чтение с ACL блокирует поток до ответа пользователя — уходим с актора.
            let r = await Task.detached { ks.lookup(account, context: box.ctx) }.value
            guard case .found(let s) = r else { throw VaultError.biometricsFailed }
            return s
        }
    }

    private func authenticateBiometrics(_ ctx: LAContext, reason: String) async throws {
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { throw VaultError.biometricsFailed }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if !ok { throw VaultError.biometricsFailed }
        } catch { throw VaultError.biometricsFailed }
    }

    func recoverCase(id: String, words: [String]) async throws {
        if let d = decoy { _ = words; try d.unlock(id: id); return }
        let rec = try await record(id, fresh: true)
        // Фраза проверяется самим AES-GCM в unwrapSecret. Заголовок кейса (он запечатан ключом этого устройства) на новом
        // телефоне прочитать нельзя, поэтому он НЕ обязателен: иначе восстановление по 12 словам не работало бы там, где нужнее всего.
        guard let wrapped = rec.recoveryWrappedKey,
              let secret = try? CryptoService.unwrapSecret(wrapped, words: words), secret.count == KeyFormat.secretLength else {
            throw VaultError.recoveryFailed
        }
        let ck = CryptoService.caseKey(fromSecret: secret)
        let known = headers[id]
        if let known, CryptoService.keyCheck(for: ck) != known.keyCheck { throw VaultError.recoveryFailed }
        unlocked[id] = ck
        if known == nil {
            // Заводим заголовок на этом устройстве (имя временное), чтобы кейс потом открывался и по ключу, и по Face ID.
            let fresh = CaseHeader(name: "Восстановленный кейс", icon: .key, level: .standard, favorite: false, keyCheck: CryptoService.keyCheck(for: ck))
            if var r = try? await record(id, fresh: true), let sealed = try? CryptoService.seal(try json(fresh), key: try await vaultKey()) {
                let expected = r.revision
                r.sealedHeader = sealed
                if let updated = try? await mapped({ try await api.cases.update(r, expectedRevision: expected) }) {
                    records[id] = updated; headers[id] = fresh; names[id] = fresh
                }
            }
        }
        tracker.reset(id)
        _ = try? keys.setCaseSecret(secret, caseID: id, policy: secretPolicy)
        await fireAudit(.keyRecovered, id)
    }

    func lockCase(id: String) async {
        if let d = decoy { d.lock(id: id); return }
        guard unlocked.removeValue(forKey: id) != nil else { return }
        fireAuditDetached([(.caseLocked, id)])
    }
    func lockAll() async {
        if let d = decoy { d.lockAll(); return }
        let ids = Array(unlocked.keys)
        unlocked.removeAll()
        fireAuditDetached(ids.map { (.caseLocked, $0) })
    }

    func exportKey(caseID: String) async throws -> ExportedKey {
        if let d = decoy { return try d.exportKey(caseID: caseID) }
        _ = try key(caseID)
        let s: Data
        do { s = try await biometricSecret(caseID, reason: "Показать ключ кейса", delay: false) }
        catch { throw VaultError.server("Ключ недоступен на этом устройстве") }
        let name = names[caseID]?.name ?? "key"
        return ExportedKey(keyString: KeyFormat.format(s), fileName: KeyFormat.keyFileName(for: name),
                           fileData: KeyFormat.keyFileData(caseID: caseID, secret: s))
    }

    func purgeCase(id: String) async throws {
        if let d = decoy { try d.purge(id: id); return }
        try await mapped { try await api.cases.purge(id: id) }
        unlocked[id] = nil; records[id] = nil; headers[id] = nil
        fileIndex = fileIndex.filter { $0.value.caseId != id }
        keys.removeCaseSecret(id)
        tracker.reset(id)
        await fireAudit(.caseDeleted, id)
    }

    // MARK: Файлы
    private func metadata(_ r: FileRecordDTO, key k: SymmetricKey) throws -> FileMetadata {
        do { return try unjson(FileMetadata.self, try CryptoService.open(r.sealedMetadata, key: k)) }
        catch { throw VaultError.integrityFailed(fileID: r.id) }
    }
    private func vaultFile(_ r: FileRecordDTO, _ m: FileMetadata?) -> VaultFile {
        VaultFile(id: r.id, caseID: r.caseId, name: m?.name ?? "Зашифрованный файл", kind: m?.kind ?? .other,
                  bytes: m?.plainBytes ?? r.ciphertextSize, note: m?.note, favorite: m?.favorite ?? false,
                  offline: m?.offline ?? false, createdAt: r.createdAt, deletedAt: r.deletedAt, ocr: m?.ocrText)
    }
    private func decodeList(_ list: [FileRecordDTO], _ k: SymmetricKey?) -> [VaultFile] {
        list.map { r in
            fileIndex[r.id] = r
            return vaultFile(r, k.flatMap { try? metadata(r, key: $0) })
        }
    }

    func listFiles(caseID: String) async throws -> [VaultFile] {
        if let d = decoy { return try d.listFiles(caseID: caseID) }
        let k = try key(caseID)
        let list = try await mapped { try await api.files.list(caseId: caseID) }
        return decodeList(list, k)
    }

    func favoriteFiles() async throws -> [VaultFile] {
        if let d = decoy { return d.favoriteFiles() }
        var out: [VaultFile] = []
        for id in unlocked.keys.sorted() { out += try await listFiles(caseID: id).filter(\.favorite) }
        return out
    }

    func addFile(caseID: String, name: String, kind: FileKind, data: Data, note: String?, ocrText: String?,
                 progress: @escaping @Sendable (UploadProgress) -> Void) async throws -> VaultFile {
        if let d = decoy {
            for st in [UploadProgress.Stage.encrypting, .uploading, .verifying, .done] { progress(UploadProgress(stage: st, fraction: 1)) }
            return try d.addFile(caseID: caseID, name: name, kind: kind, data: data, note: note, ocrText: ocrText)
        }
        let k = try key(caseID)
        progress(UploadProgress(stage: .encrypting, fraction: 0))
        let usage = try await mapped { try await api.account.storageUsage() }
        if usage.usedBytes + Int64(data.count + CryptoService.sealOverhead) > usage.limitBytes {
            throw VaultError.quotaExceeded(limitBytes: usage.limitBytes)
        }
        let meta = FileMetadata(name: name, kind: kind, plainBytes: Int64(data.count), note: note, favorite: false, offline: false,
                                contentSha256: CryptoService.sha256Hex(data), ocrText: ocrText)
        let blob = try CryptoService.seal(data, key: k)
        let sha = CryptoService.sha256Hex(blob)
        let now = Date()
        let rec = FileRecordDTO(id: newID(), caseId: caseID, sealedMetadata: try CryptoService.seal(try json(meta), key: k),
                                ciphertextSize: Int64(blob.count), ciphertextSha256: sha, revision: 0, createdAt: now, updatedAt: now, deletedAt: nil)
        progress(UploadProgress(stage: .encrypting, fraction: 1))
        let created = try await mapped { try await api.files.create(rec) }
        progress(UploadProgress(stage: .uploading, fraction: 0))
        do {
            try await mapped { try await api.files.uploadCiphertext(fileId: created.id, data: blob, sha256: sha) {
                progress(UploadProgress(stage: .uploading, fraction: $0))
            } }
        } catch {
            _ = try? await api.files.purge(id: created.id)
            throw error
        }
        progress(UploadProgress(stage: .verifying, fraction: 0.5))
        guard created.ciphertextSha256 == sha else { throw VaultError.server("Не удалось проверить целостность при загрузке") }
        progress(UploadProgress(stage: .verifying, fraction: 1))
        progress(UploadProgress(stage: .done, fraction: 1))
        fileIndex[created.id] = created
        return vaultFile(created, meta)
    }

    private func locate(_ id: String) async throws -> FileRecordDTO {
        if let r = fileIndex[id] { return r }
        for c in try await refreshRecords() {
            let list = try await mapped { try await api.files.list(caseId: c.id) }
            list.forEach { fileIndex[$0.id] = $0 }
        }
        let trash = try await mapped { try await api.files.listTrash() }
        trash.forEach { fileIndex[$0.id] = $0 }
        guard let r = fileIndex[id] else { throw VaultError.server("Не найдено") }
        return r
    }

    /// Скачать, проверить хэши, расшифровать.
    private func fetchPlain(_ r: FileRecordDTO) async throws -> (Data, FileMetadata) {
        let k = try key(r.caseId)
        let blob = try await mapped { try await api.files.downloadCiphertext(fileId: r.id) }
        guard CryptoService.sha256Hex(blob) == r.ciphertextSha256 else { throw VaultError.integrityFailed(fileID: r.id) }
        guard let plain = try? CryptoService.open(blob, key: k) else { throw VaultError.integrityFailed(fileID: r.id) }
        let m = try metadata(r, key: k)
        guard CryptoService.sha256Hex(plain) == m.contentSha256 else { throw VaultError.integrityFailed(fileID: r.id) }
        return (plain, m)
    }

    func openFile(id: String) async throws -> Data {
        if let d = decoy { return try d.openFile(id: id) }
        let r = try await locate(id)
        _ = try key(r.caseId)
        return try await fetchPlain(r).0
    }

    func updateFile(id: String, name: String?, note: String?, favorite: Bool?, offline: Bool?) async throws -> VaultFile {
        if let d = decoy { return try d.updateFile(id: id, name: name, note: note, favorite: favorite, offline: offline) }
        var r = try await locate(id)
        let k = try key(r.caseId)
        let list = try await mapped { try await api.files.list(caseId: r.caseId) }
        if let fresh = list.first(where: { $0.id == id }) { r = fresh }
        var m = try metadata(r, key: k)
        if let name { m.name = name }
        if let note { m.note = note.isEmpty ? nil : note }
        if let favorite { m.favorite = favorite }
        if let offline { m.offline = offline }
        let expected = r.revision
        r.sealedMetadata = try CryptoService.seal(try json(m), key: k)
        let updated = try await mapped { try await api.files.update(r, expectedRevision: expected) }
        fileIndex[id] = updated
        return vaultFile(updated, m)
    }

    // MARK: Версии (1.1.0)
    private func freshRecord(_ id: String) async throws -> FileRecordDTO {
        var r = try await locate(id)
        let list = try await mapped { try await api.files.list(caseId: r.caseId) }
        if let f = list.first(where: { $0.id == id }) { r = f; fileIndex[id] = f }
        return r
    }
    func listVersions(fileID: String) async throws -> [FileVersion] {
        if let d = decoy { return try d.listVersions(fileID: fileID) }
        let r = try await freshRecord(fileID)
        let k = try key(r.caseId)
        let cur = try metadata(r, key: k)
        var out = [FileVersion(id: "current", name: cur.name, kind: cur.kind, bytes: cur.plainBytes, createdAt: r.updatedAt, isCurrent: true)]
        let vs = try await mapped { try await api.files.listVersions(fileId: fileID) }
        for v in vs {
            let m = (try? CryptoService.open(v.sealedMetadata, key: k)).flatMap { try? unjson(FileMetadata.self, $0) }
            out.append(FileVersion(id: v.id, name: m?.name ?? "Версия", kind: m?.kind ?? .other, bytes: m?.plainBytes ?? v.ciphertextSize,
                                   createdAt: v.createdAt, isCurrent: false))
        }
        return out
    }
    func replaceFileContent(fileID: String, data: Data, progress: @escaping @Sendable (UploadProgress) -> Void) async throws -> VaultFile {
        if let d = decoy {
            progress(UploadProgress(stage: .done, fraction: 1))
            return try d.replaceFileContent(fileID: fileID, data: data)
        }
        let r = try await freshRecord(fileID)
        let k = try key(r.caseId)
        progress(UploadProgress(stage: .encrypting, fraction: 0))
        var m = try metadata(r, key: k)
        m.plainBytes = Int64(data.count); m.contentSha256 = CryptoService.sha256Hex(data)
        let blob = try CryptoService.seal(data, key: k)
        let sha = CryptoService.sha256Hex(blob)
        let req = ReplaceFileRequest(sealedMetadata: try CryptoService.seal(try json(m), key: k), ciphertextSize: Int64(blob.count),
                                     ciphertextSha256: sha, expectedRevision: r.revision)
        progress(UploadProgress(stage: .encrypting, fraction: 1))
        let updated = try await mapped { try await api.files.replaceContent(fileId: fileID, request: req) }
        do {
            progress(UploadProgress(stage: .uploading, fraction: 0))
            try await mapped { try await api.files.uploadCiphertext(fileId: fileID, data: blob, sha256: sha) {
                progress(UploadProgress(stage: .uploading, fraction: $0))
            } }
        } catch {
            // Откат: возвращаем прежнюю версию, чтобы у файла не осталось «пустого» содержимого.
            if let prev = try? await api.files.listVersions(fileId: fileID).first {
                if let back = try? await api.files.restoreVersion(fileId: fileID, versionId: prev.id) { fileIndex[fileID] = back }
            }
            throw error
        }
        progress(UploadProgress(stage: .done, fraction: 1))
        fileIndex[fileID] = updated
        return vaultFile(updated, m)
    }
    func openVersion(fileID: String, versionID: String) async throws -> Data {
        if let d = decoy { return try d.openVersion(fileID: fileID, versionID: versionID) }
        let r = try await freshRecord(fileID)
        let k = try key(r.caseId)
        if versionID == "current" { return try await fetchPlain(r).0 }
        let vs = try await mapped { try await api.files.listVersions(fileId: fileID) }
        guard let v = vs.first(where: { $0.id == versionID }) else { throw VaultError.server("Версия не найдена") }
        let blob = try await mapped { try await api.files.downloadVersionCiphertext(versionId: versionID) }
        guard CryptoService.sha256Hex(blob) == v.ciphertextSha256 else { throw VaultError.integrityFailed(fileID: fileID) }
        guard let plain = try? CryptoService.open(blob, key: k) else { throw VaultError.integrityFailed(fileID: fileID) }
        // Сервер задаёт ciphertextSha256 сам, поэтому сверяем ещё и хэш открытого содержимого из запечатанных метаданных версии.
        guard let metaRaw = try? CryptoService.open(v.sealedMetadata, key: k), let meta = try? unjson(FileMetadata.self, metaRaw),
              CryptoService.sha256Hex(plain) == meta.contentSha256 else { throw VaultError.integrityFailed(fileID: fileID) }
        return plain
    }
    func restoreVersion(fileID: String, versionID: String) async throws -> VaultFile {
        if let d = decoy { return try d.restoreVersion(fileID: fileID, versionID: versionID) }
        let r = try await freshRecord(fileID)
        let k = try key(r.caseId)
        let updated = try await mapped { try await api.files.restoreVersion(fileId: fileID, versionId: versionID) }
        fileIndex[fileID] = updated
        _ = r
        return vaultFile(updated, try? metadata(updated, key: k))
    }

    // MARK: Сеансы и тарифы (1.1.0)
    func listSessions() async throws -> [DeviceSession] {
        if decoy != nil {
            let now = Date()
            return [DeviceSession(id: "local", deviceName: "Этот iPhone", platform: "ios", appVersion: nil, approxLocation: nil,
                                  createdAt: now.addingTimeInterval(-86_400 * 12), lastActiveAt: now, isCurrent: true)]
        }
        return try await mapped { try await api.account.listSessions() }.map {
            DeviceSession(id: $0.id, deviceName: $0.deviceName, platform: $0.platform, appVersion: $0.appVersion,
                          approxLocation: $0.approxLocation, createdAt: $0.createdAt, lastActiveAt: $0.lastActiveAt, isCurrent: $0.isCurrent)
        }
    }
    func revokeSession(id: String) async throws {
        if decoy != nil { return }
        try await mapped { try await api.account.revokeSession(id: id) }
    }
    func revokeOtherSessions() async throws {
        if decoy != nil { return }
        try await mapped { try await api.account.revokeOtherSessions() }
    }

    private func sub(_ d: SubscriptionDTO) -> PlanSubscription {
        PlanSubscription(planID: d.planId, state: d.status == .active ? .active : (d.status == .cancelled ? .cancelled : .expired), renewsAt: d.renewsAt)
    }
    func plans() async throws -> [StoragePlan] {
        try await mapped { try await api.billing.plans() }.map {
            StoragePlan(id: $0.id, title: $0.title, storageBytes: $0.storageBytes, priceMinor: $0.priceMinor, currency: $0.currency,
                        period: $0.period == .free ? .free : ($0.period == .month ? .month : .year))
        }
    }
    func subscription() async throws -> PlanSubscription { sub(try await mapped { try await api.billing.subscription() }) }
    func purchase(planID: String, transaction: String?) async throws -> PlanSubscription {
        if decoy != nil { return try await subscription() }
        return sub(try await mapped { try await api.billing.purchase(PurchaseRequest(planId: planID, appleTransaction: transaction)) })
    }
    func cancelSubscription() async throws -> PlanSubscription {
        if decoy != nil { return try await subscription() }
        return sub(try await mapped { try await api.billing.cancelSubscription() })
    }

    func moveFiles(ids: [String], toCaseID: String) async throws {
        if let d = decoy { try d.moveFiles(ids: ids, toCaseID: toCaseID); return }
        let target = try key(toCaseID)
        var recs: [FileRecordDTO] = []
        for id in ids {
            let r = try await locate(id)
            _ = try key(r.caseId)
            if r.caseId != toCaseID { recs.append(r) }
        }
        let usage = try await mapped { try await api.account.storageUsage() }
        if usage.usedBytes + recs.reduce(0, { $0 + $1.ciphertextSize }) > usage.limitBytes {
            throw VaultError.quotaExceeded(limitBytes: usage.limitBytes)
        }
        for r in recs {
            let (plain, m) = try await fetchPlain(r)
            let blob = try CryptoService.seal(plain, key: target)
            let sha = CryptoService.sha256Hex(blob)
            let now = Date()
            let rec = FileRecordDTO(id: newID(), caseId: toCaseID, sealedMetadata: try CryptoService.seal(try json(m), key: target),
                                    ciphertextSize: Int64(blob.count), ciphertextSha256: sha, revision: 0, createdAt: now, updatedAt: now, deletedAt: nil)
            let created = try await mapped { try await api.files.create(rec) }
            do { try await mapped { try await api.files.uploadCiphertext(fileId: created.id, data: blob, sha256: sha) { _ in } } }
            catch { _ = try? await api.files.purge(id: created.id); throw error }
            fileIndex[created.id] = created
            try await mapped { try await api.files.softDelete(id: r.id) }
            fileIndex[r.id] = nil
        }
    }

    func trashFiles(ids: [String]) async throws {
        if let d = decoy { try d.trashFiles(ids: ids); return }
        for id in ids { try await mapped { try await api.files.softDelete(id: id) }; fileIndex[id] = nil }
    }

    func listTrash() async throws -> [VaultFile] {
        if let d = decoy { return d.listTrash() }
        let list = try await mapped { try await api.files.listTrash() }
        return list.map { r in
            fileIndex[r.id] = r
            return vaultFile(r, unlocked[r.caseId].flatMap { try? metadata(r, key: $0) })
        }
    }
    func restoreFile(id: String) async throws {
        if let d = decoy { try d.restoreFile(id: id); return }
        let r = try await mapped { try await api.files.restore(id: id) }
        fileIndex[id] = r
    }
    func purgeFile(id: String) async throws {
        if let d = decoy { try d.purgeFile(id: id); return }
        try await mapped { try await api.files.purge(id: id) }
        fileIndex[id] = nil
    }

    // MARK: Безопасность
    func setDuressPIN(_ pin: String?) async throws {
        if decoy != nil { return }      // в приманке настройки «под принуждением» не меняются
        if let pin { try duressStore.save(pin: pin) } else { duressStore.clear() }
    }
    var duressEnabled: Bool { get async { decoy == nil && duressStore.isSet } }

    func unlockAppWithDuress(pin: String) async -> Bool {
        if decoy != nil { return DuressPIN.isFormatValid(pin) }
        guard duressStore.matches(pin) else { return false }
        // Реальные ключи и данные из памяти убираем и больше не трогаем, пока приманка включена.
        unlocked.removeAll(); records.removeAll(); headers.removeAll(); names.removeAll(); fileIndex.removeAll()
        decoy = DecoyVault()
        setDecoyFlag("active")
        reportEvent(.duressUnlock, caseId: nil)
        return true
    }

    func setWipePolicy(_ policy: WipePolicy) async {
        if decoy != nil { return }
        wipeStore.save(policy)
    }
    var wipePolicy: WipePolicy { get async { decoy != nil ? .off : wipeStore.load() } }

    // MARK: Поиск
    func searchAll(query: String) async -> [FileSearchHit] {
        if let d = decoy { return FileSearch.hits(query: query, sources: d.openCasesWithFiles()) }
        var sources: [(VaultCase, [VaultFile])] = []
        for id in unlocked.keys.sorted() {
            guard let rec = records[id], rec.deletedAt == nil, let files = try? await listFiles(caseID: id) else { continue }
            sources.append((vaultCase(rec, headers[id]), files))
        }
        return FileSearch.hits(query: query, sources: sources)
    }
    func searchSkippedLockedCount() async -> Int {
        if decoy != nil { return 0 }
        return records.values.filter { $0.deletedAt == nil && unlocked[$0.id] == nil }.count
    }

    // MARK: Локальное хранение
    func offlineSnapshot() async -> AccountSnapshot? {
        guard decoy == nil else { return nil }
        return try? sessionStore()?.load()
    }

    func cachedCases(for snapshot: AccountSnapshot) async -> [VaultCase] {
        guard decoy == nil, let cache = casesCache(), let recs = try? cache.load(accountId: snapshot.accountId) else { return [] }
        // Ключ аккаунта только читаем; создавать новый здесь нельзя.
        var vk: SymmetricKey?
        if case .found(let d) = keys.lookup("vault.key.\(snapshot.accountId)"), d.count == 32 { vk = SymmetricKey(data: d) }
        return recs.filter { $0.deletedAt == nil }.map { r in
            let h = vk.flatMap { try? CryptoService.open(r.sealedHeader, key: $0) }.flatMap { try? unjson(CaseHeader.self, $0) }
            return vaultCase(r, h)
        }
    }

    func resumeOfflineSession(_ snapshot: AccountSnapshot) async -> AccountDTO? {
        guard AppConfig.useMocks, decoy == nil else { return nil }
        guard let r = try? await api.auth.login(LoginRequest(identifier: snapshot.email, password: "mock-restore-session")),
              let s = r.session else { return nil }
        accountID = s.account.id
        await seedIfNeeded()
        saveSnapshot(s.account)
        return s.account
    }

    func makeHistoryStore() async -> HistoryStore? {
        guard let k = persistenceKey() else { return nil }
        return try? FileHistoryStore(key: k, baseDirectory: persistenceDirectory)
    }

    func clearLocalPersistence(wipeChats: Bool) async {
        guard decoy == nil else { return }
        var ids: Set<String> = []
        if let id = accountID { ids.insert(id) }
        if let id = (try? sessionStore()?.load())?.accountId { ids.insert(id) }
        try? sessionStore()?.clear()
        for id in ids { try? casesCache()?.clear(accountId: id) }
        if wipeChats, let hs = await makeHistoryStore() { for id in ids { try? await hs.wipe(accountId: id) } }
    }

    // MARK: Демо-данные
    private func seedIfNeeded() async {
        guard seedDemo, !seeded else { return }
        seeded = true
        guard let existing = try? await api.cases.list(), existing.isEmpty else { return }
        MockBackend.Hooks.setLatencyEnabled(false)
        kdfRounds = 20_000
        defer { MockBackend.Hooks.setLatencyEnabled(true); kdfRounds = nil }
        struct F { var name: String; var kind: FileKind; var note: String? = nil; var fav = false; var offline = false }
        let plan: [(String, CaseIcon, SecurityLevel, String?, Bool, [F])] = [
            ("Документы", .document, .critical, nil, true, [
                F(name: "Паспорт", kind: .pdf, note: "Действует до 2031. Оригинал — в сейфе дома.", fav: true, offline: true),
                F(name: "ID-карта, лицевая сторона", kind: .jpg),
                F(name: "Договор аренды", kind: .pdf, note: "скан до ремонта"),
                F(name: "Свидетельство о рождении", kind: .pdf),
                F(name: "Водительское удостоверение", kind: .heic),
                F(name: "Полис ОМС", kind: .jpg, fav: true)]),
            ("Финансы", .wallet, .sensitive, Self.demoKeyFinance, false, [
                F(name: "Выписка по счёту", kind: .pdf), F(name: "Налоговая декларация", kind: .pdf), F(name: "Чек на технику", kind: .jpg)]),
            ("Медицина", .health, .sensitive, Self.demoKeyHealth, false, [
                F(name: "Результаты анализов", kind: .pdf), F(name: "Рецепт", kind: .jpg)]),
            ("Семейный архив", .home, .standard, nil, true, [
                F(name: "Фото с отпуска", kind: .jpg), F(name: "Родословная", kind: .pdf),
                F(name: "Новый год 2024", kind: .jpg), F(name: "Письмо бабушки", kind: .pdf)])
        ]
        let tints: [UIColor] = [.systemTeal, .systemIndigo, .systemPink, .systemOrange, .systemGreen]
        for (name, icon, level, fixed, stayOpen, files) in plan {
            guard let res = try? await makeCase(name: name, icon: icon, level: level, secret: fixed.flatMap { try? KeyFormat.parse($0) }) else { continue }
            let cid = res.vaultCase.id
            for (i, f) in files.enumerated() {
                let data = f.kind == .pdf ? DemoContent.pdf(title: f.name) : DemoContent.jpeg(title: f.name, tint: tints[i % tints.count])
                guard let vf = try? await addFile(caseID: cid, name: f.name, kind: f.kind, data: data, note: f.note, ocrText: nil, progress: { _ in }) else { continue }
                if f.fav || f.offline { _ = try? await updateFile(id: vf.id, name: nil, note: nil, favorite: f.fav, offline: f.offline) }
            }
            if !stayOpen { unlocked[cid] = nil }
        }
    }
}
