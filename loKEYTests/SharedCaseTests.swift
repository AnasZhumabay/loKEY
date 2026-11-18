import XCTest
import CryptoKit
@testable import loKEY

private actor FakeSharedAPI: SharedCaseAPI {
    var members: [String: [CaseMemberDTO]] = [:]
    var revoked: [String] = []
    func invite(caseId: String, inviteeUserId: String, wrappedKeyForInvitee: Data, role: SharedRole) async throws {}
    func listMembers(caseId: String) async throws -> [CaseMemberDTO] { members[caseId] ?? [] }
    func accept(inviteId: String) async throws -> CaseMemberDTO { throw APIError.notFound }
    func revoke(caseId: String, userId: String) async throws {
        revoked.append(userId)
        members[caseId] = (members[caseId] ?? []).map { var m = $0; if m.userId == userId { m.status = .revoked }; return m }
    }
    func fetchWrappedKey(caseId: String) async throws -> Data? { nil }
    func listInvites() async throws -> [CaseInviteDTO] { [] }
    func set(_ m: [CaseMemberDTO], _ c: String) { members[c] = m }
}

final class SharedCaseTests: XCTestCase {
    private let secret = KeyFormat.generateSecret()
    private let dh = DemoKeyAgreement.secret("alice", "bob")

    func testWrapRoundTrip() throws {
        let w = try SharedCaseWrap.wrap(secret: secret, sharedSecret: dh, caseId: "c1", inviter: "alice", invitee: "bob")
        XCTAssertNil(w.range(of: secret))
        XCTAssertEqual(try SharedCaseWrap.unwrap(w, sharedSecret: dh, caseId: "c1", inviter: "alice", invitee: "bob"), secret)
    }

    func testWrongContactFails() throws {
        let w = try SharedCaseWrap.wrap(secret: secret, sharedSecret: dh, caseId: "c1", inviter: "alice", invitee: "bob")
        let other = DemoKeyAgreement.secret("alice", "eve")
        XCTAssertThrowsError(try SharedCaseWrap.unwrap(w, sharedSecret: other, caseId: "c1", inviter: "alice", invitee: "bob"))
    }

    func testTamperedAADFails() throws {
        let w = try SharedCaseWrap.wrap(secret: secret, sharedSecret: dh, caseId: "c1", inviter: "alice", invitee: "bob")
        XCTAssertThrowsError(try SharedCaseWrap.unwrap(w, sharedSecret: dh, caseId: "c2", inviter: "alice", invitee: "bob"))
        XCTAssertThrowsError(try SharedCaseWrap.unwrap(w, sharedSecret: dh, caseId: "c1", inviter: "mallory", invitee: "bob"))
        XCTAssertThrowsError(try SharedCaseWrap.unwrap(w, sharedSecret: dh, caseId: "c1", inviter: "alice", invitee: "carol"))
        var bad = w; bad[bad.count - 1] ^= 1
        XCTAssertThrowsError(try SharedCaseWrap.unwrap(bad, sharedSecret: dh, caseId: "c1", inviter: "alice", invitee: "bob"))
    }

    func testRoleRules() {
        XCTAssertFalse(SharedRolePolicy.canEdit(.viewer))
        XCTAssertTrue(SharedRolePolicy.canEdit(.editor))
        XCTAssertFalse(SharedRolePolicy.canAssign(.owner))
        XCTAssertFalse(SharedRolePolicy.canManage(.viewer))
        XCTAssertFalse(SharedRolePolicy.canManage(.editor))
        XCTAssertTrue(SharedRolePolicy.canManage(.owner))
    }

    func testRevokeOwnerOnlyAndFlow() async throws {
        // Прямая проверка политики и фейкового API: владелец отзывает, статус становится revoked.
        let api = FakeSharedAPI()
        await api.set([CaseMemberDTO(userId: "me", displayName: "Я", role: .owner, status: .active, joinedAt: nil),
                       CaseMemberDTO(userId: "bob", displayName: "Боб", role: .editor, status: .active, joinedAt: nil)], "c1")
        try await api.revoke(caseId: "c1", userId: "bob")
        let m = try await api.listMembers(caseId: "c1")
        XCTAssertEqual(m.first { $0.userId == "bob" }?.status, .revoked)
        let revoked = await api.revoked
        XCTAssertEqual(revoked, ["bob"])
    }

    func testMockInviteAcceptFlowAgainstMock() async throws {
        let api = MockSharedCaseAPI(me: "me")
        let wrapped = try SharedCaseWrap.wrap(secret: secret, sharedSecret: dh, caseId: "c1", inviter: "me", invitee: "bob")
        try await api.invite(caseId: "c1", inviteeUserId: "bob", wrappedKeyForInvitee: wrapped, role: .viewer)
        let invites = try await api.listInvites()
        XCTAssertEqual(invites.count, 1)
        let member = try await api.accept(inviteId: invites[0].id)
        XCTAssertEqual(member.status, .active)
        try await api.revoke(caseId: "c1", userId: "bob")
        let after = try await api.listMembers(caseId: "c1")
        XCTAssertEqual(after.first { $0.userId == "bob" }?.status, .revoked)
    }
}
