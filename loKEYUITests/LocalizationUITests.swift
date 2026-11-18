import XCTest

/// Запуск на английском и казахском: снимки первых экранов.
final class LocalizationUITests: XCTestCase {
    var dir: String { ProcessInfo.processInfo.environment["LOKEY_SHOTS"] ?? "/private/tmp/lokey-shots" }

    func shoot(_ lang: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["-language", lang]
        app.launch()
        Thread.sleep(forTimeInterval: 2.5)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/loc-\(lang)-1.png"))
        app.terminate()
    }
    func testEnglish() { shoot("en") }
    func testKazakh() { shoot("kk") }
}
