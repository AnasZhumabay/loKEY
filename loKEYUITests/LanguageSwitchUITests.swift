import XCTest

/// Меняет язык в Настройках на лету: Русский → English → Қазақша.
final class LanguageSwitchUITests: XCTestCase {
    func testSwitch() {
        let app = XCUIApplication()
        app.launchArguments = ["-language", "ru", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        if app.buttons["Пропустить"].waitForExistence(timeout: 5) { app.buttons["Пропустить"].tap() }
        let id = app.textFields.firstMatch
        XCTAssertTrue(id.waitForExistence(timeout: 8)); id.tap(); id.typeText("demo@lokey.app")
        let pw = app.secureTextFields.firstMatch; pw.tap(); pw.typeText("lokey-demo")
        app.buttons["Войти"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Настройки"].waitForExistence(timeout: 40))
        for _ in 0..<5 {
            let notNow = app.buttons["Not Now"].exists ? app.buttons["Not Now"] : XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Not Now"]
            if notNow.waitForExistence(timeout: 1) { notNow.tap(); break }
        }
        for _ in 0..<4 where !app.staticTexts["БЕЗОПАСНОСТЬ"].exists {
            Thread.sleep(forTimeInterval: 1)
            if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }
            app.buttons["Настройки"].tap()
            _ = app.staticTexts["БЕЗОПАСНОСТЬ"].waitForExistence(timeout: 2)
        }
        let lang = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Язык'")).firstMatch
        for _ in 0..<6 where !lang.exists || !lang.isHittable { app.swipeUp(); Thread.sleep(forTimeInterval: 0.6) }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/lokey-shots/lang-dbg.png"))
        XCTAssertTrue(lang.waitForExistence(timeout: 3))
        lang.tap()
        app.descendants(matching: .any)["English"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5), "после выбора English вкладка должна стать Settings")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/lokey-shots/lang-en.png"))
        let lang2 = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Language'")).firstMatch
        for _ in 0..<3 where !lang2.isHittable { app.swipeUp(); Thread.sleep(forTimeInterval: 0.6) }
        lang2.tap()
        app.descendants(matching: .any)["Қазақша"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Баптаулар"].waitForExistence(timeout: 5))
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/lokey-shots/lang-kk.png"))
    }
}
