import XCTest
@testable import loKEY

final class OnboardingTests: XCTestCase {
    func testPageListAndNumbers() {
        XCTAssertEqual(OnboardingPage.count, 7)
        XCTAssertEqual(OnboardingPage.allCases.map(\.number), Array(1...7))
    }

    func testNextBackBounds() {
        var f = OnboardingFlow()
        f.back(); XCTAssertEqual(f.index, 0); XCTAssertTrue(f.isFirst)
        for _ in 0..<10 { f.next() }
        XCTAssertTrue(f.isLast); XCTAssertEqual(f.index, 6)
        f.back(); XCTAssertEqual(f.index, 5)
    }

    func testProgress() {
        var f = OnboardingFlow()
        XCTAssertEqual(f.progress, 1.0 / 7.0, accuracy: 0.0001)
        f.go(to: 6); XCTAssertEqual(f.progress, 1.0, accuracy: 0.0001)
        f.go(to: 99); XCTAssertEqual(f.index, 6)
    }

    func testSkipRules() {
        XCTAssertEqual(OnboardingPage.allCases.filter(\.canSkip), [.welcome, .cipher, .keys, .chat])
        var f = OnboardingFlow()
        f.skip(); XCTAssertEqual(f.page, .words)          // обязательная страница не пропускается
        f.skip(); XCTAssertEqual(f.page, .words)
        f.go(to: OnboardingPage.chat.rawValue)
        f.skip(); XCTAssertEqual(f.page, .final)
    }
}
