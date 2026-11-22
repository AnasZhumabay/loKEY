// Live-клиент контракта 1.3.0: общие кейсы, бэкап на сервере, группы, события безопасности.
// Пути и тела — Docs/BACKEND_CONTRACT.md (раздел 1.3.0); сервер — backend/app/routers/{shared,backups,groups,security_events}.py.
// Всё идёт через LiveHTTP (Bearer, один refresh на 401, ошибки → APIError), как в LiveBackend.swift.
import Foundation

private struct EmptyBody: Codable {}

struct LiveSharedCaseAPI: SharedCaseAPI {
    let http: LiveHTTP
    private struct InviteBody: Codable { var inviteeUserId: String; var wrappedKeyForInvitee: Data; var role: SharedRole }
    private struct WrappedKeyBody: Codable { var wrappedKey: Data }

    // POST /v1/cases/{caseId}/invites  body {invitee_user_id, wrapped_key_for_invitee(base64), role} → 204
    func invite(caseId: String, inviteeUserId: String, wrappedKeyForInvitee: Data, role: SharedRole) async throws {
        try await http.send("POST", "/v1/cases/\(caseId)/invites",
                            body: InviteBody(inviteeUserId: inviteeUserId, wrappedKeyForInvitee: wrappedKeyForInvitee, role: role))
    }
    // GET /v1/cases/{caseId}/members → [CaseMemberDTO] (владелец первым)
    func listMembers(caseId: String) async throws -> [CaseMemberDTO] {
        try await http.get("/v1/cases/\(caseId)/members")
    }
    // POST /v1/invites/{inviteId}/accept → CaseMemberDTO (повтор — идемпотентен)
    func accept(inviteId: String) async throws -> CaseMemberDTO {
        try await http.json("POST", "/v1/invites/\(inviteId)/accept", body: EmptyBody())
    }
    // DELETE /v1/cases/{caseId}/members/{userId} → 204 (владелец — любого, участник — только себя)
    func revoke(caseId: String, userId: String) async throws {
        try await http.send("DELETE", "/v1/cases/\(caseId)/members/\(userId)", body: Optional<EmptyBody>.none)
    }
    // GET /v1/cases/{caseId}/wrapped-key → {wrapped_key(base64)}; 404 = нет доступа или ещё не принято → nil
    func fetchWrappedKey(caseId: String) async throws -> Data? {
        do {
            let r: WrappedKeyBody = try await http.get("/v1/cases/\(caseId)/wrapped-key")
            return r.wrappedKey
        } catch APIError.notFound {
            return nil
        }
    }
    // GET /v1/invites → [CaseInviteDTO] (входящие, ещё не принятые)
    func listInvites() async throws -> [CaseInviteDTO] {
        try await http.get("/v1/invites")
    }
}

struct LiveBackupAPI: BackupAPI {
    let http: LiveHTTP

    // GET /v1/backups → [BackupInfoDTO] (новые первыми)
    func listBackups() async throws -> [BackupInfoDTO] {
        try await http.get("/v1/backups")
    }
    // PUT /v1/backups/{id} (octet-stream) + X-LK-Info (JSON BackupInfoDTO) + X-LK-SHA256; 422 при несовпадении хэша/размера
    func upload(info: BackupInfoDTO, data: Data, sha256: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let infoHeader = Self.asciiJSON(try LKCoding.encoder.encode(info))
        _ = try await http.raw("PUT", "/v1/backups/\(info.id)", body: data, contentType: "application/octet-stream",
                               headers: ["X-LK-Info": infoHeader, "X-LK-SHA256": sha256], progress: progress)
    }
    // GET /v1/backups/{id}/blob → octet-stream (LiveHTTP сам ставит Accept для путей на /blob)
    func download(id: String) async throws -> Data {
        try await http.raw("GET", "/v1/backups/\(id)/blob")
    }
    // DELETE /v1/backups/{id} → 204
    func delete(id: String) async throws {
        try await http.send("DELETE", "/v1/backups/\(id)", body: Optional<EmptyBody>.none)
    }

    /// Значение HTTP-заголовка должно быть ASCII. Не-ASCII (например, имя устройства «iPhone Анаса»)
    /// экранируем как \uXXXX — это по-прежнему валидный JSON, сервер разберёт его как обычно.
    static func asciiJSON(_ data: Data) -> String {
        var out = ""
        for unit in String(decoding: data, as: UTF8.self).utf16 {
            if unit < 0x80 {
                out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            } else {
                out += String(format: "\\u%04x", unit)
            }
        }
        return out
    }
}

struct LiveChatGroupAPI: ChatGroupAPI {
    let http: LiveHTTP
    private struct MemberBody: Codable { var userId: String }

    // POST /v1/chat/groups body GroupDTO → GroupDTO (идемпотентно по id)
    func createGroup(_ group: GroupDTO) async throws -> GroupDTO {
        try await http.json("POST", "/v1/chat/groups", body: group)
    }
    // GET /v1/chat/groups → [GroupDTO]
    func listGroups() async throws -> [GroupDTO] {
        try await http.get("/v1/chat/groups")
    }
    // POST /v1/chat/groups/{groupId}/members body {user_id} → GroupDTO (только создатель группы)
    func addMember(groupId: String, userId: String) async throws -> GroupDTO {
        try await http.json("POST", "/v1/chat/groups/\(groupId)/members", body: MemberBody(userId: userId))
    }
    // DELETE /v1/chat/groups/{groupId}/members/{userId} → GroupDTO (создатель — любого, участник — себя)
    func removeMember(groupId: String, userId: String) async throws -> GroupDTO {
        let data = try await http.raw("DELETE", "/v1/chat/groups/\(groupId)/members/\(userId)")
        return try LiveHTTP.decode(GroupDTO.self, data)
    }
    // POST /v1/chat/groups/{groupId}/messages body GroupEnvelopeDTO → 204; сервер раздаёт копию каждому recipient_ids
    func send(groupEnvelope: GroupEnvelopeDTO) async throws {
        try await http.send("POST", "/v1/chat/groups/\(groupEnvelope.groupId)/messages", body: groupEnvelope)
    }
}

struct LiveSecurityEventAPI: SecurityEventAPI {
    let http: LiveHTTP
    // POST /v1/security-events body SecurityEventDTO → 204
    func report(_ event: SecurityEventDTO) async throws {
        try await http.send("POST", "/v1/security-events", body: event)
    }
}
