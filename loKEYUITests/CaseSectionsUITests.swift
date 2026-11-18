import XCTest

/// Разделы внутри кейса, редактор фото и подпись в PDF (скриншоты).
final class CaseSectionsUITests: XCTestCase {
    let dir = "/private/tmp/lokey-shots"
    func shot(_ n: String) { Thread.sleep(forTimeInterval: 0.9); try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(n).png")) }

    func testCaseSectionsAndEditors() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["-language", "ru", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-lokeyDemoLogin", "-lokeyOpenCase", "Семейный архив"]
        app.launch()
        let photos = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Фото'")).firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        shot("case-1-overview")
        photos.tap()
        shot("case-2-photos")
        // первое фото → просмотр → редактор
        let thumb = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Фото'")).firstMatch
        if thumb.waitForExistence(timeout: 5) {
            thumb.tap()
            let editor = app.buttons["Редактор"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10), "нет кнопки «Редактор» у фото")
            shot("case-3-viewer")
            editor.tap()
            Thread.sleep(forTimeInterval: 1.5)
            shot("case-4-editor")
        }
    }
}
