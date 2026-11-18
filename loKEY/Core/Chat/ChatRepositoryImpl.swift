import Foundation
import CryptoKit

actor ChatRepositoryImpl: ChatRepository, ChatKeyAgreement {
    struct StoredContact: Codable {
        var id: String; var username: String; var name: String
        var publicKey: Data; var verified: Bool; var disappear: Double?
        var theme: String? = nil; var pinned: Bool? = nil
    }
    private struct Persisted: Codable {
        var contacts: [StoredContact] = []
        /// Старый формат (до CryptoEngine): состояния встроенного движка. Только чтение; при миграции JSON тот же, что у BuiltinCryptoEngine.
        var sessions: [String: ChatCrypto.SessionState]?
        /// Новый формат: непрозрачные байты сессии движка.
        var sessionBlobs: [String: Data]?
        var engine: String?
    }
    private struct IdentityBlob: Codable { var p: Data; var u: Data }
    /// Сериализованная история одного собеседника (лежит внутри зашифрованного HistoryStore).
    private struct HistoryBlob: Codable { var v = 1; var messages: [ChatMessage] }

    private let api: ChatAPI
    private let keys: KeyStore
    private let persist: Bool
    private let engine: CryptoEngine
    private let clock: @Sendable () -> Date
    private var historyStore: HistoryStore?
    private var dirty = Set<String>()
    private var flushing = false

    private var myID: String?
    private var myName = ""
    private var identity: CryptoIdentity?
    private var contacts: [String: StoredContact] = [:]
    private var sessions: [String: Data] = [:]
    private var history: [String: [ChatMessage]] = [:]
    private var unread: [String: Int] = [:]
    private var seen = Set<String>()
    /// Уже зашифрованные конверты, которые не ушли на сервер: повторяем ИХ ЖЕ (новый ключ не тратим).
    private var pending: [String: ChatEnvelopeDTO] = [:]

    init(api: ChatAPI, keys: KeyStore = KeychainKeyStore(service: "com.lokey.chat"), persist: Bool? = nil,
         engine: CryptoEngine = BuiltinCryptoEngine(), historyStore: HistoryStore? = nil,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api; self.keys = keys
        self.persist = persist ?? !AppConfig.useMocks
        self.engine = engine; self.historyStore = historyStore; self.clock = clock
    }

    // MARK: Настройка

    func configure(accountID: String, username: String, historyStore store: HistoryStore?) async throws {
        if myID == accountID, identity != nil {
            if let store, historyStore == nil { historyStore = store; await loadHistory() }
            return
        }
        if let store { historyStore = store }
        myID = accountID; myName = username
        let name = "chat.identity.\(accountID)"
        if persist {
            switch keys.lookup(name) {
            case .found(let raw):
                if raw.count == 32, let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
                    identity = CryptoIdentity(privateKey: raw, publicKey: k.publicKey.rawRepresentation)     // старый формат
                } else if let b = try? JSONDecoder().decode(IdentityBlob.self, from: raw) {
                    identity = CryptoIdentity(privateKey: b.p, publicKey: b.u)
                } else { myID = nil; throw ChatError.notReady }
            case .missing:
                let k = engine.generateIdentity()
                guard let blob = try? JSONEncoder().encode(IdentityBlob(p: k.privateKey, u: k.publicKey)) else { myID = nil; throw ChatError.notReady }
                try keys.write(blob, account: name)
                identity = k
            case .failed:
                // Хранилище недоступно (например, устройство заблокировано): новую личность НЕ создаём, чтобы не затереть настоящую.
                myID = nil; throw ChatError.notReady
            }
            switch keys.lookup("chat.state.\(accountID)") {
            case .found(let d):
                if let p = try? JSONDecoder().decode(Persisted.self, from: d) {
                    contacts = Dictionary(uniqueKeysWithValues: p.contacts.map { ($0.id, $0) })
                    if let blobs = p.sessionBlobs { sessions = blobs }
                    else if let legacy = p.sessions {
                        sessions = legacy.compactMapValues { try? JSONEncoder().encode($0) }
                    }
                }
            case .missing: break
            case .failed: myID = nil; identity = nil; throw ChatError.notReady
            }
        } else {
            identity = engine.generateIdentity()
        }
        guard let pub = identity?.publicKey else { throw ChatError.notReady }
        _ = try await mapped { try await api.registerIdentity(publicKey: pub) }
        await loadHistory()
    }

    // MARK: Постоянная история

    /// Загружает историю из HistoryStore (если он подключён). Просроченное выбрасывается и стирается с диска; «отправляется» -> «не отправлено».
    private func loadHistory() async {
        guard let store = historyStore, let acc = myID else { return }
        guard let blobs = try? await store.load(accountId: acc) else { return }
        let now = clock()
        for (cid, data) in blobs where contacts[cid] != nil {
            guard let b = try? JSONDecoder().decode(HistoryBlob.self, from: data) else { continue }
            var msgs = b.messages
            let before = msgs.count
            msgs.removeAll { ($0.expiresAt ?? .distantFuture) <= now }
            for i in msgs.indices where msgs[i].state == .sending { msgs[i].state = .failed }
            history[cid] = msgs
            if msgs.count != before { dirty.insert(cid) }
        }
        await flush()
    }

    /// Пишет историю изменившихся собеседников. Один писатель за раз: поздняя запись не затрёт более новую.
    private func persistHistory(_ cids: Set<String>) async {
        dirty.formUnion(cids)
        await flush()
    }

    private func flush() async {
        guard let store = historyStore, let acc = myID else { dirty = []; return }
        if flushing { return }       // уже идущий цикл подхватит новые id
        flushing = true; defer { flushing = false }
        while let cid = dirty.popFirst() {
            guard let blob = try? JSONEncoder().encode(HistoryBlob(messages: history[cid] ?? [])) else { continue }
            try? await store.save(accountId: acc, contactId: cid, blob)
        }
    }

    func reset() async {
        myID = nil; identity = nil; contacts = [:]; sessions = [:]; history = [:]; unread = [:]; seen = []; dirty = []
        // historyStore остаётся подключённым: файлы зашифрованы ключом аккаунта, при следующем входе они подхватятся.
    }

    /// false — состояние не удалось сохранить (тогда сообщение отправлять нельзя: ключ уже использован).
    @discardableResult
    private func save() -> Bool {
        guard persist, let id = myID else { return true }
        let p = Persisted(contacts: Array(contacts.values), sessions: nil, sessionBlobs: sessions, engine: engine.name)
        guard let d = try? JSONEncoder().encode(p) else { return false }
        do { try keys.write(d, account: "chat.state.\(id)"); return true } catch { return false }
    }

    private func mapped<T>(_ op: () async throws -> T) async throws -> T {
        do { return try await op() }
        catch let e as APIError { throw ChatError.server(VaultError.from(e).message) }
        catch let e as ChatError { throw e }
        catch { throw ChatError.server("Не удалось связаться с сервером") }
    }

    private func ready() throws -> (String, CryptoIdentity) {
        guard let id = myID, let k = identity else { throw ChatError.notReady }
        return (id, k)
    }

    private func domain(_ c: StoredContact) -> ChatContact {
        let mine = identity?.publicKey ?? Data()
        return ChatContact(id: c.id, username: c.username, name: c.name, safetyNumber: engine.safetyNumber(mine: mine, theirs: c.publicKey),
                           verified: c.verified, disappearAfter: c.disappear, theme: c.theme, pinned: c.pinned ?? false)
    }

    private func newSession(peer: Data) throws -> Data {
        guard let id = identity else { throw ChatError.notReady }
        do { return try engine.establishSession(identity: id, peerPublic: peer) } catch { throw ChatError.invalidInvite }
    }

    // MARK: Общий секрет с контактом (для общих кейсов)

    /// X25519 между моим приватным ключом личности и публичным ключом контакта; результат пропущен через HKDF с меткой
    /// назначения, поэтому не совпадает с ключами сессий чата. Одинаков у обеих сторон.
    func sharedSecret(withContact contactID: String) async throws -> Data {
        let (_, me) = try ready()
        guard let c = contacts[contactID] else { throw ChatError.notReady }
        do {
            let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: me.privateKey)
            let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: c.publicKey)
            let dh = try priv.sharedSecretFromKeyAgreement(with: pub)
            let key = dh.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("lokey.shared-case.dh.v1".utf8),
                                                 sharedInfo: Data(), outputByteCount: 32)
            return key.withUnsafeBytes { Data($0) }
        } catch { throw ChatError.notReady }
    }

    // MARK: Исчезающие сообщения

    /// Удаляет просроченное из памяти и из сохранённой истории. Заглушек не оставляет.
    func expireDue(now: Date) async -> Int {
        var removed = 0
        var touched = Set<String>()
        for cid in Array(history.keys) {
            let before = history[cid]?.count ?? 0
            history[cid]?.removeAll { ($0.expiresAt ?? .distantFuture) <= now }
            let d = before - (history[cid]?.count ?? 0)
            if d > 0 { removed += d; touched.insert(cid) }
        }
        if !touched.isEmpty { await persistHistory(touched) }
        return removed
    }

    /// Таймер входящего сообщения стартует при ПЕРВОМ ПОКАЗЕ на экране, а не при получении.
    func messageShown(ids: [String], contactID: String) async {
        let now = clock()
        var changed = false
        for id in ids {
            guard let i = history[contactID]?.firstIndex(where: { $0.id == id }), let m = history[contactID]?[i],
                  !m.fromMe, m.expiresAt == nil, let t = m.ttl else { continue }
            history[contactID]?[i].expiresAt = now.addingTimeInterval(t)
            changed = true
        }
        if changed { await persistHistory([contactID]) }
    }

    private func appendSystem(_ line: ChatSystemLine, fromMe: Bool, contactID: String) {
        var text = ""
        if case .disappear(let s) = line { text = s == nil ? "Исчезающие сообщения: выкл" : "Исчезающие сообщения: " + ChatDisappearPreset.title(for: s) }
        history[contactID, default: []].append(ChatMessage(id: UUID().uuidString.lowercased(), contactID: contactID, fromMe: fromMe, text: text,
                                                           at: clock(), state: .sent, expiresAt: nil, system: line))
    }

    // MARK: Проверка по QR

    func verificationQR(contactID: String) async -> String? {
        guard let c = contacts[contactID], let me = myID else { return nil }
        return ChatVerifyCodec.encode(myID: me, theirID: contactID, safetyNumber: domain(c).safetyNumber)
    }

    func verify(scanned: String, contactID: String) async -> ChatVerifyOutcome {
        guard let c = contacts[contactID], let me = myID, let parsed = ChatVerifyCodec.decode(scanned) else { return .invalid }
        switch ChatVerifyCodec.compare(parsed, myID: me, theirID: contactID, safetyNumber: domain(c).safetyNumber) {
        case .match: contacts[contactID]?.verified = true; save(); return .match
        case .mismatch: contacts[contactID]?.verified = false; save(); return .mismatch
        case .wrongContact: return .wrongContact
        }
    }

    // MARK: Контакты

    func myInvite() async throws -> ChatInvite {
        let (id, k) = try ready()
        let s = ChatInviteCodec.encode(id: id, username: myName, key: k.publicKey)
        return ChatInvite(userID: id, username: myName, publicKey: k.publicKey, string: s)
    }

    func demoInvite() async -> String? {
        guard let mock = api as? MockChatAPI else { return nil }
        return await mock.demoInvite()
    }

    func addContact(invite: String) async throws -> ChatContact {
        let (me, _) = try ready()
        guard let inv = ChatInviteCodec.decode(invite) else { throw ChatError.invalidInvite }
        if inv.id == me { throw ChatError.selfInvite }
        if let existing = contacts[inv.id] {
            // Контакт мог появиться автоматически (по ключу от сервера). QR очный, поэтому сверяем ключ и подтверждаем контакт.
            guard existing.publicKey == inv.key else { throw ChatError.server("Ключ в приглашении не совпал с ключом контакта. Возможна подмена, не доверяйте этому чату.") }
            contacts[inv.id]?.verified = true; save()
            guard let c = contacts[inv.id] else { throw ChatError.invalidInvite }
            return domain(c)
        }
        // Ключ из QR сверяем с серверным: расхождение = попытка подмены.
        let server = try await mapped { try await api.findUser(id: inv.id) }
        guard server.identityKey == inv.key else { throw ChatError.server("Ключ в приглашении не совпал с серверным. Контакт не добавлен.") }
        let state = try newSession(peer: inv.key)
        let c = StoredContact(id: inv.id, username: server.username, name: server.username, publicKey: inv.key, verified: false, disappear: nil)
        contacts[c.id] = c; sessions[c.id] = state; save()
        return domain(c)
    }

    func contact(id: String) async -> ChatContact? { contacts[id].map(domain) }

    func threads() async -> [ChatThread] {
        _ = await expireDue(now: clock())
        return contacts.values.map { c in
            ChatThread(contact: domain(c), last: history[c.id]?.last, unread: unread[c.id] ?? 0)
        }
        .sorted { a, b in
            if a.contact.pinned != b.contact.pinned { return a.contact.pinned }
            return (a.last?.at ?? .distantPast) > (b.last?.at ?? .distantPast)
        }
    }

    func messages(contactID: String) async -> [ChatMessage] { _ = await expireDue(now: clock()); return history[contactID] ?? [] }
    var unreadTotal: Int { unread.values.reduce(0, +) }
    func markRead(contactID: String) async { unread[contactID] = 0 }

    // MARK: Отправка

    private func snippet(_ m: ChatMessage) -> String {
        if m.deleted { return "Сообщение удалено" }
        if m.sticker != nil { return "Стикер" }
        if let a = m.attachment { return "📎 " + a.name }
        return String(m.text.prefix(80))
    }

    /// Шифрует и кладёт на сервер. Ключ сообщения расходуется до отправки, поэтому состояние сохраняем сразу.
    private func deliver(_ payload: ChatPayload, id: String, to cid: String, at: Date) async throws -> (counter: Int, bytes: Int) {
        let (me, _) = try ready()
        guard let state = sessions[cid] else { throw ChatError.unknownContact }
        let plain = try JSONEncoder().encode(payload)
        let cipher: Data
        do {
            let r = try engine.seal(plain, session: state, from: me, to: cid)
            cipher = r.ciphertext; sessions[cid] = r.session
        } catch { throw ChatError.server("Не удалось зашифровать сообщение") }
        guard save() else { throw ChatError.notReady }          // ключ потрачен, а сохранить не вышло — не отправляем
        let counter = Int(cipher.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let env = ChatEnvelopeDTO(id: id, senderId: me, recipientId: cid, version: ChatCrypto.version, ciphertext: cipher,
                                  sentAt: at, expiresAt: at.addingTimeInterval(30 * 86400))
        do { try await mapped { try await api.send(env) } }
        catch { pending[id] = env; throw error }               // позже отправим тот же конверт
        return (counter, cipher.count)
    }

    func send(text: String, attachment: ChatAttachment?, sticker: String?, replyTo: String?, to contactID: String) async throws -> ChatMessage {
        try await send(text: text, attachment: attachment, sticker: sticker, replyTo: replyTo, options: .chatDefault, to: contactID)
    }

    func send(text: String, attachment: ChatAttachment?, sticker: String?, replyTo: String?, options: ChatSendOptions, to contactID: String) async throws -> ChatMessage {
        let (me, _) = try ready()
        guard let c = contacts[contactID], sessions[contactID] != nil else { throw ChatError.unknownContact }
        if let a = attachment, a.bytes > 5_000_000 { throw ChatError.tooLarge }
        let now = clock()
        let id = UUID().uuidString.lowercased()
        let ttl = ChatDisappearPreset.clamp(options.overridesTTL ? options.ttl : c.disappear)
        var reply: ChatReply?
        if let rid = replyTo, let orig = history[contactID]?.first(where: { $0.id == rid }) {
            reply = ChatReply(id: rid, text: snippet(orig), fromMe: orig.fromMe)
        }
        var payload = ChatPayload(t: text, ttl: ttl, an: attachment?.name, ad: attachment?.data)
        payload.s = sticker; payload.rp = reply?.id; payload.rt = reply?.text
        payload.nf = options.noForward ? true : nil
        var msg = ChatMessage(id: id, contactID: contactID, fromMe: true, text: text,
                              attachment: attachment.map { ChatAttachment(name: $0.name, bytes: $0.bytes, data: $0.data) },
                              at: now, state: .sending, expiresAt: ttl.map { now.addingTimeInterval($0) },
                              sticker: sticker, reply: reply, ttl: ttl, noForward: options.noForward)
        history[contactID, default: []].append(msg)
        do {
            let r = try await deliver(payload, id: id, to: contactID, at: now)
            msg.counter = r.counter; msg.cipherBytes = r.bytes; msg.state = .sent
        } catch {
            msg.state = .failed; update(msg); await persistHistory([contactID]); throw error
        }
        update(msg)
        await persistHistory([contactID])
        _ = me
        return msg
    }

    private func update(_ m: ChatMessage) {
        if let i = history[m.contactID]?.firstIndex(where: { $0.id == m.id }) { history[m.contactID]?[i] = m }
    }

    private func control(_ kind: String, target: String?, text: String = "", emoji: String? = nil, theme: String? = nil, ttl: Double? = nil, to cid: String) async throws {
        var p = ChatPayload(t: text); p.k = kind; p.r = target; p.e = emoji; p.th = theme; p.ttl = ttl
        _ = try await deliver(p, id: UUID().uuidString.lowercased(), to: cid, at: clock())
    }

    func edit(messageID: String, text: String, contactID: String) async throws {
        guard let i = history[contactID]?.firstIndex(where: { $0.id == messageID }), var m = history[contactID]?[i], m.fromMe, !m.deleted,
              m.sticker == nil, m.attachment == nil else { throw ChatError.unknownContact }
        guard clock().timeIntervalSince(m.at) <= 15 * 60 else { throw ChatError.cannotEdit }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try await control("edit", target: messageID, text: t, to: contactID)
        m.text = t; m.edited = true
        history[contactID]?[i] = m
        await persistHistory([contactID])
    }

    func delete(messageID: String, forEveryone: Bool, contactID: String) async throws {
        guard let i = history[contactID]?.firstIndex(where: { $0.id == messageID }) else { return }
        if forEveryone, history[contactID]?[i].fromMe == true {
            try await control("del", target: messageID, to: contactID)
            if var arr = history[contactID], arr.indices.contains(i) { Self.tombstone(&arr[i]); history[contactID] = arr }
        } else {
            history[contactID]?.remove(at: i)
        }
        await persistHistory([contactID])
    }

    private static func tombstone(_ m: inout ChatMessage) {
        m.deleted = true; m.text = ""; m.attachment = nil; m.sticker = nil; m.reactions = []; m.reply = nil
    }

    func react(messageID: String, emoji: String?, contactID: String) async throws {
        guard let i = history[contactID]?.firstIndex(where: { $0.id == messageID }), history[contactID]?[i].deleted == false else { return }
        try await control("react", target: messageID, emoji: emoji ?? "", to: contactID)
        history[contactID]?[i].reactions.removeAll { $0.fromMe }
        if let e = emoji, !e.isEmpty { history[contactID]?[i].reactions.append(ChatReaction(emoji: e, fromMe: true)) }
        await persistHistory([contactID])
    }

    func setTheme(_ id: String?, contactID: String) async {
        guard contacts[contactID] != nil else { return }
        contacts[contactID]?.theme = id; save()
        try? await control("theme", target: nil, theme: id ?? "", to: contactID)
    }

    func setPinned(_ pinned: Bool, contactID: String) async { contacts[contactID]?.pinned = pinned; save() }

    // MARK: Приём

    @discardableResult
    func sync() async -> Int {
        guard let (me, _) = try? ready() else { return 0 }
        // повторная отправка конвертов, которые не дошли (тот же шифртекст, тот же id)
        for (id, env) in pending {
            if (try? await api.send(env)) != nil {
                pending[id] = nil
                if let i = history[env.recipientId]?.firstIndex(where: { $0.id == id }) { history[env.recipientId]?[i].state = .sent }
            }
        }
        guard let envs = try? await api.fetch(limit: 100), !envs.isEmpty else { return 0 }
        var acked: [String] = []
        var added = 0
        var touched = Set<String>()
        for e in envs.sorted(by: { $0.sentAt < $1.sentAt }) {
            // постоянные отказы подтверждаем (иначе зациклимся), временные (сеть) — оставляем на сервере
            guard e.recipientId == me, e.version == ChatCrypto.version, !seen.contains(e.id) else { acked.append(e.id); continue }
            if contacts[e.senderId] == nil {
                let u: ChatUserDTO
                do { u = try await api.findUser(id: e.senderId) }
                catch let err as APIError { if err == .notFound { acked.append(e.id) }; continue }
                catch { continue }
                guard let st = try? newSession(peer: u.identityKey) else { acked.append(e.id); continue }
                contacts[u.id] = StoredContact(id: u.id, username: u.username, name: u.username, publicKey: u.identityKey, verified: false, disappear: nil)
                sessions[u.id] = st
            }
            guard let state = sessions[e.senderId] else { acked.append(e.id); continue }
            guard let opened = try? engine.open(e.ciphertext, session: state, from: e.senderId, to: me),
                  let p = try? JSONDecoder().decode(ChatPayload.self, from: opened.plain) else { seen.insert(e.id); acked.append(e.id); continue }
            sessions[e.senderId] = opened.session
            seen.insert(e.id); acked.append(e.id)
            let sid = e.senderId
            touched.insert(sid)
            switch p.k {
            case "edit":
                if let i = history[sid]?.firstIndex(where: { $0.id == p.r && !$0.fromMe && !$0.deleted }) {
                    history[sid]?[i].text = p.t; history[sid]?[i].edited = true
                }
            case "del":
                if let i = history[sid]?.firstIndex(where: { $0.id == p.r && !$0.fromMe }) , var arr = history[sid], arr.indices.contains(i) { Self.tombstone(&arr[i]); history[sid] = arr }
            case "react":
                if let i = history[sid]?.firstIndex(where: { $0.id == p.r }) {
                    history[sid]?[i].reactions.removeAll { !$0.fromMe }
                    if let em = p.e, !em.isEmpty { history[sid]?[i].reactions.append(ChatReaction(emoji: em, fromMe: false)) }
                }
            case "theme":
                if let th = p.th { contacts[sid]?.theme = th.isEmpty ? nil : th }
            case "ttl":
                let v = ChatDisappearPreset.clamp(p.ttl)
                if contacts[sid]?.disappear != v {
                    contacts[sid]?.disappear = v
                    appendSystem(.disappear(seconds: v), fromMe: false, contactID: sid)
                }
            default:
                let att = p.an.map { ChatAttachment(name: $0, bytes: p.ad?.count ?? 0, data: p.ad) }
                var reply: ChatReply?
                if let rid = p.rp {
                    if let orig = history[sid]?.first(where: { $0.id == rid }) { reply = ChatReply(id: rid, text: snippet(orig), fromMe: orig.fromMe) }
                    else { reply = ChatReply(id: rid, text: p.rt ?? "", fromMe: false) }
                }
                let counter = Int(e.ciphertext.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                history[sid, default: []].append(ChatMessage(id: e.id, contactID: sid, fromMe: false, text: p.t, attachment: att, at: e.sentAt,
                                                             state: .sent, expiresAt: nil,      // таймер стартует при первом показе (messageShown)
                                                             sticker: p.s, reply: reply, counter: counter, cipherBytes: e.ciphertext.count,
                                                             ttl: ChatDisappearPreset.clamp(p.ttl), noForward: p.nf ?? false))
                unread[sid, default: 0] += 1
                added += 1
            }
        }
        save()
        await persistHistory(touched)
        if !acked.isEmpty { try? await api.acknowledge(ids: acked) }
        return added
    }

    // MARK: Настройки чата

    /// Таймер чата по умолчанию. Собеседник получает служебное сообщение, и у обоих в ленте появляется строка «Исчезающие сообщения: …».
    func setDisappear(_ seconds: TimeInterval?, contactID: String) async {
        guard contacts[contactID] != nil else { return }
        let v = ChatDisappearPreset.clamp(seconds)
        guard contacts[contactID]?.disappear != v else { return }
        contacts[contactID]?.disappear = v; save()
        appendSystem(.disappear(seconds: v), fromMe: true, contactID: contactID)
        try? await control("ttl", target: nil, ttl: v ?? 0, to: contactID)
        await persistHistory([contactID])
    }
    func markVerified(contactID: String, _ verified: Bool) async { contacts[contactID]?.verified = verified; save() }
    func clearHistory(contactID: String) async { history[contactID] = []; unread[contactID] = 0; await persistHistory([contactID]) }
    func removeContact(id: String) async {
        contacts[id] = nil; sessions[id] = nil; history[id] = nil; unread[id] = nil; save()
        await persistHistory([id])      // пустая история перезаписывает сохранённую
    }
}
