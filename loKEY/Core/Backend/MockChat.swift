// Мок чата: «почта» в памяти и демо-собеседница Алиса с настоящим шифрованием (те же ChatCrypto, что и у клиента).
import Foundation
import CryptoKit

actor MockChatStore {
    static let botID = "bot-alisa"
    private let botKey = ChatCrypto.generateIdentity()
    private var users: [String: ChatUserDTO] = [:]
    private var mailbox: [String: [ChatEnvelopeDTO]] = [:]
    private var botSessions: [String: ChatCrypto.SessionState] = [:]
    private var seen = Set<String>()
    private let account: @Sendable () async -> AccountDTO?

    private let replies = [
        "Привет! Я демо-собеседница loKEY. Всё, что ты пишешь, шифруется на твоём телефоне.",
        "Сервер видит только набор байтов. Прочитать сообщение могу только я, потому что у меня есть общий ключ с тобой.",
        "Хочешь проверить, что нас никто не подслушивает? Открой «Код безопасности» в меню чата и сверь цифры со мной.",
        "Можешь включить исчезающие сообщения: тогда они удалятся у обоих через выбранное время.",
        "Файлы из кейсов тоже можно отправлять прямо отсюда. Они шифруются тем же ключом.",
    ]
    private var replyIndex = 0

    init(account: @escaping @Sendable () async -> AccountDTO?) {
        self.account = account
        users[Self.botID] = ChatUserDTO(id: Self.botID, username: "alisa_demo", identityKey: botKey.publicKey.rawRepresentation)
    }

    var botInvite: String {
        ChatInviteCodec.encode(id: Self.botID, username: "alisa_demo", key: botKey.publicKey.rawRepresentation)
    }

    private func me() async throws -> AccountDTO {
        guard let a = await account() else { throw APIError.unauthorized }
        return a
    }

    func register(_ pub: Data) async throws -> ChatUserDTO {
        let a = try await me()
        guard pub.count == 32 else { throw APIError.validation("Некорректный ключ") }
        let u = ChatUserDTO(id: a.id, username: a.username, identityKey: pub)
        users[a.id] = u
        return u
    }

    func find(_ id: String) async throws -> ChatUserDTO {
        _ = try await me()
        guard let u = users[id] else { throw APIError.notFound }
        return u
    }

    func send(_ e: ChatEnvelopeDTO) async throws {
        let a = try await me()
        guard e.senderId == a.id else { throw APIError.forbidden }
        guard users[e.recipientId] != nil else { throw APIError.notFound }
        guard !seen.contains(e.id) else { return }
        seen.insert(e.id)
        if e.recipientId == Self.botID { Task { await self.botReply(to: e) } }
        else { mailbox[e.recipientId, default: []].append(e) }
    }

    func fetch(_ limit: Int) async throws -> [ChatEnvelopeDTO] {
        let a = try await me()
        return Array((mailbox[a.id] ?? []).prefix(limit))
    }

    func ack(_ ids: [String]) async throws {
        let a = try await me()
        mailbox[a.id]?.removeAll { ids.contains($0.id) }
    }

    private func botReply(to e: ChatEnvelopeDTO) async {
        try? await Task.sleep(for: .milliseconds(1400))
        guard let user = users[e.senderId] else { return }
        var state: ChatCrypto.SessionState
        if let s = botSessions[user.id] { state = s }
        else { guard let s = try? ChatCrypto.makeSession(mine: botKey, theirPublic: user.identityKey) else { return }; state = s }
        // бот действительно расшифровывает входящее: если шифрование сломано, ответа не будет
        guard let plainIn = try? ChatCrypto.open(e.ciphertext, state: &state, from: user.id, to: Self.botID) else { botSessions[user.id] = state; return }
        botSessions[user.id] = state
        // служебные действия (правка, удаление, реакция, тема) бот расшифровывает, но не отвечает на них
        guard let incoming = try? JSONDecoder().decode(ChatPayload.self, from: plainIn), incoming.k == nil else { return }
        func push(_ payload: ChatPayload, id: String = UUID().uuidString.lowercased()) {
            guard let plain = try? JSONEncoder().encode(payload),
                  let cipher = try? ChatCrypto.seal(plain, state: &state, from: Self.botID, to: user.id) else { return }
            mailbox[user.id, default: []].append(ChatEnvelopeDTO(id: id, senderId: Self.botID, recipientId: user.id,
                                                                  version: ChatCrypto.version, ciphertext: cipher, sentAt: Date(), expiresAt: nil))
        }
        // каждое второе сообщение пользователя бот «лайкает»
        if replyIndex % 2 == 0 { var r = ChatPayload(t: ""); r.k = "react"; r.r = e.id; r.e = "❤️"; push(r) }
        var reply = ChatPayload(t: incoming.s != nil ? "" : replies[replyIndex % replies.count])
        if incoming.s != nil { reply.s = "heart" }
        replyIndex += 1
        push(reply)
        botSessions[user.id] = state
    }
}

struct MockChatAPI: ChatAPI {
    let s: MockChatStore
    func registerIdentity(publicKey: Data) async throws -> ChatUserDTO { try await s.register(publicKey) }
    func findUser(id: String) async throws -> ChatUserDTO { try await s.find(id) }
    func send(_ envelope: ChatEnvelopeDTO) async throws { try await s.send(envelope) }
    func fetch(limit: Int) async throws -> [ChatEnvelopeDTO] { try await s.fetch(limit) }
    func acknowledge(ids: [String]) async throws { try await s.ack(ids) }
    func demoInvite() async -> String { await s.botInvite }
}
