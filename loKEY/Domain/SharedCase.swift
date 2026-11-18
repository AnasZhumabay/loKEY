// Интерфейс «общего кейса» для UI. UI не знает про ключи, обёртки и DTO контракта.
// Формат обёрнутого ключа и модель угроз: Docs/_shared_case_format.md.
import Foundation

struct SharedMember: Identifiable, Equatable, Sendable {
    var id: String            // id пользователя
    var name: String
    var role: SharedRole
    var status: SharedMemberStatus
    var joinedAt: Date?
    var isMe: Bool
}

struct SharedInvite: Identifiable, Equatable, Sendable {
    var id: String
    var caseId: String
    /// nil — имя зашифровано ключом кейса и станет видно после принятия.
    var caseName: String?
    var fromUserId: String
    var fromName: String
    /// Контакт, который пригласил, проверен кодом безопасности.
    var fromVerified: Bool
    var createdAt: Date
}

enum SharedCaseError: Error, LocalizedError, Equatable, Sendable {
    case notReady, notOwner, invalidRole, notAContact, keyAgreementUnavailable
    case alreadyMember, inviteMalformed, wrongKey, notImplemented, server(String)
    var errorDescription: String? {
        switch self {
        case .notReady: return "Чат ещё настраивается. Попробуйте через секунду."
        case .notOwner: return "Это может сделать только владелец кейса."
        case .invalidRole: return "Эту роль выдать нельзя. Доступны «Редактор» и «Просмотр»."
        case .notAContact: return "Поделиться можно только с контактом из чата."
        case .keyAgreementUnavailable: return "Не удалось получить общий ключ с контактом. Добавьте его заново через QR."
        case .alreadyMember: return "Этот человек уже участник кейса."
        case .inviteMalformed: return "Приглашение повреждено или адресовано не вам."
        case .wrongKey: return "Ключ не подошёл: приглашение от другого человека или подменено."
        case .notImplemented: return "Пока не реализовано."
        case .server(let m): return m
        }
    }
}

/// Правила ролей (чистые функции, проверяются тестами).
enum SharedRolePolicy {
    /// Выдать можно только эти роли; владелец у кейса один.
    static let assignable: [SharedRole] = [.editor, .viewer]
    static func canAssign(_ role: SharedRole) -> Bool { assignable.contains(role) }
    static func canEdit(_ role: SharedRole) -> Bool { role == .owner || role == .editor }
    /// Приглашать, отзывать доступ и менять ключ может только владелец.
    static func canManage(_ role: SharedRole) -> Bool { role == .owner }
}

protocol SharedCaseService: Sendable {
    func members(caseId: String) async throws -> [SharedMember]
    /// Только владелец. Оборачивает секрет кейса общим с контактом ключом; сервер секрета не видит.
    func invite(caseId: String, contactId: String, role: SharedRole) async throws
    func pendingInvites() async throws -> [SharedInvite]
    func accept(inviteId: String) async throws
    /// Скрывает приглашение на этом устройстве (в контракте 1.3.0 нет метода отказа).
    func decline(inviteId: String) async throws
    /// Только владелец. Не может стереть то, что человек уже видел или скопировал.
    func revoke(caseId: String, userId: String) async throws
    /// Участник выходит сам.
    func leave(caseId: String) async throws
    /// Кейсы, в которые меня пригласили и я принял (даже если запись кейса ещё не появилась в списке хранилища).
    func joinedCaseIds() async -> [String]
    /// Синхронно: по последнему известному списку участников (обновляется в `members`).
    func isShared(caseId: String) -> Bool
    /// TODO(backend): смена ключа кейса и перешифрование файлов после отзыва. Пока бросает `.notImplemented`.
    func rotateKeyAfterRevoke(caseId: String) async throws
}

extension SharedCaseService {
    func rotateKeyAfterRevoke(caseId: String) async throws { throw SharedCaseError.notImplemented }
}

/// Шов к слою чата: общий секрет X25519 между моей личностью и публичным ключом контакта (32 байта, одинаков у обоих).
/// `ChatRepositoryImpl` должен реализовать этот протокол (приватный ключ и публичный ключ контакта лежат только там).
protocol ChatKeyAgreement: Sendable {
    func sharedSecret(withContact contactID: String) async throws -> Data
}
