// Живой REST-клиент. Таблица эндпоинтов — Docs/BACKEND_CONTRACT.md.
// JSON через LKCoding, Bearer-токен, токены в Keychain, 401 → один refresh → повтор.
import Foundation

enum LiveBackend {
    static func makeServices(baseURL: URL) -> APIServices {
        let http = LiveHTTP(baseURL: baseURL)
        return APIServices(auth: LiveAuthAPI(http: http), account: LiveAccountAPI(http: http), cases: LiveCasesAPI(http: http),
                           files: LiveFilesAPI(http: http), audit: LiveAuditAPI(http: http), billing: LiveBillingAPI(http: http), chat: LiveChatAPI(http: http),
                           sharedCases: LiveSharedCaseAPI(http: http), backup: LiveBackupAPI(http: http),
                           chatGroups: LiveChatGroupAPI(http: http), securityEvents: LiveSecurityEventAPI(http: http))
    }
}

private struct Empty: Codable {}
private struct RefreshBody: Codable { var refreshToken: String }
private struct EmailBody: Codable { var email: String }
/// null пишем ЯВНО: «очистить запасной email» (синтезированный Encodable пропустил бы ключ).
private struct BackupBody: Codable {
    var backupEmail: String?
    enum CodingKeys: String, CodingKey { case backupEmail }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backupEmail, forKey: .backupEmail)
    }
}
private struct MFABody: Codable { var enabled: Bool; var method: MFAMethod }
private struct AuditBody: Codable { var kind: AuditKind; var caseId: String? }

actor LiveHTTP {
    let baseURL: URL
    private let urlSession: URLSession
    private let store: KeyStore
    private var session: SessionDTO?
    private var loaded = false
    private var refreshTask: Task<SessionDTO, Error>?

    init(baseURL: URL, store: KeyStore = KeychainKeyStore(service: "com.lokey.tokens")) {
        self.baseURL = baseURL
        self.store = store
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: cfg)
    }

    // MARK: Токены
    private func current() -> SessionDTO? {
        if !loaded {
            loaded = true
            if let d = store.read("session") { session = try? LKCoding.decoder.decode(SessionDTO.self, from: d) }
        }
        return session
    }
    func setSession(_ s: SessionDTO?) {
        loaded = true; session = s
        if let s, let d = try? LKCoding.encoder.encode(s) { try? store.write(d, account: "session") } else { store.delete("session") }
    }
    func currentSession() -> SessionDTO? { current() }

    private func refreshSession() async throws -> SessionDTO {
        if let t = refreshTask { return try await t.value }
        guard let rt = current()?.refreshToken else { throw APIError.unauthorized }
        let t = Task { () throws -> SessionDTO in
            let data = try await self.raw("POST", "/v1/auth/refresh", body: try LKCoding.encoder.encode(RefreshBody(refreshToken: rt)),
                                          contentType: "application/json", auth: false, retry: false)
            return try Self.decode(SessionDTO.self, data)
        }
        refreshTask = t
        defer { refreshTask = nil }
        do { let s = try await t.value; setSession(s); return s }
        catch let e as APIError {
            // Сессию стираем только когда сервер ОТКАЗАЛ в обновлении. Сбой сети или 5xx не должен разлогинивать.
            switch e {
            case .unauthorized, .forbidden, .mfaInvalid: setSession(nil); throw APIError.unauthorized
            default: throw e
            }
        } catch { throw APIError.network }
    }

    // MARK: Запросы
    static func decode<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T {
        do { return try LKCoding.decoder.decode(t, from: d) } catch { throw APIError.server("Некорректный ответ сервера") }
    }

    func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, contentType: String? = nil,
             headers: [String: String] = [:], auth: Bool = true, retry: Bool = true,
             progress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw APIError.validation("bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(path.hasSuffix("/blob") ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Accept")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if auth {
            guard let tok = current()?.accessToken else { throw APIError.unauthorized }
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        }
        let data: Data, resp: URLResponse
        do {
            if let body, let progress, method == "PUT" {
                (data, resp) = try await urlSession.upload(for: req, from: body, delegate: ProgressDelegate(progress))
            } else {
                req.httpBody = body
                (data, resp) = try await urlSession.data(for: req)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw APIError.network }
        guard let http = resp as? HTTPURLResponse else { throw APIError.network }
        if (200..<300).contains(http.statusCode) { return data }
        if http.statusCode == 401, auth, retry,
           (try? LKCoding.decoder.decode(APIErrorEnvelope.self, from: data))?.code != "mfa_invalid" {
            _ = try await refreshSession()
            return try await raw(method, path, query: query, body: body, contentType: contentType, headers: headers,
                                 auth: auth, retry: false, progress: progress)
        }
        if let env = try? LKCoding.decoder.decode(APIErrorEnvelope.self, from: data) { throw APIError.from(env) }
        switch http.statusCode {
        case 401: throw APIError.unauthorized
        case 403: throw APIError.forbidden
        case 404: throw APIError.notFound
        case 409: throw APIError.conflict
        case 413: throw APIError.quotaExceeded(limitBytes: 0)
        case 422: throw APIError.integrityFailed
        case 429: throw APIError.rateLimited(retryAfterSeconds: Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60)
        case 400: throw APIError.validation("")
        default: throw APIError.server("")
        }
    }

    func json<B: Encodable, R: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: B,
                                          headers: [String: String] = [:], auth: Bool = true) async throws -> R {
        let d = try await raw(method, path, query: query, body: try LKCoding.encoder.encode(body), contentType: "application/json", headers: headers, auth: auth)
        return try Self.decode(R.self, d)
    }
    func get<R: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> R {
        try Self.decode(R.self, try await raw("GET", path, query: query))
    }
    func send<B: Encodable>(_ method: String, _ path: String, body: B? = Optional<Empty>.none, headers: [String: String] = [:], auth: Bool = true) async throws {
        _ = try await raw(method, path, body: try body.map { try LKCoding.encoder.encode($0) },
                          contentType: body == nil ? nil : "application/json", headers: headers, auth: auth)
    }
}

private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let cb: @Sendable (Double) -> Void
    init(_ cb: @escaping @Sendable (Double) -> Void) { self.cb = cb }
    func urlSession(_ s: URLSession, task: URLSessionTask, didSendBodyData b: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { cb(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
}

struct LiveAuthAPI: AuthAPI {
    let http: LiveHTTP
    func register(_ r: RegisterRequest) async throws -> SessionDTO {
        let s: SessionDTO = try await http.json("POST", "/v1/auth/register", body: r, auth: false)
        await http.setSession(s); return s
    }
    func login(_ r: LoginRequest) async throws -> LoginResponse {
        let resp: LoginResponse = try await http.json("POST", "/v1/auth/login", body: r, auth: false)
        if let s = resp.session { await http.setSession(s) }
        return resp
    }
    func verifyMFA(_ r: MFAVerifyRequest) async throws -> SessionDTO {
        let s: SessionDTO = try await http.json("POST", "/v1/auth/mfa/verify", body: r, auth: false)
        await http.setSession(s); return s
    }
    func restoreSession() async -> SessionDTO? {
        guard let s = await http.currentSession() else { return nil }
        if s.expiresAt > Date() { return s }
        do {
            let d = try await http.raw("POST", "/v1/auth/refresh", body: try? LKCoding.encoder.encode(RefreshBody(refreshToken: s.refreshToken)),
                                       contentType: "application/json", auth: false, retry: false)
            guard let n = try? LKCoding.decoder.decode(SessionDTO.self, from: d) else { return s }
            await http.setSession(n); return n
        } catch let e as APIError {
            switch e {
            case .unauthorized, .forbidden, .mfaInvalid: await http.setSession(nil); return nil
            default: return s      // нет сети: остаёмся в аккаунте, обновим токен при первом запросе
            }
        } catch { return s }
    }
    func logout() async throws {
        defer { Task { await http.setSession(nil) } }
        try await http.send("POST", "/v1/auth/logout", body: Optional<Empty>.none)
    }
    func requestPasswordReset(email: String) async throws {
        try await http.send("POST", "/v1/auth/password-reset", body: EmailBody(email: email), auth: false)
    }
}

struct LiveAccountAPI: AccountAPI {
    let http: LiveHTTP
    func me() async throws -> AccountDTO { try await http.get("/v1/account") }
    func updateBackupEmail(_ email: String?) async throws -> AccountDTO {
        try await http.json("PATCH", "/v1/account", body: BackupBody(backupEmail: email))
    }
    func setMFA(enabled: Bool, method: MFAMethod) async throws -> MFASetupDTO? {
        let d = try await http.raw("PUT", "/v1/account/mfa", body: try LKCoding.encoder.encode(MFABody(enabled: enabled, method: method)), contentType: "application/json")
        return d.isEmpty ? nil : try LiveHTTP.decode(MFASetupDTO?.self, d)
    }
    func storageUsage() async throws -> StorageUsageDTO { try await http.get("/v1/account/storage") }
    func listSessions() async throws -> [SessionInfoDTO] { try await http.get("/v1/account/sessions") }
    func revokeSession(id: String) async throws { try await http.send("DELETE", "/v1/account/sessions/\(id)", body: Optional<Empty>.none) }
    func revokeOtherSessions() async throws { try await http.send("POST", "/v1/account/sessions/revoke-others", body: Optional<Empty>.none) }
}

struct LiveCasesAPI: CasesAPI {
    let http: LiveHTTP
    func list() async throws -> [CaseRecordDTO] { try await http.get("/v1/cases") }
    func create(_ record: CaseRecordDTO) async throws -> CaseRecordDTO { try await http.json("POST", "/v1/cases", body: record) }
    func update(_ record: CaseRecordDTO, expectedRevision: Int) async throws -> CaseRecordDTO {
        try await http.json("PUT", "/v1/cases/\(record.id)", body: record, headers: ["If-Match": String(expectedRevision)])
    }
    func purge(id: String) async throws { try await http.send("DELETE", "/v1/cases/\(id)", body: Optional<Empty>.none) }
}

struct LiveFilesAPI: FilesAPI {
    let http: LiveHTTP
    func list(caseId: String) async throws -> [FileRecordDTO] { try await http.get("/v1/cases/\(caseId)/files") }
    func listTrash() async throws -> [FileRecordDTO] { try await http.get("/v1/trash/files") }
    func create(_ record: FileRecordDTO) async throws -> FileRecordDTO { try await http.json("POST", "/v1/files", body: record) }
    func update(_ record: FileRecordDTO, expectedRevision: Int) async throws -> FileRecordDTO {
        try await http.json("PUT", "/v1/files/\(record.id)", body: record, headers: ["If-Match": String(expectedRevision)])
    }
    func uploadCiphertext(fileId: String, data: Data, sha256: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await http.raw("PUT", "/v1/files/\(fileId)/blob", body: data, contentType: "application/octet-stream",
                               headers: ["X-Content-SHA256": sha256], progress: progress)
    }
    func downloadCiphertext(fileId: String) async throws -> Data { try await http.raw("GET", "/v1/files/\(fileId)/blob") }
    func softDelete(id: String) async throws { try await http.send("POST", "/v1/files/\(id)/trash", body: Optional<Empty>.none) }
    func restore(id: String) async throws -> FileRecordDTO {
        try await http.json("POST", "/v1/files/\(id)/restore", body: Empty())
    }
    func purge(id: String) async throws { try await http.send("DELETE", "/v1/files/\(id)", body: Optional<Empty>.none) }
    func listVersions(fileId: String) async throws -> [FileVersionDTO] { try await http.get("/v1/files/\(fileId)/versions") }
    func replaceContent(fileId: String, request: ReplaceFileRequest) async throws -> FileRecordDTO {
        try await http.json("POST", "/v1/files/\(fileId)/versions", body: request)
    }
    func downloadVersionCiphertext(versionId: String) async throws -> Data { try await http.raw("GET", "/v1/file-versions/\(versionId)/blob") }
    func restoreVersion(fileId: String, versionId: String) async throws -> FileRecordDTO {
        try await http.json("POST", "/v1/files/\(fileId)/versions/\(versionId)/restore", body: Empty())
    }
}

struct LiveBillingAPI: BillingAPI {
    let http: LiveHTTP
    func plans() async throws -> [PlanDTO] { try await http.get("/v1/billing/plans") }
    func subscription() async throws -> SubscriptionDTO { try await http.get("/v1/billing/subscription") }
    func purchase(_ request: PurchaseRequest) async throws -> SubscriptionDTO { try await http.json("POST", "/v1/billing/purchase", body: request) }
    func cancelSubscription() async throws -> SubscriptionDTO { try await http.json("POST", "/v1/billing/cancel", body: Empty()) }
}

struct LiveAuditAPI: AuditAPI {
    let http: LiveHTTP
    /// Неизвестные значения enum от более нового сервера не должны ронять весь журнал: битые элементы пропускаем.
    private struct Lossy: Decodable {
        let value: AuditEventDTO?
        init(from decoder: Decoder) throws { value = try? AuditEventDTO(from: decoder) }
    }
    func list(limit: Int) async throws -> [AuditEventDTO] {
        let items: [Lossy] = try await http.get("/v1/audit", query: [URLQueryItem(name: "limit", value: String(limit))])
        return items.compactMap(\.value)
    }
    func record(kind: AuditKind, caseId: String?) async throws { try await http.send("POST", "/v1/audit", body: AuditBody(kind: kind, caseId: caseId)) }
}

struct LiveChatAPI: ChatAPI {
    let http: LiveHTTP
    private struct KeyBody: Codable { var publicKey: Data }
    private struct AckBody: Codable { var ids: [String] }
    func registerIdentity(publicKey: Data) async throws -> ChatUserDTO { try await http.json("PUT", "/v1/chat/identity", body: KeyBody(publicKey: publicKey)) }
    func findUser(id: String) async throws -> ChatUserDTO { try await http.get("/v1/chat/users/\(id)") }
    func send(_ envelope: ChatEnvelopeDTO) async throws { try await http.send("POST", "/v1/chat/messages", body: envelope) }
    func fetch(limit: Int) async throws -> [ChatEnvelopeDTO] { try await http.get("/v1/chat/messages", query: [URLQueryItem(name: "limit", value: String(limit))]) }
    func acknowledge(ids: [String]) async throws { try await http.send("POST", "/v1/chat/messages/ack", body: AckBody(ids: ids)) }
}
