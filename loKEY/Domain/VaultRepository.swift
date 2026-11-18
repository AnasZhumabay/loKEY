// Единственный интерфейс, через который UI общается с «данными».
// UI не знает ни про сеть, ни про шифрование. Реализация (`VaultRepositoryImpl`)
// шифрует/расшифровывает на устройстве и ходит в бэкенд через `APIServices`.
import Foundation

protocol VaultRepository: Sendable {
    // MARK: Сессия
    func restoreSession() async -> AccountDTO?
    func register(email: String, username: String, password: String) async throws -> AccountDTO
    func login(identifier: String, password: String) async throws -> LoginOutcome
    func verifyMFA(challengeId: String, code: String) async throws -> AccountDTO
    func requestPasswordReset(email: String) async throws
    func logout() async throws

    // MARK: Аккаунт
    func updateBackupEmail(_ email: String?) async throws -> AccountDTO
    func setMFA(enabled: Bool, method: MFAKind) async throws -> MFASetup?
    func storageUsage() async throws -> StorageUsage
    func auditLog(limit: Int) async throws -> [AuditEvent]

    // MARK: Кейсы
    func listCases() async throws -> [VaultCase]
    func createCase(name: String, icon: CaseIcon, level: SecurityLevel) async throws -> NewCaseResult
    func updateCase(id: String, name: String?, icon: CaseIcon?, level: SecurityLevel?, favorite: Bool?) async throws -> VaultCase
    func unlockStatus(caseID: String) async -> UnlockStatus
    /// Бросает `.wrongKey`, `.invalidKeyFormat`, `.lockedOut`, `.biometricsFailed`.
    func unlockCase(id: String, method: UnlockMethod) async throws
    /// Восстановить доступ по 12 словам (если ключ потерян) — после успеха кейс открыт.
    func recoverCase(id: String, words: [String]) async throws
    func lockCase(id: String) async
    func lockAll() async
    func exportKey(caseID: String) async throws -> ExportedKey
    /// Навсегда, без отката (экран «Удаление кейса»).
    func purgeCase(id: String) async throws

    // MARK: Файлы (кейс должен быть открыт, иначе `.notUnlocked`)
    func listFiles(caseID: String) async throws -> [VaultFile]
    /// Избранные файлы только из ОТКРЫТЫХ кейсов.
    func favoriteFiles() async throws -> [VaultFile]
    func addFile(caseID: String, name: String, kind: FileKind, data: Data, note: String?, ocrText: String?,
                 progress: @escaping @Sendable (UploadProgress) -> Void) async throws -> VaultFile
    /// Расшифровывает в память. Бросает `.integrityFailed`, если файл изменён.
    func openFile(id: String) async throws -> Data
    func updateFile(id: String, name: String?, note: String?, favorite: Bool?, offline: Bool?) async throws -> VaultFile
    /// Перешифровывает файлы ключом другого кейса (оба кейса должны быть открыты).
    func moveFiles(ids: [String], toCaseID: String) async throws
    func trashFiles(ids: [String]) async throws
    func listTrash() async throws -> [VaultFile]
    func restoreFile(id: String) async throws
    func purgeFile(id: String) async throws

    // MARK: Версии файла (кейс должен быть открыт)
    /// Текущая версия первой (isCurrent), затем предыдущие, новые первыми.
    func listVersions(fileID: String) async throws -> [FileVersion]
    /// Новое содержимое: прежнее состояние сохраняется как версия. Возвращает обновлённый файл.
    func replaceFileContent(fileID: String, data: Data, progress: @escaping @Sendable (UploadProgress) -> Void) async throws -> VaultFile
    func openVersion(fileID: String, versionID: String) async throws -> Data
    func restoreVersion(fileID: String, versionID: String) async throws -> VaultFile

    // MARK: Сеансы
    func listSessions() async throws -> [DeviceSession]
    func revokeSession(id: String) async throws
    func revokeOtherSessions() async throws

    // MARK: Тарифы
    func plans() async throws -> [StoragePlan]
    func subscription() async throws -> PlanSubscription
    /// transaction — подтверждение покупки из StoreKit (nil в мок-режиме).
    func purchase(planID: String, transaction: String?) async throws -> PlanSubscription
    func cancelSubscription() async throws -> PlanSubscription

    // MARK: Безопасность (клиентская часть)
    /// PIN «под принуждением» (6 цифр, хранится только как соленый PBKDF2-хэш). nil — выключить.
    func setDuressPIN(_ pin: String?) async throws
    var duressEnabled: Bool { get async }
    /// true — PIN совпал с «принудительным»: репозиторий переключился на приманку (реальные данные не загружались).
    func unlockAppWithDuress(pin: String) async -> Bool
    func setWipePolicy(_ policy: WipePolicy) async
    var wipePolicy: WipePolicy { get async }

    // MARK: Поиск (только открытые кейсы, на устройстве)
    func searchAll(query: String) async -> [FileSearchHit]
    /// Сколько кейсов пропущено, потому что закрыты.
    func searchSkippedLockedCount() async -> Int

    // MARK: Локальное зашифрованное хранение (сессия, кэш кейсов, история чата)
    /// Снимок аккаунта с прошлого запуска (расшифрован ключом устройства) или nil.
    func offlineSnapshot() async -> AccountSnapshot?
    /// Кейсы из зашифрованного кэша — мгновенно, до ответа сервера. Все закрыты.
    func cachedCases(for snapshot: AccountSnapshot) async -> [VaultCase]
    /// Только мок-режим: бэкенд живёт в памяти и после перезапуска пуст, поэтому сессию создаём заново. В «живом» режиме всегда nil.
    func resumeOfflineSession(_ snapshot: AccountSnapshot) async -> AccountDTO?
    /// Зашифрованное хранилище истории чата для `ChatRepository.configure(…historyStore:)`.
    func makeHistoryStore() async -> HistoryStore?
    /// Выход: стирает снимок сессии и кэш кейсов; историю чата — только при `wipeChats`.
    func clearLocalPersistence(wipeChats: Bool) async
    /// true — сейчас работает приманка («под принуждением»): настоящие данные, резервные копии, напоминания и общие кейсы недоступны.
    var isDecoy: Bool { get async }
    /// Открыть кейс секретом из приглашения общего кейса. НЕ считается попыткой подбора (счётчик/стирание не затрагиваются).
    func unlockSharedCase(id: String, secret: Data) async throws
}

extension VaultRepository {
    var isDecoy: Bool { get async { false } }
    func unlockSharedCase(id: String, secret: Data) async throws { try await unlockCase(id: id, method: .keyString(KeyFormat.format(secret))) }
    func addFile(caseID: String, name: String, kind: FileKind, data: Data, note: String?,
                 progress: @escaping @Sendable (UploadProgress) -> Void) async throws -> VaultFile {
        try await addFile(caseID: caseID, name: name, kind: kind, data: data, note: note, ocrText: nil, progress: progress)
    }
}

/// Значения по умолчанию: другие реализации (заглушки, превью) продолжают компилироваться.
extension VaultRepository {
    func setDuressPIN(_ pin: String?) async throws {}
    var duressEnabled: Bool { get async { false } }
    func unlockAppWithDuress(pin: String) async -> Bool { false }
    func setWipePolicy(_ policy: WipePolicy) async {}
    var wipePolicy: WipePolicy { get async { .off } }
    func searchAll(query: String) async -> [FileSearchHit] { [] }
    func searchSkippedLockedCount() async -> Int { 0 }
    func offlineSnapshot() async -> AccountSnapshot? { nil }
    func cachedCases(for snapshot: AccountSnapshot) async -> [VaultCase] { [] }
    func resumeOfflineSession(_ snapshot: AccountSnapshot) async -> AccountDTO? { nil }
    func makeHistoryStore() async -> HistoryStore? { nil }
    func clearLocalPersistence(wipeChats: Bool) async {}
}
