// Мок-режим: добавляет к любому SharedCaseAPI демо-приглашение от Алисы (для показа потока и скриншотов).
// Обёрнутый ключ в нём настоящий формат (SharedCaseWrap), но общий секрет демо-выведенный (DemoKeyAgreement).
import Foundation

actor DemoSharedCaseAPI: SharedCaseAPI {
    static let inviteId = "demo-invite-alisa"
    static let caseId = "demo-shared-case"

    private let base: SharedCaseAPI
    private let meProvider: @Sendable () async -> String
    private let alisa: String
    private var inviteVisible = true
    private var accepted = false
    private var wrappedCache: (me: String, data: Data)?

    init(base: SharedCaseAPI, me: String, alisaID: String = MockChatStore.botID) {
        self.base = base; self.meProvider = { me }; self.alisa = alisaID
    }
    /// Мок-режим: id аккаунта известен только после входа, поэтому читаем его лениво.
    init(base: SharedCaseAPI, meProvider: @escaping @Sendable () async -> String, alisaID: String = MockChatStore.botID) {
        self.base = base; self.meProvider = meProvider; self.alisa = alisaID
    }

    private func wrapped(for me: String) -> Data {
        if let c = wrappedCache, c.me == me { return c.data }
        let dh = DemoKeyAgreement.secret(me, alisa)
        let d = (try? SharedCaseWrap.wrap(secret: KeyFormat.generateSecret(), sharedSecret: dh,
                                          caseId: Self.caseId, inviter: alisa, invitee: me)) ?? Data()
        wrappedCache = (me, d)
        return d
    }

    func invite(caseId: String, inviteeUserId: String, wrappedKeyForInvitee: Data, role: SharedRole) async throws {
        try await base.invite(caseId: caseId, inviteeUserId: inviteeUserId, wrappedKeyForInvitee: wrappedKeyForInvitee, role: role)
    }
    func listMembers(caseId: String) async throws -> [CaseMemberDTO] {
        guard caseId == Self.caseId else { return try await base.listMembers(caseId: caseId) }
        let me = await meProvider()
        var list = [CaseMemberDTO(userId: alisa, displayName: "Алиса", role: .owner, status: .active, joinedAt: Date(timeIntervalSinceNow: -86400))]
        if accepted { list.append(CaseMemberDTO(userId: me, displayName: "Я", role: .editor, status: .active, joinedAt: Date())) }
        else if inviteVisible { list.append(CaseMemberDTO(userId: me, displayName: "Я", role: .editor, status: .invited, joinedAt: nil)) }
        return list
    }
    func accept(inviteId: String) async throws -> CaseMemberDTO {
        guard inviteId == Self.inviteId else { return try await base.accept(inviteId: inviteId) }
        guard inviteVisible else { throw APIError.notFound }
        let me = await meProvider()
        inviteVisible = false; accepted = true
        return CaseMemberDTO(userId: me, displayName: "Я", role: .editor, status: .active, joinedAt: Date())
    }
    func revoke(caseId: String, userId: String) async throws {
        if caseId == Self.caseId { accepted = false; return }
        try await base.revoke(caseId: caseId, userId: userId)
    }
    func fetchWrappedKey(caseId: String) async throws -> Data? {
        if caseId == Self.caseId { return accepted ? wrapped(for: await meProvider()) : nil }
        return try await base.fetchWrappedKey(caseId: caseId)
    }
    func listInvites() async throws -> [CaseInviteDTO] {
        var list = try await base.listInvites()
        if inviteVisible {
            list.insert(CaseInviteDTO(id: Self.inviteId, caseId: Self.caseId, caseNameCiphertext: nil, fromUserId: alisa,
                                      createdAt: Date(timeIntervalSinceNow: -3600)), at: 0)
        }
        return list
    }
}
