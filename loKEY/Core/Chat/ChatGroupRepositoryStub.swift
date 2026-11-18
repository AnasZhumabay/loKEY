import Foundation

/// Заглушка групповых чатов (UI нет). Все операции бросают `ChatError.notImplemented`.
///
/// Как это подключится на самом деле:
///  • сеть: `ChatGroupAPI` из `APIServices.chatGroups` (Contract 1.3.0) — создать группу, список, добавить/убрать участника,
///    `send(groupEnvelope:)` с fan-out по `recipientIds`; название группы хранится как `nameCiphertext`, сервер его не видит;
///  • шифрование: нужен `CryptoEngine` с `supportsGroups == true` (MLS / sender keys). Встроенный движок групп не умеет,
///    поэтому `isSupported` = `engine.supportsGroups` и остаётся false, пока движок не заменят;
///  • хранение: групповую историю можно класть в тот же `HistoryStore` под ключом `group:<id>`.
struct ChatGroupRepositoryStub: ChatGroupRepository {
    let api: ChatGroupAPI
    let engine: CryptoEngine

    init(api: ChatGroupAPI = UnavailableChatGroupAPI(), engine: CryptoEngine = BuiltinCryptoEngine()) {
        self.api = api; self.engine = engine
    }

    var isSupported: Bool { engine.supportsGroups && false }   // «&& false»: репозиторий пока не написан, даже если движок готов

    func groups() async throws -> [ChatGroup] { throw ChatError.notImplemented }
    func createGroup(name: String, memberIDs: [String]) async throws -> ChatGroup { throw ChatError.notImplemented }
    func addMember(groupID: String, userID: String) async throws -> ChatGroup { throw ChatError.notImplemented }
    func removeMember(groupID: String, userID: String) async throws -> ChatGroup { throw ChatError.notImplemented }
    func send(text: String, toGroup groupID: String) async throws { throw ChatError.notImplemented }
}
