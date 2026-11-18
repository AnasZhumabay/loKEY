// Интерфейс чата для UI. UI не знает про ключи, конверты и сеть.
import Foundation

struct ChatContact: Identifiable, Equatable, Sendable {
    var id: String            // id пользователя на сервере
    var username: String
    var name: String
    var safetyNumber: String
    var verified: Bool
    var disappearAfter: TimeInterval?     // nil — не исчезают
    var theme: String? = nil              // id темы чата, общий у обоих (синхронизируется внутри шифртекста)
    var pinned: Bool = false
}

enum ChatMessageState: String, Codable, Sendable { case sending, sent, failed }

struct ChatAttachment: Equatable, Sendable, Codable {
    var name: String
    var bytes: Int
    var data: Data?
}

struct ChatReaction: Equatable, Sendable, Codable { var emoji: String; var fromMe: Bool }

/// Цитата сообщения, на которое отвечают.
struct ChatReply: Equatable, Sendable, Codable { var id: String; var text: String; var fromMe: Bool }

/// Служебная строка в ленте (не сообщение): сейчас только смена таймера исчезновения.
enum ChatSystemLine: Equatable, Sendable, Codable {
    /// nil — исчезающие сообщения выключены.
    case disappear(seconds: TimeInterval?)
}

/// Пресеты таймера исчезновения (чат по умолчанию и переопределение в композере).
enum ChatDisappearPreset {
    static let all: [(title: String, seconds: TimeInterval?)] = [
        ("Выкл", nil), ("30 сек", 30), ("5 мин", 300), ("1 час", 3600), ("1 день", 86400), ("1 неделя", 604800),
    ]
    static func title(for seconds: TimeInterval?) -> String {
        guard let s = seconds else { return "Выкл" }
        if let p = all.first(where: { $0.seconds == s }) { return p.title }
        if s < 60 { return "\(Int(s)) сек" }
        if s < 3600 { return "\(Int(s / 60)) мин" }
        if s < 86400 { return "\(Int(s / 3600)) ч" }
        return "\(Int(s / 86400)) дн"
    }
    /// Верхняя граница, которую принимает получатель (защита от абсурдных значений).
    static let maxSeconds: TimeInterval = 31 * 86400
    static func clamp(_ s: TimeInterval?) -> TimeInterval? {
        guard let s, s.isFinite, s > 0 else { return nil }
        return min(max(s, 1), maxSeconds)
    }
}

/// Параметры отправки одного сообщения.
struct ChatSendOptions: Equatable, Sendable {
    /// true — `ttl` перекрывает таймер чата (в том числе nil = «не исчезает»).
    var overridesTTL = false
    var ttl: TimeInterval? = nil
    /// «Запретить пересылку»: вежливая клиентская пометка (см. Docs/CHAT.md), не защита от модифицированного клиента и скриншотов.
    var noForward = false
    static let chatDefault = ChatSendOptions()
    static func ttl(_ t: TimeInterval?, noForward: Bool = false) -> ChatSendOptions { .init(overridesTTL: true, ttl: t, noForward: noForward) }
}

enum ChatVerifyOutcome: Equatable, Sendable {
    /// Код совпал: контакт отмечен проверенным.
    case match
    /// Хэш не совпал — возможна подмена ключа.
    case mismatch
    /// QR от другого собеседника.
    case wrongContact
    /// Не QR проверки loKEY.
    case invalid
}

struct ChatMessage: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var contactID: String
    var fromMe: Bool
    var text: String
    var attachment: ChatAttachment?
    var at: Date
    var state: ChatMessageState
    var expiresAt: Date?
    var sticker: String? = nil
    var reply: ChatReply? = nil
    var reactions: [ChatReaction] = []
    var edited: Bool = false
    var deleted: Bool = false
    /// Для экрана «Сведения»: номер ключа в цепочке и размер шифртекста.
    var counter: Int? = nil
    var cipherBytes: Int = 0
    /// Срок жизни, сек. У входящего таймер стартует при ПЕРВОМ ПОКАЗЕ (тогда проставляется `expiresAt`), у исходящего при отправке.
    var ttl: TimeInterval? = nil
    /// Пометка «не пересылать» (клиентская, вежливая).
    var noForward: Bool = false
    var system: ChatSystemLine? = nil
}

extension ChatMessage {
    /// false — отправитель попросил не пересылать. Любое будущее «Переслать» / «Сохранить в галерею» / «Копировать» обязано это проверять.
    /// Это клиентская вежливая пометка, а не защита: модифицированный клиент и скриншот её обходят.
    var canForward: Bool { !noForward && !deleted && system == nil }
}

struct ChatThread: Identifiable, Equatable, Sendable {
    var id: String { contact.id }
    var contact: ChatContact
    var last: ChatMessage?
    var unread: Int
}

/// Приглашение: строка `lokey://add?...`, её же кодирует QR.
struct ChatInvite: Equatable, Sendable {
    var userID: String
    var username: String
    var publicKey: Data
    var string: String
}

enum ChatError: Error, LocalizedError, Equatable {
    case notReady, invalidInvite, selfInvite, alreadyAdded, unknownContact, tooLarge, cannotEdit, notImplemented, server(String)
    var errorDescription: String? {
        switch self {
        case .notReady: return "Чат ещё настраивается. Попробуйте через секунду."
        case .invalidInvite: return "Это не приглашение loKEY. Отсканируйте код из раздела «Мой код»."
        case .selfInvite: return "Это ваш собственный код. Отсканируйте код собеседника."
        case .alreadyAdded: return "Этот контакт уже добавлен."
        case .unknownContact: return "Контакт не найден."
        case .tooLarge: return "Вложение слишком большое (до 5 МБ)."
        case .cannotEdit: return "Сообщение можно изменить только в течение 15 минут."
        case .notImplemented: return "Не реализовано: групповые чаты появятся позже."
        case .server(let m): return m
        }
    }
}

protocol ChatRepository: Sendable {
    /// Вызывается после входа: готовит ключи (создаёт при первом запуске) и публикует публичный ключ.
    /// `historyStore` — зашифрованное хранилище истории. AppStore должен передавать
    /// `repo.makeHistoryStore()`; ключ — 32 байта `vault.key.device` из Keychain (ключ устройства, а не аккаунта); nil — история только в памяти
    /// (в мок-режиме тоже nil, пока не передан явно). Повторный вызов с тем же аккаунтом допустим и подключает хранилище, если оно ещё не задано.
    func configure(accountID: String, username: String, historyStore: HistoryStore?) async throws
    func reset() async

    func myInvite() async throws -> ChatInvite
    /// Только для мок-режима: приглашение демо-собеседника. В «живом» режиме nil.
    func demoInvite() async -> String?
    func addContact(invite: String) async throws -> ChatContact

    func threads() async -> [ChatThread]
    func contact(id: String) async -> ChatContact?
    func messages(contactID: String) async -> [ChatMessage]
    /// Забирает и расшифровывает входящие. Возвращает число новых сообщений.
    @discardableResult func sync() async -> Int
    func markRead(contactID: String) async
    func send(text: String, attachment: ChatAttachment?, sticker: String?, replyTo: String?, to contactID: String) async throws -> ChatMessage
    /// То же, но с таймером-переопределением и флагом «не пересылать».
    func send(text: String, attachment: ChatAttachment?, sticker: String?, replyTo: String?, options: ChatSendOptions, to contactID: String) async throws -> ChatMessage
    /// Только свои текстовые сообщения и не позже, чем через 15 минут.
    func edit(messageID: String, text: String, contactID: String) async throws
    /// forEveryone = true: у собеседника тоже (приходит внутри шифртекста); false — только на этом телефоне.
    func delete(messageID: String, forEveryone: Bool, contactID: String) async throws
    /// emoji = nil снимает вашу реакцию.
    func react(messageID: String, emoji: String?, contactID: String) async throws
    func setTheme(_ id: String?, contactID: String) async
    func setPinned(_ pinned: Bool, contactID: String) async

    func setDisappear(_ seconds: TimeInterval?, contactID: String) async
    func markVerified(contactID: String, _ verified: Bool) async
    func clearHistory(contactID: String) async
    func removeContact(id: String) async
    var unreadTotal: Int { get async }

    /// Удаляет из памяти И из сохранённой истории сообщения, чей срок вышел к `now`. Возвращает, сколько удалено. Следов не остаётся.
    func expireDue(now: Date) async -> Int
    /// Вызывается, когда входящие сообщения впервые показаны на экране: именно тогда стартует их таймер исчезновения.
    func messageShown(ids: [String], contactID: String) async
    /// Строка для QR проверки: `lokey://verify?a=<мой id>&b=<id собеседника>&h=<хэш кода безопасности>`.
    func verificationQR(contactID: String) async -> String?
    /// Сверяет отсканированный QR. При совпадении сам вызывает `markVerified(true)`; при подмене снимает отметку.
    func verify(scanned: String, contactID: String) async -> ChatVerifyOutcome
}

extension ChatRepository {
    func configure(accountID: String, username: String) async throws {
        try await configure(accountID: accountID, username: username, historyStore: nil)
    }
    func send(text: String, attachment: ChatAttachment?, sticker: String?, replyTo: String?, options: ChatSendOptions, to contactID: String) async throws -> ChatMessage {
        try await send(text: text, attachment: attachment, sticker: sticker, replyTo: replyTo, to: contactID)
    }
    func expireDue(now: Date) async -> Int { 0 }
    func messageShown(ids: [String], contactID: String) async {}
    func verificationQR(contactID: String) async -> String? { nil }
    func verify(scanned: String, contactID: String) async -> ChatVerifyOutcome { .invalid }
    func send(text: String, attachment: ChatAttachment?, to contactID: String) async throws -> ChatMessage {
        try await send(text: text, attachment: attachment, sticker: nil, replyTo: nil, to: contactID)
    }
}


// MARK: - Группы (задел, без UI)
//
// Как подключится: `ChatGroupRepository` оборачивает `APIServices.chatGroups` (`ChatGroupAPI`, Contract 1.3.0: createGroup/listGroups/
// addMember/removeMember/send(groupEnvelope:)) и `CryptoEngine` с `supportsGroups == true` (встроенный движок групп НЕ поддерживает:
// у него только парные сессии). Пока вместо реализации используется `ChatGroupRepositoryStub`, чьи методы бросают `ChatError.notImplemented`.

struct ChatGroup: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var memberIDs: [String]
    var createdAt: Date
}

protocol ChatGroupRepository: Sendable {
    /// false, пока движок шифрования не умеет групповые ключи.
    var isSupported: Bool { get }
    func groups() async throws -> [ChatGroup]
    func createGroup(name: String, memberIDs: [String]) async throws -> ChatGroup
    func addMember(groupID: String, userID: String) async throws -> ChatGroup
    func removeMember(groupID: String, userID: String) async throws -> ChatGroup
    func send(text: String, toGroup groupID: String) async throws
}
