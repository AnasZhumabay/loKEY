// In-memory бэкенд для разработки и тестов. Реализует ВСЕ протоколы Contract/Services.swift.
import Foundation
import CryptoKit

enum MockBackend {
    static func makeServices(latency: ClosedRange<Double> = 0.12...0.35) -> APIServices {
        let s = MockStore(latency: latency)
        MockRegistry.shared.current = s
        return APIServices(auth: MockAuthAPI(s: s), account: MockAccountAPI(s: s), cases: MockCasesAPI(s: s),
                           files: MockFilesAPI(s: s), audit: MockAuditAPI(s: s), billing: MockBillingAPI(s: s),
                           chat: MockChatAPI(s: MockChatStore(account: { await s.currentAccount() })),
                           sharedCases: MockSharedCaseAPI(), backup: MockBackupAPI(),
                           chatGroups: MockChatGroupAPI(), securityEvents: MockSecurityEventAPI())
    }

    /// Тестовые «рычаги» последнего созданного мок-бэкенда.
    enum Hooks {
        /// Испортить сохранённый шифртекст файла.
        static func tamper(fileId: String) async { await MockRegistry.shared.current?.tamper(fileId) }
        static func setLimit(bytes: Int64) async { await MockRegistry.shared.current?.setLimit(bytes) }
        /// Сдвинуть время удаления файла в прошлое (проверка срока хранения корзины).
        static func backdateTrash(fileId: String, days: Int) async { await MockRegistry.shared.current?.backdate(fileId, days) }
        static func setLatencyEnabled(_ on: Bool) { MockRegistry.shared.latencyEnabled = on }
    }

    static let trashRetentionDays = 30
}

final class MockRegistry: @unchecked Sendable {
    static let shared = MockRegistry()
    private let lock = NSLock()
    private var _current: MockStore?
    private var _latency = true
    var current: MockStore? { get { lock.lock(); defer { lock.unlock() }; return _current } set { lock.lock(); _current = newValue; lock.unlock() } }
    var latencyEnabled: Bool { get { lock.lock(); defer { lock.unlock() }; return _latency } set { lock.lock(); _latency = newValue; lock.unlock() } }
}

actor MockStore {
    struct Acct { var dto: AccountDTO }
    struct Vault {
        var cases: [CaseRecordDTO] = []
        var files: [FileRecordDTO] = []
        var blobs: [String: Data] = [:]
        var audit: [AuditEventDTO] = []
        var versions: [String: [FileVersionDTO]] = [:]   // fileId → предыдущие версии, новые первыми
        var versionBlobs: [String: Data] = [:]
        var sessions: [SessionInfoDTO] = []
        var subscription = SubscriptionDTO(planId: "free", status: .active, renewsAt: nil)
    }
    static let plans: [PlanDTO] = [
        PlanDTO(id: "free", title: "Бесплатный", storageBytes: 5 * 1_000_000_000, priceMinor: 0, currency: "USD", period: .free),
        PlanDTO(id: "plus_10_month", title: "Плюс", storageBytes: 10 * 1_000_000_000, priceMinor: 499, currency: "USD", period: .month),
        PlanDTO(id: "pro_25_month", title: "Про", storageBytes: 25 * 1_000_000_000, priceMinor: 999, currency: "USD", period: .month),
        PlanDTO(id: "max_120_month", title: "Макс", storageBytes: 120 * 1_000_000_000, priceMinor: 4999, currency: "USD", period: .month),
    ]

    private let latency: ClosedRange<Double>
    private var accounts: [String: Acct] = [:]          // по id
    private var session: SessionDTO?
    private var challenges: [String: String] = [:]
    private var vaults: [String: Vault] = [:]
    private var limit: Int64 = AppConfig.storageLimitBytes

    init(latency: ClosedRange<Double>) { self.latency = latency }

    func currentAccount() -> AccountDTO? { session?.account }

    // MARK: Служебное
    private func pause() async {
        guard MockRegistry.shared.latencyEnabled, latency.upperBound > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(Double.random(in: latency) * 1_000_000_000))
    }
    private func uid() throws -> String {
        guard let s = session else { throw APIError.unauthorized }
        return s.account.id
    }
    private func vault() throws -> (String, Vault) { let id = try uid(); return (id, vaults[id] ?? Vault()) }
    private func save(_ id: String, _ v: Vault) { vaults[id] = v }
    private func log(_ v: inout Vault, _ kind: AuditKind, _ caseId: String?) {
        v.audit.insert(AuditEventDTO(id: UUID().uuidString.lowercased(), kind: kind, caseId: caseId,
                                     deviceName: "Этот iPhone", ipHint: "192.168.1.x", at: Date()), at: 0)
    }
    private func makeSession(_ a: AccountDTO) -> SessionDTO {
        let s = SessionDTO(accessToken: "mock-access-" + UUID().uuidString, refreshToken: "mock-refresh-" + UUID().uuidString,
                           expiresAt: Date().addingTimeInterval(3600), account: a)
        session = s
        var v = vaults[a.id] ?? Vault()
        v.sessions.removeAll { $0.isCurrent }
        if v.sessions.isEmpty {
            let now = Date()
            v.sessions = [
                SessionInfoDTO(id: "mock-s-ipad", deviceName: "iPad Pro", platform: "ios", appVersion: "0.1.0", approxLocation: "Алматы, KZ",
                               createdAt: now.addingTimeInterval(-86400 * 9), lastActiveAt: now.addingTimeInterval(-3600 * 5), isCurrent: false),
                SessionInfoDTO(id: "mock-s-web", deviceName: "Safari · MacBook", platform: "web", appVersion: nil, approxLocation: "Астана, KZ",
                               createdAt: now.addingTimeInterval(-86400 * 30), lastActiveAt: now.addingTimeInterval(-86400 * 2), isCurrent: false),
            ]
        }
        v.sessions.insert(SessionInfoDTO(id: "cur-" + String(s.accessToken.suffix(8)), deviceName: "Этот iPhone", platform: "ios", appVersion: "0.1.0",
                                         approxLocation: nil, createdAt: Date(), lastActiveAt: Date(), isCurrent: true), at: 0)
        vaults[a.id] = v
        if let sub = vaults[a.id]?.subscription, let plan = MockStore.plans.first(where: { $0.id == sub.planId }) { limit = plan.storageBytes }
        return s
    }
    private func validEmail(_ e: String) -> Bool {
        let p = e.split(separator: "@", omittingEmptySubsequences: false)
        return p.count == 2 && !p[0].isEmpty && p[1].contains(".") && !p[1].hasPrefix(".") && !p[1].hasSuffix(".") && !e.contains(" ")
    }
    private func decorate(_ c: CaseRecordDTO, _ v: Vault) -> CaseRecordDTO {
        var c = c
        let fs = v.files.filter { $0.caseId == c.id }
        c.fileCount = fs.filter { $0.deletedAt == nil }.count
        c.storageBytes = fs.reduce(0) { $0 + $1.ciphertextSize }
        return c
    }
    private func used(_ v: Vault) -> Int64 {
        v.files.reduce(0) { $0 + $1.ciphertextSize } + v.versions.values.joined().reduce(0) { $0 + $1.ciphertextSize }   // версии занимают место
    }

    // MARK: Auth
    func register(_ r: RegisterRequest) async throws -> SessionDTO {
        await pause()
        guard validEmail(r.email) else { throw APIError.validation("Введите корректный email") }
        guard r.username.trimmingCharacters(in: .whitespaces).count >= 3 else { throw APIError.validation("Имя пользователя — минимум 3 символа") }
        guard r.password.count >= 8 else { throw APIError.validation("Пароль — минимум 8 символов") }
        if accounts.values.contains(where: { $0.dto.email.lowercased() == r.email.lowercased() }) {
            throw APIError.validation("Этот email уже зарегистрирован")
        }
        let a = AccountDTO(id: UUID().uuidString.lowercased(), email: r.email, username: r.username, backupEmail: nil, mfaEnabled: false, createdAt: Date())
        accounts[a.id] = Acct(dto: a)
        return makeSession(a)
    }

    func login(_ r: LoginRequest) async throws -> LoginResponse {
        await pause()
        let ident = r.identifier.trimmingCharacters(in: .whitespaces)
        guard !ident.isEmpty, r.password.count >= 6 else { throw APIError.validation("Введите логин и пароль (от 6 символов)") }
        let acct = accounts.values.first { $0.dto.email.lowercased() == ident.lowercased() || $0.dto.username.lowercased() == ident.lowercased() }?.dto
            ?? {
                let a = AccountDTO(id: UUID().uuidString.lowercased(), email: ident.contains("@") ? ident.lowercased() : "\(ident.lowercased())@demo.lokey",
                                   username: String(ident.split(separator: "@")[0]), backupEmail: nil, mfaEnabled: ident.lowercased().contains("mfa"), createdAt: Date())
                accounts[a.id] = Acct(dto: a)
                return a
            }()
        if r.password == "wrong-password" {
            var v = vaults[acct.id] ?? Vault(); log(&v, .loginFailed, nil); vaults[acct.id] = v
            throw APIError.unauthorized
        }
        if ident.lowercased().contains("mfa") {
            let ch = UUID().uuidString.lowercased(); challenges[ch] = acct.id
            return LoginResponse(session: nil, mfaChallengeId: ch)
        }
        var v = vaults[acct.id] ?? Vault(); log(&v, .login, nil); vaults[acct.id] = v
        return LoginResponse(session: makeSession(acct), mfaChallengeId: nil)
    }

    func verifyMFA(_ r: MFAVerifyRequest) async throws -> SessionDTO {
        await pause()
        guard let id = challenges[r.challengeId], let a = accounts[id] else { throw APIError.unauthorized }
        guard r.code == "123456" else { throw APIError.mfaInvalid }
        challenges[r.challengeId] = nil
        var v = vaults[id] ?? Vault(); log(&v, .login, nil); vaults[id] = v
        return makeSession(a.dto)
    }

    func restore() -> SessionDTO? { session }
    func logout() async throws {
        await pause()
        let id = try uid()
        var v = vaults[id] ?? Vault(); log(&v, .logout, nil); vaults[id] = v
        session = nil
    }
    func resetPassword(_ email: String) async throws {
        await pause()
        guard validEmail(email) else { throw APIError.validation("Введите корректный email") }
    }

    // MARK: Account
    func me() async throws -> AccountDTO { await pause(); let id = try uid(); return accounts[id]?.dto ?? session!.account }
    func updateBackupEmail(_ e: String?) async throws -> AccountDTO {
        await pause()
        let id = try uid()
        let mail = e?.trimmingCharacters(in: .whitespaces)
        if let m = mail, !m.isEmpty, !validEmail(m) { throw APIError.validation("Введите корректный email") }
        var a = accounts[id]?.dto ?? session!.account
        a.backupEmail = (mail?.isEmpty ?? true) ? nil : mail
        accounts[id] = Acct(dto: a); session?.account = a
        return a
    }
    func setMFA(_ enabled: Bool, _ method: MFAMethod) async throws -> MFASetupDTO? {
        await pause()
        let id = try uid()
        var a = accounts[id]?.dto ?? session!.account
        a.mfaEnabled = enabled
        accounts[id] = Acct(dto: a); session?.account = a
        var v = vaults[id] ?? Vault(); log(&v, .mfaChanged, nil); vaults[id] = v
        guard enabled else { return nil }
        return MFASetupDTO(method: method, otpauthUri: method == .authenticator ? "otpauth://totp/loKEY:\(a.email)?secret=JBSWY3DPEHPK3PXP&issuer=loKEY" : nil)
    }
    func storage() async throws -> StorageUsageDTO {
        await pause()
        let (_, v) = try vault()
        return StorageUsageDTO(usedBytes: used(v), limitBytes: limit,
                               perCase: v.cases.map { c in CaseUsageDTO(caseId: c.id, bytes: v.files.filter { $0.caseId == c.id }.reduce(0) { $0 + $1.ciphertextSize }) })
    }

    // MARK: Cases
    func listCases() async throws -> [CaseRecordDTO] { await pause(); let (_, v) = try vault(); return v.cases.map { decorate($0, v) } }
    func createCase(_ r: CaseRecordDTO) async throws -> CaseRecordDTO {
        await pause()
        var (id, v) = try vault()
        if let e = v.cases.first(where: { $0.id == r.id }) { return decorate(e, v) }
        var c = r; c.revision = 1; c.createdAt = Date(); c.updatedAt = c.createdAt; c.deletedAt = nil
        v.cases.append(c); save(id, v)
        return decorate(c, v)
    }
    func updateCase(_ r: CaseRecordDTO, _ rev: Int) async throws -> CaseRecordDTO {
        await pause()
        var (id, v) = try vault()
        guard let i = v.cases.firstIndex(where: { $0.id == r.id }) else { throw APIError.notFound }
        guard v.cases[i].revision == rev else { throw APIError.conflict }
        v.cases[i].sealedHeader = r.sealedHeader
        v.cases[i].recoveryWrappedKey = r.recoveryWrappedKey
        v.cases[i].revision += 1; v.cases[i].updatedAt = Date()
        save(id, v)
        return decorate(v.cases[i], v)
    }
    func purgeCase(_ cid: String) async throws {
        await pause()
        var (id, v) = try vault()
        guard v.cases.contains(where: { $0.id == cid }) else { throw APIError.notFound }
        let fids = v.files.filter { $0.caseId == cid }.map(\.id)
        fids.forEach { v.blobs[$0] = nil }
        v.files.removeAll { $0.caseId == cid }
        v.cases.removeAll { $0.id == cid }
        save(id, v)
    }

    // MARK: Files
    func listFiles(_ cid: String) async throws -> [FileRecordDTO] {
        await pause(); let (_, v) = try vault()
        guard v.cases.contains(where: { $0.id == cid }) else { throw APIError.notFound }
        return v.files.filter { $0.caseId == cid && $0.deletedAt == nil }
    }
    func listTrash() async throws -> [FileRecordDTO] {
        await pause()
        var (id, v) = try vault()
        let cutoff = Date().addingTimeInterval(-Double(MockBackend.trashRetentionDays) * 86_400)
        let expired = v.files.filter { ($0.deletedAt ?? .distantFuture) < cutoff }.map(\.id)
        if !expired.isEmpty {
            expired.forEach { v.blobs[$0] = nil }
            v.files.removeAll { expired.contains($0.id) }
            save(id, v)
        }
        return v.files.filter { $0.deletedAt != nil }
    }
    func createFile(_ r: FileRecordDTO) async throws -> FileRecordDTO {
        await pause()
        var (id, v) = try vault()
        if let e = v.files.first(where: { $0.id == r.id }) { return e }
        guard v.cases.contains(where: { $0.id == r.caseId }) else { throw APIError.notFound }
        guard r.ciphertextSize >= 0 else { throw APIError.validation("Некорректный размер") }
        if used(v) + r.ciphertextSize > limit { throw APIError.quotaExceeded(limitBytes: limit) }
        var f = r; f.revision = 1; f.createdAt = Date(); f.updatedAt = f.createdAt; f.deletedAt = nil
        v.files.append(f)
        log(&v, .fileAdded, f.caseId)
        save(id, v)
        return f
    }
    func updateFile(_ r: FileRecordDTO, _ rev: Int) async throws -> FileRecordDTO {
        await pause()
        var (id, v) = try vault()
        guard let i = v.files.firstIndex(where: { $0.id == r.id }) else { throw APIError.notFound }
        guard v.files[i].revision == rev else { throw APIError.conflict }
        v.files[i].sealedMetadata = r.sealedMetadata
        v.files[i].revision += 1; v.files[i].updatedAt = Date()
        save(id, v)
        return v.files[i]
    }
    func upload(_ fid: String, _ data: Data, _ sha: String, _ progress: @escaping @Sendable (Double) -> Void) async throws {
        await pause()
        var (id, v) = try vault()
        guard let f = v.files.first(where: { $0.id == fid }) else { throw APIError.notFound }
        progress(0.3); progress(0.7)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == sha, sha == f.ciphertextSha256, Int64(data.count) == f.ciphertextSize else { throw APIError.integrityFailed }
        v.blobs[fid] = data; save(id, v)
        progress(1)
    }
    func download(_ fid: String) async throws -> Data {
        await pause()
        let (_, v) = try vault()
        guard v.files.contains(where: { $0.id == fid }), let d = v.blobs[fid] else { throw APIError.notFound }
        return d
    }
    func softDelete(_ fid: String) async throws {
        await pause()
        var (id, v) = try vault()
        guard let i = v.files.firstIndex(where: { $0.id == fid }) else { throw APIError.notFound }
        if v.files[i].deletedAt == nil {
            v.files[i].deletedAt = Date(); v.files[i].revision += 1; v.files[i].updatedAt = Date()
            log(&v, .fileTrashed, v.files[i].caseId)
        }
        save(id, v)
    }
    func restore(_ fid: String) async throws -> FileRecordDTO {
        await pause()
        var (id, v) = try vault()
        guard let i = v.files.firstIndex(where: { $0.id == fid }) else { throw APIError.notFound }
        if v.files[i].deletedAt != nil {
            v.files[i].deletedAt = nil; v.files[i].revision += 1; v.files[i].updatedAt = Date()
            log(&v, .fileRestored, v.files[i].caseId)
        }
        save(id, v)
        return v.files[i]
    }
    func purgeFile(_ fid: String) async throws {
        await pause()
        var (id, v) = try vault()
        guard v.files.contains(where: { $0.id == fid }) else { throw APIError.notFound }
        v.files.removeAll { $0.id == fid }; v.blobs[fid] = nil
        save(id, v)
    }

    // MARK: Sessions (1.1.0)
    func listSessions() async throws -> [SessionInfoDTO] {
        await pause(); let (_, v) = try vault(); return v.sessions.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }
    func revokeSession(_ sid: String) async throws {
        await pause(); var (id, v) = try vault()
        guard let s = v.sessions.first(where: { $0.id == sid }) else { throw APIError.notFound }
        guard !s.isCurrent else { throw APIError.validation("Текущий сеанс завершается выходом из аккаунта") }
        v.sessions.removeAll { $0.id == sid }; save(id, v)
    }
    func revokeOthers() async throws {
        await pause(); var (id, v) = try vault(); v.sessions.removeAll { !$0.isCurrent }; save(id, v)
    }

    // MARK: Versions (1.1.0)
    func listVersions(_ fid: String) async throws -> [FileVersionDTO] {
        await pause(); let (_, v) = try vault()
        guard v.files.contains(where: { $0.id == fid }) else { throw APIError.notFound }
        return v.versions[fid] ?? []
    }
    func replaceContent(_ fid: String, _ r: ReplaceFileRequest) async throws -> FileRecordDTO {
        await pause(); var (id, v) = try vault()
        guard let i = v.files.firstIndex(where: { $0.id == fid }) else { throw APIError.notFound }
        guard v.files[i].revision == r.expectedRevision else { throw APIError.conflict }
        if used(v) - v.files[i].ciphertextSize + r.ciphertextSize > limit { throw APIError.quotaExceeded(limitBytes: limit) }
        let old = v.files[i]
        let ver = FileVersionDTO(id: UUID().uuidString.lowercased(), fileId: fid, sealedMetadata: old.sealedMetadata,
                                 ciphertextSize: old.ciphertextSize, ciphertextSha256: old.ciphertextSha256, createdAt: old.updatedAt)
        v.versions[fid, default: []].insert(ver, at: 0)
        if let b = v.blobs[fid] { v.versionBlobs[ver.id] = b }
        v.files[i].sealedMetadata = r.sealedMetadata
        v.files[i].ciphertextSize = r.ciphertextSize; v.files[i].ciphertextSha256 = r.ciphertextSha256
        v.files[i].revision += 1; v.files[i].updatedAt = Date()
        v.blobs[fid] = nil   // ждём uploadCiphertext
        save(id, v); return v.files[i]
    }
    func downloadVersion(_ vid: String) async throws -> Data {
        await pause(); let (_, v) = try vault()
        guard let d = v.versionBlobs[vid] else { throw APIError.notFound }
        return d
    }
    func restoreVersion(_ fid: String, _ vid: String) async throws -> FileRecordDTO {
        await pause(); var (id, v) = try vault()
        guard let i = v.files.firstIndex(where: { $0.id == fid }), let vi = v.versions[fid]?.firstIndex(where: { $0.id == vid }),
              let vBlob = v.versionBlobs[vid] else { throw APIError.notFound }
        let chosen = v.versions[fid]![vi]
        let cur = v.files[i]
        let curBlob = v.blobs[fid]
        v.versions[fid]![vi] = FileVersionDTO(id: vid, fileId: fid, sealedMetadata: cur.sealedMetadata, ciphertextSize: cur.ciphertextSize,
                                              ciphertextSha256: cur.ciphertextSha256, createdAt: cur.updatedAt)
        v.versionBlobs[vid] = curBlob
        v.files[i].sealedMetadata = chosen.sealedMetadata; v.files[i].ciphertextSize = chosen.ciphertextSize
        v.files[i].ciphertextSha256 = chosen.ciphertextSha256; v.files[i].revision += 1; v.files[i].updatedAt = Date()
        v.blobs[fid] = vBlob
        save(id, v); return v.files[i]
    }

    // MARK: Billing (1.1.0)
    func subscription() async throws -> SubscriptionDTO { await pause(); let (_, v) = try vault(); return v.subscription }
    func purchase(_ r: PurchaseRequest) async throws -> SubscriptionDTO {
        await pause(); var (id, v) = try vault()
        guard let plan = MockStore.plans.first(where: { $0.id == r.planId }) else { throw APIError.validation("Неизвестный тариф") }
        let renews: Date? = plan.period == .free ? nil : Calendar.current.date(byAdding: plan.period == .year ? .year : .month, value: 1, to: Date())
        v.subscription = SubscriptionDTO(planId: plan.id, status: .active, renewsAt: renews)
        limit = plan.storageBytes; save(id, v); return v.subscription
    }
    func cancelSub() async throws -> SubscriptionDTO {
        await pause(); var (id, v) = try vault()
        v.subscription.status = v.subscription.planId == "free" ? .active : .cancelled
        save(id, v); return v.subscription
    }

    // MARK: Audit
    func auditList(_ limit: Int) async throws -> [AuditEventDTO] { await pause(); let (_, v) = try vault(); return Array(v.audit.prefix(max(0, limit))) }
    func auditRecord(_ kind: AuditKind, _ cid: String?) async throws {
        await pause()
        var (id, v) = try vault(); log(&v, kind, cid); save(id, v)
    }

    // MARK: Хуки
    func tamper(_ fid: String) {
        for (k, var v) in vaults {
            if var d = v.blobs[fid], !d.isEmpty { d[d.count / 2] ^= 0xFF; v.blobs[fid] = d; vaults[k] = v }
        }
    }
    func setLimit(_ b: Int64) { limit = b }
    func backdate(_ fid: String, _ days: Int) {
        for (k, var v) in vaults {
            if let i = v.files.firstIndex(where: { $0.id == fid }) {
                v.files[i].deletedAt = Date().addingTimeInterval(-Double(days) * 86_400); vaults[k] = v
            }
        }
    }
}

struct MockAuthAPI: AuthAPI {
    let s: MockStore
    func register(_ r: RegisterRequest) async throws -> SessionDTO { try await s.register(r) }
    func login(_ r: LoginRequest) async throws -> LoginResponse { try await s.login(r) }
    func verifyMFA(_ r: MFAVerifyRequest) async throws -> SessionDTO { try await s.verifyMFA(r) }
    func restoreSession() async -> SessionDTO? { await s.restore() }
    func logout() async throws { try await s.logout() }
    func requestPasswordReset(email: String) async throws { try await s.resetPassword(email) }
}
struct MockAccountAPI: AccountAPI {
    let s: MockStore
    func me() async throws -> AccountDTO { try await s.me() }
    func updateBackupEmail(_ email: String?) async throws -> AccountDTO { try await s.updateBackupEmail(email) }
    func setMFA(enabled: Bool, method: MFAMethod) async throws -> MFASetupDTO? { try await s.setMFA(enabled, method) }
    func storageUsage() async throws -> StorageUsageDTO { try await s.storage() }
    func listSessions() async throws -> [SessionInfoDTO] { try await s.listSessions() }
    func revokeSession(id: String) async throws { try await s.revokeSession(id) }
    func revokeOtherSessions() async throws { try await s.revokeOthers() }
}
struct MockCasesAPI: CasesAPI {
    let s: MockStore
    func list() async throws -> [CaseRecordDTO] { try await s.listCases() }
    func create(_ record: CaseRecordDTO) async throws -> CaseRecordDTO { try await s.createCase(record) }
    func update(_ record: CaseRecordDTO, expectedRevision: Int) async throws -> CaseRecordDTO { try await s.updateCase(record, expectedRevision) }
    func purge(id: String) async throws { try await s.purgeCase(id) }
}
struct MockFilesAPI: FilesAPI {
    let s: MockStore
    func list(caseId: String) async throws -> [FileRecordDTO] { try await s.listFiles(caseId) }
    func listTrash() async throws -> [FileRecordDTO] { try await s.listTrash() }
    func create(_ record: FileRecordDTO) async throws -> FileRecordDTO { try await s.createFile(record) }
    func update(_ record: FileRecordDTO, expectedRevision: Int) async throws -> FileRecordDTO { try await s.updateFile(record, expectedRevision) }
    func uploadCiphertext(fileId: String, data: Data, sha256: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await s.upload(fileId, data, sha256, progress)
    }
    func downloadCiphertext(fileId: String) async throws -> Data { try await s.download(fileId) }
    func softDelete(id: String) async throws { try await s.softDelete(id) }
    func restore(id: String) async throws -> FileRecordDTO { try await s.restore(id) }
    func purge(id: String) async throws { try await s.purgeFile(id) }
    func listVersions(fileId: String) async throws -> [FileVersionDTO] { try await s.listVersions(fileId) }
    func replaceContent(fileId: String, request: ReplaceFileRequest) async throws -> FileRecordDTO { try await s.replaceContent(fileId, request) }
    func downloadVersionCiphertext(versionId: String) async throws -> Data { try await s.downloadVersion(versionId) }
    func restoreVersion(fileId: String, versionId: String) async throws -> FileRecordDTO { try await s.restoreVersion(fileId, versionId) }
}
struct MockBillingAPI: BillingAPI {
    let s: MockStore
    func plans() async throws -> [PlanDTO] { MockStore.plans }
    func subscription() async throws -> SubscriptionDTO { try await s.subscription() }
    func purchase(_ request: PurchaseRequest) async throws -> SubscriptionDTO { try await s.purchase(request) }
    func cancelSubscription() async throws -> SubscriptionDTO { try await s.cancelSub() }
}
struct MockAuditAPI: AuditAPI {
    let s: MockStore
    func list(limit: Int) async throws -> [AuditEventDTO] { try await s.auditList(limit) }
    func record(kind: AuditKind, caseId: String?) async throws { try await s.auditRecord(kind, caseId) }
}
