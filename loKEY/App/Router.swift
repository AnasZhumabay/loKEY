import SwiftUI
import Observation

enum AppTab: String, CaseIterable, Hashable { case cases, favorites, journal, settings }

/// Экраны, открываемые «вглубь» (push). Системный navigation bar скрыт — у экранов своя шапка.
enum Route: Hashable {
    case unlock(caseID: String)
    case vaultCase(caseID: String)
    case file(fileID: String, caseID: String)
    case trash
    case sessions
    case plans
    case chats
    case chat(contactID: String)
    case addContact
    case safety(contactID: String)
    case inbox
}

enum CaseIntent { case camera, upload }

enum Cover: Identifiable {
    case newCase
    var id: String { "newCase" }
}

enum AppSheet: Identifiable {
    case deleteCase(caseID: String)
    var id: String {
        switch self { case .deleteCase(let c): return "delete-\(c)" }
    }
}

@MainActor
@Observable
final class Router {
    var tab: AppTab = .cases
    var path: [Route] = []
    var cover: Cover?
    var sheet: AppSheet?
    /// Главный экран ставит намерение («Камера»/«Загрузить»), CaseView выполняет его при появлении и сбрасывает.
    var pendingIntent: CaseIntent?

    func push(_ r: Route) { path.append(r) }
    func pop() { if !path.isEmpty { path.removeLast() } }
    func popToRoot() { path.removeAll() }
    /// Заменить верхний экран (например, разблокировка → кейс)
    func replaceTop(with r: Route) { if !path.isEmpty { path.removeLast() }; path.append(r) }
}
