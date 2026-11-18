// ═══════════════════════════════════════════════════════════════════════════
//  CONTRACT 1.3.0 · только добавления (общие кейсы, бэкап, группы, события безопасности)
//  Все методы бросают ТОЛЬКО `APIError`. Сервер видит лишь шифртекст.
//  Неподдержанный сервером метод должен отвечать 501 → клиент получит `.server("not_implemented")`.
// ═══════════════════════════════════════════════════════════════════════════
import Foundation

// MARK: - Общие кейсы

enum SharedRole: String, Codable, CaseIterable, Sendable { case owner, editor, viewer }
enum SharedMemberStatus: String, Codable, CaseIterable, Sendable { case invited, active, revoked }

struct CaseMemberDTO: Codable, Equatable, Sendable, Identifiable {
    var userId: String
    var displayName: String
    var role: SharedRole
    var status: SharedMemberStatus
    var joinedAt: Date?
    var id: String { userId }
}

struct CaseInviteDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var caseId: String
    /// Имя кейса, зашифрованное ключом кейса (приглашённый видит его после accept). Может отсутствовать.
    var caseNameCiphertext: Data?
    var fromUserId: String
    var createdAt: Date
}

/// Общий кейс: у каждого участника свой «обёрнутый» ключ кейса (оборачивается публичным ключом участника).
protocol SharedCaseAPI: Sendable {
    func invite(caseId: String, inviteeUserId: String, wrappedKeyForInvitee: Data, role: SharedRole) async throws
    func listMembers(caseId: String) async throws -> [CaseMemberDTO]
    func accept(inviteId: String) async throws -> CaseMemberDTO
    func revoke(caseId: String, userId: String) async throws
    /// Ключ кейса, обёрнутый для текущего пользователя; nil — нет доступа/ещё не принято.
    func fetchWrappedKey(caseId: String) async throws -> Data?
    func listInvites() async throws -> [CaseInviteDTO]
}

// MARK: - Бэкап на сервере

struct BackupInfoDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var createdAt: Date
    var sizeBytes: Int64
    var sha256: String
    var deviceName: String
    var appVersion: String
    var formatVersion: Int
}

protocol BackupAPI: Sendable {
    func listBackups() async throws -> [BackupInfoDTO]
    /// Сервер сверяет sha256, иначе `.integrityFailed`. progress: 0...1.
    func upload(info: BackupInfoDTO, data: Data, sha256: String,
                progress: @escaping @Sendable (Double) -> Void) async throws
    func download(id: String) async throws -> Data
    func delete(id: String) async throws
}

// MARK: - Группы (fan-out)

struct GroupDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var nameCiphertext: Data
    var memberIds: [String]
    var createdAt: Date
}

struct GroupEnvelopeDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var groupId: String
    var senderId: String
    var sentAt: Date
    var ciphertext: Data
    /// Кому сервер раздаёт копию (fan-out).
    var recipientIds: [String]
}

protocol ChatGroupAPI: Sendable {
    func createGroup(_ group: GroupDTO) async throws -> GroupDTO
    func listGroups() async throws -> [GroupDTO]
    func addMember(groupId: String, userId: String) async throws -> GroupDTO
    func removeMember(groupId: String, userId: String) async throws -> GroupDTO
    func send(groupEnvelope: GroupEnvelopeDTO) async throws
}

// MARK: - События безопасности

enum SecurityEventKind: String, Codable, CaseIterable, Sendable {
    case caseWiped, duressUnlock, tooManyAttempts, backupCreated, backupRestored
}

struct SecurityEventDTO: Codable, Equatable, Sendable {
    var kind: SecurityEventKind
    var caseId: String?
    var at: Date
    var deviceName: String?
}

protocol SecurityEventAPI: Sendable {
    func report(_ event: SecurityEventDTO) async throws
}

// MARK: - Умолчания «не реализовано» (чтобы APIServices(...) без новых аргументов компилировался)

private let notImplemented = APIError.server("not_implemented")

struct UnavailableSharedCaseAPI: SharedCaseAPI {
    func invite(caseId: String, inviteeUserId: String, wrappedKeyForInvitee: Data, role: SharedRole) async throws { throw notImplemented }
    func listMembers(caseId: String) async throws -> [CaseMemberDTO] { throw notImplemented }
    func accept(inviteId: String) async throws -> CaseMemberDTO { throw notImplemented }
    func revoke(caseId: String, userId: String) async throws { throw notImplemented }
    func fetchWrappedKey(caseId: String) async throws -> Data? { throw notImplemented }
    func listInvites() async throws -> [CaseInviteDTO] { throw notImplemented }
}
struct UnavailableBackupAPI: BackupAPI {
    func listBackups() async throws -> [BackupInfoDTO] { throw notImplemented }
    func upload(info: BackupInfoDTO, data: Data, sha256: String, progress: @escaping @Sendable (Double) -> Void) async throws { throw notImplemented }
    func download(id: String) async throws -> Data { throw notImplemented }
    func delete(id: String) async throws { throw notImplemented }
}
struct UnavailableChatGroupAPI: ChatGroupAPI {
    func createGroup(_ group: GroupDTO) async throws -> GroupDTO { throw notImplemented }
    func listGroups() async throws -> [GroupDTO] { throw notImplemented }
    func addMember(groupId: String, userId: String) async throws -> GroupDTO { throw notImplemented }
    func removeMember(groupId: String, userId: String) async throws -> GroupDTO { throw notImplemented }
    func send(groupEnvelope: GroupEnvelopeDTO) async throws { throw notImplemented }
}
struct UnavailableSecurityEventAPI: SecurityEventAPI {
    func report(_ event: SecurityEventDTO) async throws { throw notImplemented }
}
