import AppIntents
import Foundation

/// Мост «Live Activity → приложение». Кнопка «Закрыть» в Dynamic Island / на экране блокировки выполняет
/// этот интент в процессе ПРИЛОЖЕНИЯ (LiveActivityIntent). Приложение при старте регистрирует `handler`.
enum LockAllBridge {
    nonisolated(unsafe) static var handler: (@Sendable () async -> Void)?
}

struct LockAllIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Закрыть все кейсы"
    static var description = IntentDescription("Мгновенно закрывает все открытые кейсы loKEY.")
    static var openAppWhenRun: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        await LockAllBridge.handler?()
        return .result()
    }
}
