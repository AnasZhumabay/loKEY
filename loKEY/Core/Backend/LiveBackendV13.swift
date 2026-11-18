// Live-заглушки контракта 1.3.0. Бэкендер заменяет тела методов; UI менять не нужно.
// Пока не реализовано — бросаем `.server("not_implemented")`.
import Foundation

private let notImplementedV13 = APIError.server("not_implemented")

struct LiveSharedCaseAPI: SharedCaseAPI {
    let http: LiveHTTP
    // TODO(backend): POST /v1/cases/{caseId}/invites  body {invitee_user_id, wrapped_key_for_invitee(base64), role} → 204
    func invite(caseId: String, inviteeUserId: String, wrappedKeyForInvitee: Data, role: SharedRole) async throws { throw notImplementedV13 }
    // TODO(backend): GET /v1/cases/{caseId}/members → [CaseMemberDTO]
    func listMembers(caseId: String) async throws -> [CaseMemberDTO] { throw notImplementedV13 }
    // TODO(backend): POST /v1/invites/{inviteId}/accept → CaseMemberDTO
    func accept(inviteId: String) async throws -> CaseMemberDTO { throw notImplementedV13 }
    // TODO(backend): DELETE /v1/cases/{caseId}/members/{userId} → 204 (владелец или сам участник)
    func revoke(caseId: String, userId: String) async throws { throw notImplementedV13 }
    // TODO(backend): GET /v1/cases/{caseId}/wrapped-key → {wrapped_key(base64)}; 404 → nil
    func fetchWrappedKey(caseId: String) async throws -> Data? { throw notImplementedV13 }
    // TODO(backend): GET /v1/invites → [CaseInviteDTO] (входящие, ещё не принятые)
    func listInvites() async throws -> [CaseInviteDTO] { throw notImplementedV13 }
}

struct LiveBackupAPI: BackupAPI {
    let http: LiveHTTP
    // TODO(backend): GET /v1/backups → [BackupInfoDTO]
    func listBackups() async throws -> [BackupInfoDTO] { throw notImplementedV13 }
    // TODO(backend): PUT /v1/backups/{id} (octet-stream) + заголовки X-LK-Info (JSON BackupInfoDTO), X-LK-SHA256; 422 при несовпадении
    func upload(info: BackupInfoDTO, data: Data, sha256: String, progress: @escaping @Sendable (Double) -> Void) async throws { throw notImplementedV13 }
    // TODO(backend): GET /v1/backups/{id}/blob → octet-stream
    func download(id: String) async throws -> Data { throw notImplementedV13 }
    // TODO(backend): DELETE /v1/backups/{id} → 204
    func delete(id: String) async throws { throw notImplementedV13 }
}

struct LiveChatGroupAPI: ChatGroupAPI {
    let http: LiveHTTP
    // TODO(backend): POST /v1/chat/groups body GroupDTO → GroupDTO (идемпотентно по id)
    func createGroup(_ group: GroupDTO) async throws -> GroupDTO { throw notImplementedV13 }
    // TODO(backend): GET /v1/chat/groups → [GroupDTO]
    func listGroups() async throws -> [GroupDTO] { throw notImplementedV13 }
    // TODO(backend): POST /v1/chat/groups/{groupId}/members body {user_id} → GroupDTO
    func addMember(groupId: String, userId: String) async throws -> GroupDTO { throw notImplementedV13 }
    // TODO(backend): DELETE /v1/chat/groups/{groupId}/members/{userId} → GroupDTO
    func removeMember(groupId: String, userId: String) async throws -> GroupDTO { throw notImplementedV13 }
    // TODO(backend): POST /v1/chat/groups/{groupId}/messages body GroupEnvelopeDTO → 204; сервер раздаёт копию каждому recipient_ids
    func send(groupEnvelope: GroupEnvelopeDTO) async throws { throw notImplementedV13 }
}

struct LiveSecurityEventAPI: SecurityEventAPI {
    let http: LiveHTTP
    // TODO(backend): POST /v1/security-events body SecurityEventDTO → 204
    func report(_ event: SecurityEventDTO) async throws { throw notImplementedV13 }
}
