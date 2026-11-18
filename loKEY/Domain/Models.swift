// Модели, которые видит UI. Они уже РАСШИФРОВАНЫ на устройстве и никогда не уходят на сервер.
import Foundation

enum CaseIcon: String, Codable, CaseIterable, Sendable {
    case document, wallet, health, home, travel, work, photo, key
}

enum FileKind: String, Codable, CaseIterable, Sendable {
    case pdf, jpg, heic, png, video, note, password, card, other
}

/// Содержимое `CaseRecordDTO.sealedHeader` после расшифровки.
struct CaseHeader: Codable, Equatable, Sendable {
    var name: String
    var icon: CaseIcon
    var level: SecurityLevel
    var favorite: Bool
    /// SHA-256(«lokey.check» + ключ кейса), hex. Позволяет проверить введённый ключ даже у пустого кейса.
    var keyCheck: String
}

/// Содержимое `FileRecordDTO.sealedMetadata` после расшифровки.
struct FileMetadata: Codable, Equatable, Sendable {
    var name: String
    var kind: FileKind
    var plainBytes: Int64
    var note: String?
    var favorite: Bool
    var offline: Bool
    /// SHA-256 открытого содержимого (hex). Проверка целостности после расшифровки.
    var contentSha256: String
    /// Распознанный на устройстве текст скана (для поиска). Лежит ВНУТРИ шифртекста, сервер его не видит.
    var ocrText: String? = nil
}

struct VaultCase: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var icon: CaseIcon
    var level: SecurityLevel
    var favorite: Bool
    var fileCount: Int
    var bytes: Int64
    var isUnlocked: Bool
    var updatedAt: Date
    /// Есть ли фраза восстановления на сервере
    var isRecoverable: Bool
}

struct VaultFile: Identifiable, Equatable, Sendable {
    var id: String
    var caseID: String
    var name: String
    var kind: FileKind
    var bytes: Int64
    var note: String?
    var favorite: Bool
    var offline: Bool
    var createdAt: Date
    var deletedAt: Date?
    /// Распознанный текст скана (если пользователь включил распознавание).
    var ocr: String? = nil
}

struct CaseStorage: Equatable, Sendable, Identifiable {
    var id: String { caseID }
    var caseID: String
    var name: String
    var level: SecurityLevel
    var bytes: Int64
}

struct StorageUsage: Equatable, Sendable {
    var usedBytes: Int64
    var limitBytes: Int64
    var perCase: [CaseStorage]
    var fraction: Double { limitBytes > 0 ? min(1, Double(usedBytes) / Double(limitBytes)) : 0 }
    var freeBytes: Int64 { max(0, limitBytes - usedBytes) }
}

struct AuditEvent: Identifiable, Equatable, Sendable {
    var id: String
    var kind: AuditKind
    var caseName: String?
    var deviceName: String
    var at: Date
}

/// Результат создания кейса: ключ показывается пользователю ОДИН раз.
struct NewCaseResult: Equatable, Sendable {
    var vaultCase: VaultCase
    /// 8 групп по 4 символа через дефис: «7F3K-QX92-LM8D-A41Z-H6TP-2WRC-9VBN-E05J»
    var keyString: String
    var keyFileName: String
    var keyFileData: Data
    /// 12 слов восстановления
    var recoveryWords: [String]
}

struct ExportedKey: Equatable, Sendable {
    var keyString: String
    var fileName: String
    var fileData: Data
}

enum UnlockMethod: Sendable {
    case biometrics
    case keyString(String)
    case keyFile(Data)
}

struct UnlockStatus: Equatable, Sendable {
    var attemptsLeft: Int
    var lockedUntil: Date?
}

struct UploadProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable { case encrypting, uploading, verifying, done }
    var stage: Stage
    /// 0...1 внутри текущего этапа
    var fraction: Double
}

enum LoginOutcome: Equatable, Sendable {
    case signedIn(AccountDTO)
    case mfaRequired(challengeId: String)
}

/// Все ошибки, которые видит UI. Тексты для пользователя — в `message`.
enum VaultError: Error, Equatable, Sendable {
    case wrongKey(attemptsLeft: Int)
    case invalidKeyFormat
    case lockedOut(until: Date)
    case notUnlocked
    case integrityFailed(fileID: String)
    case quotaExceeded(limitBytes: Int64)
    case notAuthenticated
    case mfaInvalid
    case recoveryFailed
    case biometricsFailed
    /// После N неверных попыток локальный ключ кейса стёрт с этого устройства (на сервере кейс остался).
    case localKeyWiped
    case validation(String)
    case network
    case server(String)

    var message: String {
        switch self {
        case .wrongKey(let n): return "Ключ не подошёл. Осталось попыток: \(n)"
        case .invalidKeyFormat: return "Ключ неполный или в неверном формате"
        case .lockedOut: return "Кейс заблокирован из-за неверных попыток"
        case .notUnlocked: return "Сначала откройте кейс"
        case .integrityFailed: return "Файл изменён или повреждён"
        case .quotaExceeded: return "Не хватает места в хранилище (1 ГБ)"
        case .notAuthenticated: return "Войдите в аккаунт"
        case .mfaInvalid: return "Неверный код подтверждения"
        case .recoveryFailed: return "Фразы восстановления не подошли"
        case .biometricsFailed: return "Face ID не удалось"
        case .localKeyWiped: return "Ключ этого кейса удалён с устройства. Кейс можно открыть ключом-файлом или по 12 словам"
        case .validation(let m): return m
        case .network: return "Нет соединения. Проверьте интернет"
        case .server(let m): return m.isEmpty ? "Ошибка сервера. Попробуйте позже" : m
        }
    }
}

extension VaultError {
    /// Единственное место, где APIError превращается в VaultError.
    static func from(_ e: APIError) -> VaultError {
        switch e {
        case .unauthorized, .forbidden: return .notAuthenticated
        case .quotaExceeded(let l): return .quotaExceeded(limitBytes: l)
        case .integrityFailed: return .server("Не удалось проверить целостность при загрузке")
        case .mfaInvalid: return .mfaInvalid
        case .validation(let m): return .validation(m)
        case .network: return .network
        case .rateLimited(let s): return .lockedOut(until: Date().addingTimeInterval(TimeInterval(s)))
        case .notFound: return .server("Не найдено")
        case .conflict: return .server("Данные изменились на другом устройстве, обновите экран")
        case .server(let m): return .server(m)
        }
    }
}

// MARK: - 1.1.0 · Сеансы, версии, тарифы

struct DeviceSession: Identifiable, Equatable, Sendable {
    var id: String
    var deviceName: String
    var platform: String
    var appVersion: String?
    var approxLocation: String?
    var createdAt: Date
    var lastActiveAt: Date
    var isCurrent: Bool
}

struct FileVersion: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: FileKind
    var bytes: Int64
    var createdAt: Date
    var isCurrent: Bool
}

enum PlanPeriodKind: Sendable { case free, month, year }

struct StoragePlan: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var storageBytes: Int64
    var priceMinor: Int
    var currency: String
    var period: PlanPeriodKind
}

enum SubscriptionState: Sendable { case active, cancelled, expired }

struct PlanSubscription: Equatable, Sendable {
    var planID: String
    var state: SubscriptionState
    var renewsAt: Date?
}

// MARK: - Двухфакторный вход (доменные типы, UI не знает про DTO)

enum MFAKind: Sendable { case authenticator, sms }

struct MFASetup: Identifiable, Equatable, Sendable {
    var kind: MFAKind
    var otpauthUri: String?
    var id: String { "\(kind)" + (otpauthUri ?? "") }
}

// MARK: - Безопасность: экстренное стирание, поиск, режим «под принуждением»

/// Экстренное стирание локального ключа кейса после N неверных попыток подряд.
/// По умолчанию выключено — действует обычная блокировка на 5 минут.
struct WipePolicy: Codable, Equatable, Sendable {
    var enabled: Bool
    var maxAttempts: Int

    static let allowedRange = 3...10
    static let off = WipePolicy(enabled: false, maxAttempts: 5)

    /// Приводит число попыток к допустимому диапазону 3…10.
    var clamped: WipePolicy { WipePolicy(enabled: enabled, maxAttempts: min(Self.allowedRange.upperBound, max(Self.allowedRange.lowerBound, maxAttempts))) }
    func shouldWipe(failures: Int) -> Bool { enabled && failures >= clamped.maxAttempts }
}

/// Найденный файл (поиск идёт только по ОТКРЫТЫМ кейсам, на устройстве).
struct FileSearchHit: Identifiable, Hashable {
    let id: String
    let fileId: String
    let caseId: String
    let caseName: String
    let fileName: String
    let snippet: String?
    let matchedInOCR: Bool
    let caseIsUnlocked: Bool
}
