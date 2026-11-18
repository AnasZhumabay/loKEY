// Моки контракта 1.3.0: всё в памяти (актор), без сети.
import Foundation

actor MockSharedCaseAPI: SharedCaseAPI {
    private var members: [String: [CaseMemberDTO]] = [:]      // caseId → участники
    private var invites: [CaseInviteDTO] = []
    private var keys: [String: Data] = [:]                    // "caseId|userId" → обёрнутый ключ
    private var inviteMeta: [String: (invitee: String, role: SharedRole, key: Data)] = [:]
    private let meProvider: @Sendable () async -> String
    init(me: String = "mock-me") { self.meProvider = { me } }
    /// Мок-режим: id аккаунта известен только после входа, поэтому читаем его лениво.
    init(meProvider: @escaping @Sendable () async -> String) { self.meProvider = meProvider }

    func invite(caseId: String, inviteeUserId: String, wrappedKeyForInvitee: Data, role: SharedRole) async throws {
        guard !inviteeUserId.isEmpty, !wrappedKeyForInvitee.isEmpty else { throw APIError.validation("Пустой получатель или ключ") }
        let me = await meProvider()
        let id = UUID().uuidString.lowercased()
        invites.append(CaseInviteDTO(id: id, caseId: caseId, caseNameCiphertext: nil, fromUserId: me, createdAt: Date()))
        inviteMeta[id] = (inviteeUserId, role, wrappedKeyForInvitee)
        var list = members[caseId] ?? [CaseMemberDTO(userId: me, displayName: "Я", role: .owner, status: .active, joinedAt: Date())]
        list.append(CaseMemberDTO(userId: inviteeUserId, displayName: inviteeUserId, role: role, status: .invited, joinedAt: nil))
        members[caseId] = list
    }
    func listMembers(caseId: String) async throws -> [CaseMemberDTO] { members[caseId] ?? [] }
    func accept(inviteId: String) async throws -> CaseMemberDTO {
        guard let inv = invites.first(where: { $0.id == inviteId }), let meta = inviteMeta[inviteId] else { throw APIError.notFound }
        var list = members[inv.caseId] ?? []
        guard let i = list.firstIndex(where: { $0.userId == meta.invitee }) else { throw APIError.notFound }
        list[i].status = .active; list[i].joinedAt = Date()
        members[inv.caseId] = list
        keys["\(inv.caseId)|\(meta.invitee)"] = meta.key
        invites.removeAll { $0.id == inviteId }
        return list[i]
    }
    func revoke(caseId: String, userId: String) async throws {
        guard var list = members[caseId], let i = list.firstIndex(where: { $0.userId == userId }) else { throw APIError.notFound }
        list[i].status = .revoked
        members[caseId] = list
        keys["\(caseId)|\(userId)"] = nil
    }
    func fetchWrappedKey(caseId: String) async throws -> Data? { keys["\(caseId)|\(await meProvider())"] }
    func listInvites() async throws -> [CaseInviteDTO] { invites }
}

actor MockBackupAPI: BackupAPI {
    private var infos: [BackupInfoDTO] = []
    private var blobs: [String: Data] = [:]
    func listBackups() async throws -> [BackupInfoDTO] { infos.sorted { $0.createdAt > $1.createdAt } }
    func upload(info: BackupInfoDTO, data: Data, sha256: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard sha256 == info.sha256 else { throw APIError.integrityFailed }
        progress(0.5)
        infos.removeAll { $0.id == info.id }
        infos.append(info); blobs[info.id] = data
        progress(1)
    }
    func download(id: String) async throws -> Data {
        guard let d = blobs[id] else { throw APIError.notFound }
        return d
    }
    func delete(id: String) async throws {
        guard blobs[id] != nil else { throw APIError.notFound }
        blobs[id] = nil; infos.removeAll { $0.id == id }
    }
}

actor MockChatGroupAPI: ChatGroupAPI {
    private var groups: [String: GroupDTO] = [:]
    private(set) var sent: [GroupEnvelopeDTO] = []
    func createGroup(_ group: GroupDTO) async throws -> GroupDTO {
        if let e = groups[group.id] { return e }       // идемпотентно
        groups[group.id] = group; return group
    }
    func listGroups() async throws -> [GroupDTO] { groups.values.sorted { $0.createdAt < $1.createdAt } }
    func addMember(groupId: String, userId: String) async throws -> GroupDTO {
        guard var g = groups[groupId] else { throw APIError.notFound }
        if !g.memberIds.contains(userId) { g.memberIds.append(userId) }
        groups[groupId] = g; return g
    }
    func removeMember(groupId: String, userId: String) async throws -> GroupDTO {
        guard var g = groups[groupId] else { throw APIError.notFound }
        g.memberIds.removeAll { $0 == userId }
        groups[groupId] = g; return g
    }
    func send(groupEnvelope: GroupEnvelopeDTO) async throws {
        guard groups[groupEnvelope.groupId] != nil else { throw APIError.notFound }
        if !sent.contains(where: { $0.id == groupEnvelope.id }) { sent.append(groupEnvelope) }
    }
}

actor MockSecurityEventAPI: SecurityEventAPI {
    private(set) var events: [SecurityEventDTO] = []
    func report(_ event: SecurityEventDTO) async throws { events.append(event) }
    /// Для тестов и отладки.
    func all() -> [SecurityEventDTO] { events }
}
