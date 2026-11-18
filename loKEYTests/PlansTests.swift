import XCTest
@testable import loKEY

/// Тарифы: 5 ГБ бесплатно, затем 10 / 25 / 120 ГБ.
final class PlansTests: XCTestCase {
    private let gb: Int64 = 1_073_741_824

    func testFreeLimitIsFiveGB() {
        XCTAssertEqual(AppConfig.storageLimitBytes, 5 * gb)
    }

    func testPlanTable() async throws {
        let plans = try await MockBackend.makeServices().billing.plans()
        let rows = plans.map { ($0.storageBytes / gb, $0.priceMinor, $0.currency, $0.period) }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].0, 5);   XCTAssertEqual(rows[0].1, 0);    XCTAssertEqual(rows[0].3, .free)
        XCTAssertEqual(rows[1].0, 10);  XCTAssertEqual(rows[1].1, 499)
        XCTAssertEqual(rows[2].0, 25);  XCTAssertEqual(rows[2].1, 999)
        XCTAssertEqual(rows[3].0, 120); XCTAssertEqual(rows[3].1, 4999)
        XCTAssertTrue(rows.allSatisfy { $0.2 == "USD" })
        XCTAssertEqual(plans.map(\.storageBytes), plans.map(\.storageBytes).sorted(), "тарифы идут по возрастанию")
    }
}
