// Счётчик неверных попыток по кейсу и политика экстренного стирания.
// Лежит в связке ключей, поэтому переживает перезапуск приложения (и выход из аккаунта).
// Сбрасывается только успешным открытием кейса.
import Foundation

struct AttemptState: Codable, Equatable, Sendable {
    var failures: Int = 0
    var lockedUntil: Date?
}

struct AttemptTracker: Sendable {
    let keys: KeyStore
    private func name(_ caseID: String) -> String { "case.attempts.\(caseID)" }

    func state(_ caseID: String) -> AttemptState {
        guard let d = keys.read(name(caseID)), let s = try? JSONDecoder().decode(AttemptState.self, from: d) else { return AttemptState() }
        return s
    }
    private func save(_ s: AttemptState, _ caseID: String) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? keys.write(d, account: name(caseID))
    }
    /// +1 неверная попытка. Возвращает новое состояние.
    @discardableResult
    func recordFailure(_ caseID: String) -> AttemptState {
        var s = state(caseID); s.failures += 1; save(s, caseID); return s
    }
    func setLockedUntil(_ caseID: String, _ date: Date?) {
        var s = state(caseID); s.lockedUntil = date; save(s, caseID)
    }
    /// Успешное открытие (или стирание): счётчик и блокировка обнуляются.
    func reset(_ caseID: String) { keys.delete(name(caseID)) }
}

struct WipePolicyStore: Sendable {
    let keys: KeyStore
    init(keys: KeyStore) { self.keys = keys }
    private var account: String { "wipe.policy" }

    func load() -> WipePolicy {
        guard let d = keys.read(account), let p = try? JSONDecoder().decode(WipePolicy.self, from: d) else { return .off }
        return p.clamped
    }
    func save(_ p: WipePolicy) {
        guard let d = try? JSONEncoder().encode(p.clamped) else { return }
        try? keys.write(d, account: account)
    }
}

/// Чистая логика решения после неверной попытки. Вынесена, чтобы проверять тестами без репозитория.
enum AttemptDecision: Equatable, Sendable {
    case wrong(attemptsLeft: Int)
    case lock
    case wipe

    /// - Parameters:
    ///   - failures: число неверных попыток подряд, уже с текущей.
    ///   - lockEvery: после стольких попыток кейс закрывается на 5 минут.
    static func after(failures: Int, policy: WipePolicy, lockEvery: Int) -> AttemptDecision {
        if policy.shouldWipe(failures: failures) { return .wipe }
        if policy.enabled {
            // При включённом стирании счётчик не сбрасывается блокировкой, иначе до N не дойти.
            if failures % lockEvery == 0 { return .lock }
            return .wrong(attemptsLeft: policy.clamped.maxAttempts - failures)
        }
        if failures >= lockEvery { return .lock }
        return .wrong(attemptsLeft: lockEvery - failures)
    }
}
