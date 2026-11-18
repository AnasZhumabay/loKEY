// ═══════════════════════════════════════════════════════════════════════════
//  CONTRACT · loKEY ↔ Backend            version 1.3.0
//
//  Этот файл и Services.swift — ЕДИНСТВЕННОЕ место, где фронтенд и бэкенд
//  соприкасаются. Правила:
//   • Приложение (UI) никогда не импортирует ничего «живого» — только эти типы.
//   • Сервер видит ТОЛЬКО шифртекст: sealed* поля и blob'ы — непрозрачные байты.
//   • Любое изменение этого файла = новая версия контракта (LKContract.version)
//     и согласование с бэкендером. Ломающие изменения запрещены без MAJOR+1.
//   • id генерирует клиент (UUID v4, строчными буквами) — создание идемпотентно.
//   • JSON: snake_case, даты ISO-8601 (UTC), Data — base64. См. LKCoding.
// ═══════════════════════════════════════════════════════════════════════════
import Foundation

enum LKContract {
    static let version = "1.3.0"   // 1.3.0: + общие кейсы, бэкап, группы, события безопасности (см. ContractV13.swift); 1.1.0: + сеансы, версии файлов, тарифы; 1.2.0: + защищённый чат (только добавления, обратно совместимо)
}

// MARK: - JSON (один кодек на всех — бэкенд обязан соблюдать его формат)

enum LKCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Аккаунт и сессия

struct AccountDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var email: String
    var username: String
    var backupEmail: String?
    var mfaEnabled: Bool
    var createdAt: Date
}

struct SessionDTO: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var account: AccountDTO
}

struct RegisterRequest: Codable, Equatable, Sendable {
    var email: String
    var username: String
    var password: String
}

struct LoginRequest: Codable, Equatable, Sendable {
    /// email ИЛИ username
    var identifier: String
    var password: String
}

/// Ровно одно из полей непусто: либо сессия, либо требуется второй фактор.
struct LoginResponse: Codable, Equatable, Sendable {
    var session: SessionDTO?
    var mfaChallengeId: String?
}

struct MFAVerifyRequest: Codable, Equatable, Sendable {
    var challengeId: String
    var code: String
}

enum MFAMethod: String, Codable, CaseIterable, Sendable {
    case authenticator
    case sms
}

struct MFASetupDTO: Codable, Equatable, Sendable {
    var method: MFAMethod
    /// otpauth://… для Google Authenticator (nil для sms)
    var otpauthUri: String?
}

// MARK: - Кейсы и файлы (сервер хранит только запечатанные данные)

enum SecurityLevel: String, Codable, CaseIterable, Sendable {
    case standard
    case sensitive
    case critical
}

struct CaseRecordDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String
    /// Имя/иконка/уровень/избранное кейса, запечатано ключом хранилища аккаунта (AES-256-GCM).
    var sealedHeader: Data
    /// Ключ кейса, обёрнутый фразой восстановления (PBKDF2 + AES-GCM). Сервер расшифровать не может.
    var recoveryWrappedKey: Data?
    var fileCount: Int
    var storageBytes: Int64
    /// Растёт на 1 при каждом изменении. Используется для optimistic locking.
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}

struct FileRecordDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var caseId: String
    /// Имя, тип, заметка, флаги — запечатано ключом КЕЙСА (AES-256-GCM).
    var sealedMetadata: Data
    var ciphertextSize: Int64
    /// SHA-256 шифртекста (hex, нижний регистр). Сервер сверяет при загрузке.
    var ciphertextSha256: String
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    /// Мягкое удаление (корзина 30 дней). Через 30 дней сервер удаляет навсегда.
    var deletedAt: Date?
}

struct CaseUsageDTO: Codable, Equatable, Sendable {
    var caseId: String
    var bytes: Int64
}

struct StorageUsageDTO: Codable, Equatable, Sendable {
    var usedBytes: Int64
    /// Лимит тарифа: 5 ГБ на бесплатном, затем 10 / 25 / 120 ГБ
    var limitBytes: Int64
    var perCase: [CaseUsageDTO]
}

// MARK: - Журнал событий

enum AuditKind: String, Codable, CaseIterable, Sendable {
    case login, logout, loginFailed
    case caseCreated, caseUnlocked, caseLocked, unlockFailed, caseDeleted
    case fileAdded, fileTrashed, fileRestored
    case keyRecovered, mfaChanged
}

struct AuditEventDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: AuditKind
    var caseId: String?
    var deviceName: String
    var ipHint: String?
    var at: Date
}

// MARK: - Ошибки (единый формат для всех эндпоинтов)

/// Тело любого ответа с ошибкой: HTTP 4xx/5xx + этот JSON.
struct APIErrorEnvelope: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var retryAfterSeconds: Int?
    var limitBytes: Int64?
}

enum APIError: Error, Equatable, Sendable {
    case unauthorized                       // 401 · "unauthorized"
    case forbidden                          // 403 · "forbidden"
    case notFound                           // 404 · "not_found"
    case conflict                           // 409 · "conflict"  (revision не совпал)
    case quotaExceeded(limitBytes: Int64)   // 413 · "quota_exceeded"
    case integrityFailed                    // 422 · "integrity_failed" (sha256 не совпал)
    case rateLimited(retryAfterSeconds: Int)// 429 · "rate_limited"
    case mfaInvalid                         // 401 · "mfa_invalid"
    case validation(String)                 // 400 · "validation"
    case network                            // нет сети / таймаут (клиентская)
    case server(String)                     // 5xx · "server"

    /// Единая таблица соответствия — бэкенд и фронт используют её одинаково.
    static func from(_ e: APIErrorEnvelope) -> APIError {
        switch e.code {
        case "unauthorized": return .unauthorized
        case "forbidden": return .forbidden
        case "not_found": return .notFound
        case "conflict": return .conflict
        case "quota_exceeded": return .quotaExceeded(limitBytes: e.limitBytes ?? 0)
        case "integrity_failed": return .integrityFailed
        case "rate_limited": return .rateLimited(retryAfterSeconds: e.retryAfterSeconds ?? 60)
        case "mfa_invalid": return .mfaInvalid
        case "validation": return .validation(e.message)
        default: return .server(e.message)
        }
    }
}

// MARK: - 1.1.0 · Сеансы (устройства)

struct SessionInfoDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String
    /// «iPhone Анаса», «iPad» — что прислал клиент при входе.
    var deviceName: String
    /// "ios" | "web" | "android" | …
    var platform: String
    var appVersion: String?
    /// Примерное место по IP (город, страна), может быть nil.
    var approxLocation: String?
    var createdAt: Date
    var lastActiveAt: Date
    /// true для сеанса, чьим токеном сделан запрос.
    var isCurrent: Bool
}

// MARK: - 1.1.0 · Версии файла

/// Предыдущее состояние файла. Метаданные и шифртекст запечатаны ключом кейса (как у FileRecordDTO).
struct FileVersionDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var fileId: String
    var sealedMetadata: Data
    var ciphertextSize: Int64
    var ciphertextSha256: String
    /// Когда эта версия была текущей впервые.
    var createdAt: Date
}

/// Тело «заменить содержимое файла новой версией». Сервер сохраняет прежнее состояние как FileVersionDTO.
struct ReplaceFileRequest: Codable, Equatable, Sendable {
    var sealedMetadata: Data
    var ciphertextSize: Int64
    var ciphertextSha256: String
    var expectedRevision: Int
}

// MARK: - 1.1.0 · Тарифы

enum PlanPeriod: String, Codable, Sendable { case free, month, year }

struct PlanDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var storageBytes: Int64
    /// Цена в минимальных единицах валюты (копейки/центы). 0 для free.
    var priceMinor: Int
    /// ISO 4217: "USD", "RUB"…
    var currency: String
    var period: PlanPeriod
}

enum SubscriptionStatus: String, Codable, Sendable { case active, cancelled, expired }

struct SubscriptionDTO: Codable, Equatable, Sendable {
    var planId: String
    var status: SubscriptionStatus
    var renewsAt: Date?
}

struct PurchaseRequest: Codable, Equatable, Sendable {
    var planId: String
    /// transactionId / подписанная транзакция StoreKit 2. nil допустим только для тестового бэкенда.
    var appleTransaction: String?
}

// MARK: - 1.2.0 · Защищённый чат (сквозное шифрование)
//
// Сервер — «почтовое отделение»: хранит и отдаёт ЗАШИФРОВАННЫЕ конверты. Текст, вложения, имена файлов, таймеры
// исчезновения лежат внутри `ciphertext` и сервером не читаются. Сервер видит только: кто, кому, когда, размер.

struct ChatUserDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var username: String
    /// Публичный ключ согласования X25519, 32 байта (raw representation). Подпись identity — не требуется.
    var identityKey: Data
}

struct ChatEnvelopeDTO: Codable, Equatable, Sendable, Identifiable {
    /// UUID v4, строчными, генерирует клиент — отправка идемпотентна.
    var id: String
    var senderId: String
    var recipientId: String
    /// Версия формата: байты `ciphertext` = [счётчик UInt32 BE][AES-GCM combined]. См. Docs/CHAT.md.
    var version: Int
    var ciphertext: Data
    var sentAt: Date
    /// Сервер вправе удалить конверт после этой даты (доставленный и неподтверждённый — через 30 дней).
    var expiresAt: Date?
}
