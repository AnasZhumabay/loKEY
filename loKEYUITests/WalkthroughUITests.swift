import XCTest

/// Проходит основной путь приложения и снимает экраны (папка из env LOKEY_SHOTS, по умолчанию /tmp).
final class WalkthroughUITests: XCTestCase {
    let app = XCUIApplication()
    var dir: String { ProcessInfo.processInfo.environment["LOKEY_SHOTS"] ?? "/private/tmp/lokey-shots" }

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.7)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    private func tap(_ el: XCUIElement, wait: TimeInterval = 8) -> Bool {
        guard el.waitForExistence(timeout: wait) else { return false }
        el.tap(); return true
    }

    func testWalkthrough() {
        app.launchArguments = ["-language", "ru", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-lokeyShowOnboarding"]
        app.launch()
        shot("01-onboarding")
        _ = tap(app.buttons["onboardingNext"]); shot("02-onboarding-2")
        _ = tap(app.buttons["onboardingNext"]); shot("03-onboarding-3")
        // Новый поток из 7 страниц: на странице 4 «Пропустить» нет, идём кнопкой до «Начать»
        for _ in 0..<8 where !app.buttons["onboardingStart"].exists { _ = tap(app.buttons["onboardingNext"], wait: 3) }
        _ = tap(app.buttons["onboardingStart"], wait: 4)
        shot("04-auth")

        let id = app.textFields.firstMatch
        if id.waitForExistence(timeout: 8) { id.tap(); id.typeText("demo@lokey.app") }
        let pw = app.secureTextFields.firstMatch
        if pw.waitForExistence(timeout: 3) { pw.tap(); pw.typeText("lokey-demo") }
        shot("05-auth-filled")
        _ = tap(app.buttons["Войти"].firstMatch)
        // Системный диалог «Save Password?» не должен мешать проходу
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 6) { notNow.tap() }

        // Главный экран (демо-данные создаются после входа)
        // Ввод в SecureField на симуляторе иногда не срабатывает: тогда входим через демо-флаг
        if !app.staticTexts["Защита активна · AES-256"].waitForExistence(timeout: 10) {
            app.terminate()
            app.launchArguments = ["-language", "ru", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-lokeyDemoLogin"]
            app.launch()
        }
        _ = app.staticTexts["Защита активна · AES-256"].waitForExistence(timeout: 40)
        shot("06-home")

        // Закрытый кейс → разблокировка по Face ID
        if app.buttons["Not Now"].waitForExistence(timeout: 1) { app.buttons["Not Now"].tap() }
        Thread.sleep(forTimeInterval: 1.0)
        var log = ""
        for _ in 0..<3 where !app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Финансы' OR label BEGINSWITH 'Finance'")).firstMatch.exists { app.swipeUp() }
        let card = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Финансы' OR label BEGINSWITH 'Finance'")).firstMatch
        log += "exists=\(card.exists) hittable=\(card.isHittable) frame=\(card.frame)\n"
        card.tap(); Thread.sleep(forTimeInterval: 1.5)
        log += "after tap: faceID=\(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Face ID'")).firstMatch.exists)\n"
        if !app.buttons.containing(NSPredicate(format: "label CONTAINS 'Face ID'")).firstMatch.exists {
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap(); Thread.sleep(forTimeInterval: 1.5)
            log += "after coord tap: faceID=\(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Face ID'")).firstMatch.exists)\n"
        }
        shot("07-after-taps")
        try? log.write(toFile: "\(dir)/log.txt", atomically: true, encoding: .utf8)
        try? app.debugDescription.write(toFile: "\(dir)/tree.txt", atomically: true, encoding: .utf8)
        let faceID = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Face ID'")).firstMatch
        if faceID.exists {
            faceID.tap(); Thread.sleep(forTimeInterval: 0.5); shot("08-unlock-scanning")
            _ = app.buttons["Открыть кейс"].waitForExistence(timeout: 8); shot("09-unlock-success")
            _ = tap(app.buttons["Открыть кейс"], wait: 2)
            Thread.sleep(forTimeInterval: 1.6); shot("10-case")
            let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'PDF' OR label CONTAINS 'JPG'")).firstMatch
            if tap(row, wait: 4) { Thread.sleep(forTimeInterval: 1.0); shot("11-file") }
        }
        for _ in 0..<3 { if app.buttons["Назад"].exists { app.buttons["Назад"].tap(); Thread.sleep(forTimeInterval: 0.5) } }
        shot("11b-home-after")
        for (title, name) in [("Избранное", "12-favorites"), ("Журнал", "13-journal"), ("Настройки", "14-settings")] {
            if tap(app.buttons[title], wait: 6) { Thread.sleep(forTimeInterval: 1.0); shot(name) }
        }
        // Новые экраны 1.1.0
        for (title, name) in [("Устройства и сеансы", "15-sessions"), ("Хранилище и тариф", "16-plans")] {
            let row = app.buttons[title]
            if !row.exists { app.swipeUp(); Thread.sleep(forTimeInterval: 0.5) }
            if tap(row, wait: 4) {
                Thread.sleep(forTimeInterval: 1.2); shot(name)
                if app.buttons["Назад"].exists { app.buttons["Назад"].tap(); Thread.sleep(forTimeInterval: 0.6) }
            }
        }
    }
}
