import XCTest

final class OnboardingUITests: XCTestCase {
    let app = XCUIApplication()
    var dir: String { ProcessInfo.processInfo.environment["LOKEY_SHOTS"] ?? "/private/tmp/lokey-shots" }

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        app.launchArguments = ["-lokeyShowOnboarding", "-language", "ru", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
    }

    private func shot(_ n: Int) {
        Thread.sleep(forTimeInterval: 1.2)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(dir)/onboarding-\(n).png"))
    }

    func testTapThroughAllPages() {
        app.launch()
        for n in 1...7 {
            XCTAssertTrue(app.descendants(matching: .any)["onboardingPage-\(n)"].waitForExistence(timeout: 8), "page \(n)")
            shot(n)
            if n < 7 {
                let next = app.buttons["onboardingNext"]
                XCTAssertTrue(next.waitForExistence(timeout: 4))
                next.tap()
            }
        }
        XCTAssertTrue(app.buttons["onboardingStart"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["onboardingSkip"].exists)
        app.buttons["onboardingBack"].tap()
        XCTAssertTrue(app.buttons["onboardingNext"].waitForExistence(timeout: 4))
    }

    func testSkipGoesToWordsThenCannotSkip() {
        app.launch()
        let skip = app.buttons["onboardingSkip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 8))
        skip.tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboardingPage-4"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["onboardingSkip"].exists)
    }
}
