// ═══════════════════════════════════════════════════════════════════════════
//  CONTRACT · протоколы сервисов (то, что реализует бэкенд)
//
//  Бэкендер пишет классы `Live…API`, которые соответствуют этим протоколам,
//  и возвращает их из `LiveBackend.makeServices(baseURL:)`. Больше ничего в
//  приложении менять не нужно: включить — `AppConfig.useMocks = false`.
//  Все методы бросают ТОЛЬКО `APIError`.
// ═══════════════════════════════════════════════════════════════════════════
import Foundation

protocol AuthAPI: Sendable {
    func register(_ request: RegisterRequest) async throws -> SessionDTO
    func login(_ request: LoginRequest) async throws -> LoginResponse
    func verifyMFA(_ request: MFAVerifyRequest) async throws -> SessionDTO
    /// Восстановить сессию из безопасного хранилища (если есть и не истекла).
    func restoreSession() async -> SessionDTO?
    func logout() async throws
    func requestPasswordReset(email: String) async throws
}

protocol AccountAPI: Sendable {
    func me() async throws -> AccountDTO
    func updateBackupEmail(_ email: String?) async throws -> AccountDTO
    /// enabled=true → вернуть данные настройки (otpauth для authenticator).
    func setMFA(enabled: Bool, method: MFAMethod) async throws -> MFASetupDTO?
    func storageUsage() async throws -> StorageUsageDTO
    // 1.1.0
    /// Все активные сеансы аккаунта, текущий — с isCurrent = true.
    func listSessions() async throws -> [SessionInfoDTO]
    func revokeSession(id: String) async throws
    /// Завершить все сеансы, кроме текущего.
    func revokeOtherSessions() async throws
}

protocol CasesAPI: Sendable {
    /// Только не удалённые кейсы пользователя.
    func list() async throws -> [CaseRecordDTO]
    /// Идемпотентно: повторный вызов с тем же id возвращает существующую запись.
    func create(_ record: CaseRecordDTO) async throws -> CaseRecordDTO
    /// `.conflict`, если expectedRevision != текущей revision на сервере.
    func update(_ record: CaseRecordDTO, expectedRevision: Int) async throws -> CaseRecordDTO
    /// Навсегда: удаляет кейс и все его файлы и blob'ы. Откатить нельзя.
    func purge(id: String) async throws
}

protocol FilesAPI: Sendable {
    /// Только не удалённые файлы кейса.
    func list(caseId: String) async throws -> [FileRecordDTO]
    /// Файлы в корзине (deletedAt != nil) всех кейсов пользователя.
    func listTrash() async throws -> [FileRecordDTO]
    func create(_ record: FileRecordDTO) async throws -> FileRecordDTO
    func update(_ record: FileRecordDTO, expectedRevision: Int) async throws -> FileRecordDTO
    /// Загрузка шифртекста. Сервер считает SHA-256 и сверяет с `sha256`,
    /// иначе `.integrityFailed`. progress: 0...1, вызывается с любого потока.
    func uploadCiphertext(fileId: String, data: Data, sha256: String,
                          progress: @escaping @Sendable (Double) -> Void) async throws
    func downloadCiphertext(fileId: String) async throws -> Data
    /// В корзину (ставит deletedAt). Через 30 дней сервер удаляет сам.
    func softDelete(id: String) async throws
    func restore(id: String) async throws -> FileRecordDTO
    func purge(id: String) async throws
    // 1.1.0 · версии
    /// Предыдущие версии, новые первыми (текущая сюда не входит).
    func listVersions(fileId: String) async throws -> [FileVersionDTO]
    /// Атомарно: текущее состояние уходит в версии, ревизия +1. Затем клиент вызывает uploadCiphertext для fileId.
    /// `.conflict`, если expectedRevision не совпал.
    func replaceContent(fileId: String, request: ReplaceFileRequest) async throws -> FileRecordDTO
    func downloadVersionCiphertext(versionId: String) async throws -> Data
    /// Меняет местами текущее состояние и выбранную версию. Возвращает обновлённый файл.
    func restoreVersion(fileId: String, versionId: String) async throws -> FileRecordDTO
}

protocol BillingAPI: Sendable {
    func plans() async throws -> [PlanDTO]
    func subscription() async throws -> SubscriptionDTO
    /// После покупки на устройстве (StoreKit) — подтвердить на сервере; сервер поднимает лимит хранилища.
    func purchase(_ request: PurchaseRequest) async throws -> SubscriptionDTO
    func cancelSubscription() async throws -> SubscriptionDTO
}

protocol AuditAPI: Sendable {
    func list(limit: Int) async throws -> [AuditEventDTO]
    /// Клиент сообщает о событиях, которые сервер сам не видит (разблокировка, блокировка).
    func record(kind: AuditKind, caseId: String?) async throws
}

/// 1.2.0 · Защищённый чат. Все методы бросают ТОЛЬКО `APIError`.
protocol ChatAPI: Sendable {
    /// Публикует (или обновляет) публичный ключ текущего пользователя. Идемпотентно.
    func registerIdentity(publicKey: Data) async throws -> ChatUserDTO
    /// Профиль и публичный ключ другого пользователя. `.notFound`, если такого нет.
    func findUser(id: String) async throws -> ChatUserDTO
    /// Кладёт конверт в очередь получателя. Повтор с тем же id игнорируется.
    func send(_ envelope: ChatEnvelopeDTO) async throws
    /// Входящие конверты текущего пользователя, старые первыми. Не удаляет их до `acknowledge`.
    func fetch(limit: Int) async throws -> [ChatEnvelopeDTO]
    /// Подтверждение: сервер удаляет эти конверты из очереди.
    func acknowledge(ids: [String]) async throws
}

/// Набор сервисов, который приложение получает целиком.
struct APIServices: Sendable {
    var auth: AuthAPI
    var account: AccountAPI
    var cases: CasesAPI
    var files: FilesAPI
    var audit: AuditAPI
    var billing: BillingAPI
    var chat: ChatAPI
    // 1.3.0 · с умолчаниями, чтобы прежние инициализаторы компилировались. По умолчанию — «не реализовано».
    var sharedCases: SharedCaseAPI = UnavailableSharedCaseAPI()
    var backup: BackupAPI = UnavailableBackupAPI()
    var chatGroups: ChatGroupAPI = UnavailableChatGroupAPI()
    var securityEvents: SecurityEventAPI = UnavailableSecurityEventAPI()
}
