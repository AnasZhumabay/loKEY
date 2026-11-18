import XCTest
@testable import loKEY

/// Фикстуры — эталон JSON-формата. Бэкенд должен отдавать и принимать ровно такие документы.
final class ContractTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), "нет фикстуры \(name)")
        return try Data(contentsOf: url)
    }

    /// decode → encode → сравнение как JSON-деревьев → повторный decode равен первому.
    private func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let raw = try fixture(name)
        let value = try LKCoding.decoder.decode(T.self, from: raw)
        let encoded = try LKCoding.encoder.encode(value)
        let a = try JSONSerialization.jsonObject(with: raw) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
        XCTAssertEqual(a, b, "\(name): JSON после перекодирования отличается", file: file, line: line)
        XCTAssertEqual(try LKCoding.decoder.decode(T.self, from: encoded), value, file: file, line: line)
    }

    func testAccountDTO() throws { try roundTrip(AccountDTO.self, "AccountDTO") }
    func testSessionDTO() throws { try roundTrip(SessionDTO.self, "SessionDTO") }
    func testRegisterRequest() throws { try roundTrip(RegisterRequest.self, "RegisterRequest") }
    func testLoginRequest() throws { try roundTrip(LoginRequest.self, "LoginRequest") }
    func testLoginResponse() throws { try roundTrip(LoginResponse.self, "LoginResponse") }
    func testMFAVerifyRequest() throws { try roundTrip(MFAVerifyRequest.self, "MFAVerifyRequest") }
    func testMFASetupDTO() throws { try roundTrip(MFASetupDTO.self, "MFASetupDTO") }
    func testCaseRecordDTO() throws { try roundTrip(CaseRecordDTO.self, "CaseRecordDTO") }
    func testFileRecordDTO() throws { try roundTrip(FileRecordDTO.self, "FileRecordDTO") }
    func testCaseUsageDTO() throws { try roundTrip(CaseUsageDTO.self, "CaseUsageDTO") }
    func testStorageUsageDTO() throws { try roundTrip(StorageUsageDTO.self, "StorageUsageDTO") }
    func testAuditEventDTO() throws { try roundTrip(AuditEventDTO.self, "AuditEventDTO") }
    func testErrorEnvelope() throws { try roundTrip(APIErrorEnvelope.self, "APIErrorEnvelope") }
    func testCaseHeader() throws { try roundTrip(CaseHeader.self, "CaseHeader") }
    func testFileMetadata() throws { try roundTrip(FileMetadata.self, "FileMetadata") }

    // 1.3.0
    func testCaseMemberDTO() throws { try roundTrip(CaseMemberDTO.self, "CaseMemberDTO") }
    func testCaseInviteDTO() throws { try roundTrip(CaseInviteDTO.self, "CaseInviteDTO") }
    func testBackupInfoDTO() throws { try roundTrip(BackupInfoDTO.self, "BackupInfoDTO") }
    func testGroupDTO() throws { try roundTrip(GroupDTO.self, "GroupDTO") }
    func testGroupEnvelopeDTO() throws { try roundTrip(GroupEnvelopeDTO.self, "GroupEnvelopeDTO") }
    func testSecurityEventDTO() throws { try roundTrip(SecurityEventDTO.self, "SecurityEventDTO") }
    func testContractVersion() { XCTAssertEqual(LKContract.version, "1.3.0") }

    func testSessionValues() throws {
        let s = try LKCoding.decoder.decode(SessionDTO.self, from: try fixture("SessionDTO"))
        XCTAssertEqual(s.account.email, "anna@example.com")
        XCTAssertEqual(s.accessToken, "acc-token")
    }

    func testBinaryFieldsAreBase64() throws {
        let c = try LKCoding.decoder.decode(CaseRecordDTO.self, from: try fixture("CaseRecordDTO"))
        XCTAssertEqual(c.sealedHeader, Data([0xde, 0xad, 0xbe, 0xef]))
        XCTAssertEqual(c.recoveryWrappedKey, Data([0, 1, 2, 3, 4, 5, 6, 7]))
    }

    func testErrorTable() throws {
        func env(_ code: String) -> APIErrorEnvelope { APIErrorEnvelope(code: code, message: "m", retryAfterSeconds: 7, limitBytes: 5) }
        XCTAssertEqual(APIError.from(env("unauthorized")), .unauthorized)
        XCTAssertEqual(APIError.from(env("forbidden")), .forbidden)
        XCTAssertEqual(APIError.from(env("not_found")), .notFound)
        XCTAssertEqual(APIError.from(env("conflict")), .conflict)
        XCTAssertEqual(APIError.from(env("quota_exceeded")), .quotaExceeded(limitBytes: 5))
        XCTAssertEqual(APIError.from(env("integrity_failed")), .integrityFailed)
        XCTAssertEqual(APIError.from(env("rate_limited")), .rateLimited(retryAfterSeconds: 7))
        XCTAssertEqual(APIError.from(env("mfa_invalid")), .mfaInvalid)
        XCTAssertEqual(APIError.from(env("validation")), .validation("m"))
        XCTAssertEqual(APIError.from(env("whatever")), .server("m"))
    }

}
