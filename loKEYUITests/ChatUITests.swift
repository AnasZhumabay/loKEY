import XCTest

/// Чат с демо-собеседницей: добавление по приглашению, отправка, расшифрованный ответ.
final class ChatUITests: XCTestCase {
    func testChatWithDemoContact() {
        try? FileManager.default.createDirectory(atPath: "/private/tmp/lokey-shots", withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["-language", "ru", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-lokeyDemoLogin"]
        app.launch()
        let chatBtn = app.buttons["chatStripButton"].firstMatch   // карточка «Сообщения» на главной
        if !chatBtn.waitForExistence(timeout: 40) { try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/lokey-shots/chat-fail.png")) }
        XCTAssertTrue(chatBtn.waitForExistence(timeout: 40))
        chatBtn.tap()
        let add = app.buttons["Добавить контакт"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        let demo = app.buttons["demoContactButton"].firstMatch   // по id: не зависит от языка интерфейса
        for _ in 0..<3 where !demo.exists { app.swipeUp() }
        XCTAssertTrue(demo.waitForExistence(timeout: 5)); demo.tap()
        let field = app.textFields["Сообщение"]
        XCTAssertTrue(field.waitForExistence(timeout: 8)); field.tap(); field.typeText("Привет, это проверка шифрования")
        // при наборе над полем появляется чип таймера исчезновения
        XCTAssertTrue(app.buttons["Таймер исчезновения сообщения"].waitForExistence(timeout: 5), "нет чипа таймера")
        app.buttons["Отправить"].tap()
        // ответ приходит зашифрованным и расшифровывается на клиенте
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'демо-собеседница'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "нет расшифрованного ответа")
        Thread.sleep(forTimeInterval: 0.8)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/lokey-shots/chat-1.png"))

        // долгое нажатие на своё сообщение: меню с реакциями и действиями
        let mine = app.staticTexts["Привет, это проверка шифрования"]
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        mine.press(forDuration: 0.8)
        let edit = app.buttons["Изменить"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "в меню нет «Изменить»")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/lokey-shots/chat-2-menu.png"))
        edit.tap()
        let field2 = app.textFields.firstMatch
        XCTAssertTrue(field2.waitForExistence(timeout: 5))
        field2.typeText(" (изменено)")
        app.buttons["Отправить"].tap()
        XCTAssertTrue(app.staticTexts["изменено"].waitForExistence(timeout: 8) || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'изменено'")).firstMatch.waitForExistence(timeout: 8), "правка не применилась")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/lokey-shots/chat-3-edited.png"))
        // эмодзи и стикеры
        app.buttons["Эмодзи и стикеры"].tap()
        XCTAssertTrue(app.buttons["Стикеры"].waitForExistence(timeout: 5)); Thread.sleep(forTimeInterval: 1.0)
        app.buttons["Стикеры"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/lokey-shots/chat-4a-panel.png"))
        let st = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Закрыто'")).firstMatch
        XCTAssertTrue(st.waitForExistence(timeout: 5)); st.tap()
        Thread.sleep(forTimeInterval: 2.5)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/lokey-shots/chat-4-sticker.png"))
    }
}
