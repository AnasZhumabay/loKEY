// Реализация общего кейса: клиент оборачивает секрет кейса ключом, общим с контактом (см. SharedCaseWrap),
// сервер получает только обёрнутый blob. Секрет в открытом виде никуда не уходит.
//
// Что нужно от слоя чата: `ChatKeyAgreement` (общий секрет X25519 с контактом). Если `chat` его не реализует,
// в мок-режиме используется `DemoKeyAgreement`, в «живом» — ошибка `.keyAgreementUnavailable` (тихо ослабить защиту нельзя).
import Foundation

final class SharedCaseServiceImpl: SharedCaseService, @unchecked Sendable {
    private let repo: VaultRepository
    private let chat: ChatRepository
    private let api: SharedCaseAPI
    private let agreement: ChatKeyAgreement?
    private let keys: KeyStore
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var shared = Set<String>()

    init(repo: VaultRepository, chat: ChatRepository, api: SharedCaseAPI, agreement: ChatKeyAgreement? = nil,
         keys: KeyStore = KeychainKeyStore(service: "com.lokey.shared"), defaults: UserDefaults = .standard) {
        self.repo = repo; self.chat = chat; self.api = api; self.agreement = agreement; self.keys = keys; self.defaults = defaults
    }

    // MARK: Вспомогательное
    private static let declinedKey = "lokey.shared.declined"
    private static let joinedKey = "lokey.shared.joined"

    private func mapped<T>(_ op: () async throws -> T) async throws -> T {
        do { return try await op() }
        catch let e as SharedCaseError { throw e }
        catch let e as APIError {
            if e == .server("not_implemented") { throw SharedCaseError.notImplemented }
            throw SharedCaseError.server(VaultError.from(e).message)
        }
        catch let e as ChatError { throw e.errorDescription.map { SharedCaseError.server($0) } ?? .notReady }
        catch let e as VaultError { throw SharedCaseError.server(e.message) }
        catch { throw SharedCaseError.server("Не удалось выполнить действие. Попробуйте ещё раз.") }
    }

    private func myID() async throws -> String {
        do { return try await chat.myInvite().userID } catch { throw SharedCaseError.notReady }
    }

    private func dh(with contactID: String) async throws -> Data {
        if let a = agreement ?? (chat as? ChatKeyAgreement) {
            do { return try await a.sharedSecret(withContact: contactID) } catch { throw SharedCaseError.keyAgreementUnavailable }
        }
        if await chat.demoInvite() != nil { return DemoKeyAgreement.secret(try await myID(), contactID) }
        throw SharedCaseError.keyAgreementUnavailable
    }

    private func strings(_ key: String) -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    private func setStrings(_ s: Set<String>, _ key: String) { defaults.set(Array(s), forKey: key) }
    private func mark(_ caseId: String, shared flag: Bool) {
        lock.lock(); defer { lock.unlock() }
        if flag { shared.insert(caseId) } else { shared.remove(caseId) }
    }
    private func pendingAccount(_ caseId: String) -> String { "shared.pending.\(caseId)" }

    // MARK: Протокол
    func members(caseId: String) async throws -> [SharedMember] {
        if await repo.isDecoy { return [] }
        let me = try await myID()
        let dtos = try await mapped { try await api.listMembers(caseId: caseId) }
        let list = dtos.map { SharedMember(id: $0.userId, name: $0.userId == me ? "Вы" : $0.displayName, role: $0.role,
                                           status: $0.status, joinedAt: $0.joinedAt, isMe: $0.userId == me) }
        mark(caseId, shared: list.contains { !$0.isMe && $0.role != .owner && $0.status != .revoked }
                              || list.contains { $0.isMe && $0.role != .owner && $0.status == .active })
        return list
    }

    func invite(caseId: String, contactId: String, role: SharedRole) async throws {
        if await repo.isDecoy { throw SharedCaseError.notReady }
        guard SharedRolePolicy.canAssign(role) else { throw SharedCaseError.invalidRole }
        let me = try await myID()
        guard contactId != me else { throw SharedCaseError.notAContact }
        guard await chat.contact(id: contactId) != nil else { throw SharedCaseError.notAContact }
        let current = try await mapped { try await api.listMembers(caseId: caseId) }
        if let mine = current.first(where: { $0.userId == me }), !SharedRolePolicy.canManage(mine.role) { throw SharedCaseError.notOwner }
        if current.contains(where: { $0.userId == contactId && $0.status != .revoked }) { throw SharedCaseError.alreadyMember }
        // Секрет берётся из хранилища (может потребовать Face ID) и живёт в памяти только на время обёртки.
        let secret: Data = try await mapped { try KeyFormat.parse(try await repo.exportKey(caseID: caseId).keyString) }
        let wrapped = try SharedCaseWrap.wrap(secret: secret, sharedSecret: try await dh(with: contactId),
                                              caseId: caseId, inviter: me, invitee: contactId)
        try await mapped { try await api.invite(caseId: caseId, inviteeUserId: contactId, wrappedKeyForInvitee: wrapped, role: role) }
        mark(caseId, shared: true)
    }

    func pendingInvites() async throws -> [SharedInvite] {
        if await repo.isDecoy { return [] }       // приманка не показывает настоящие приглашения
        let dtos = try await mapped { try await api.listInvites() }
        let hidden = strings(Self.declinedKey)
        var out: [SharedInvite] = []
        for d in dtos where !hidden.contains(d.id) {
            let c = await chat.contact(id: d.fromUserId)
            out.append(SharedInvite(id: d.id, caseId: d.caseId, caseName: nil, fromUserId: d.fromUserId,
                                    fromName: c?.name ?? "Неизвестный контакт", fromVerified: c?.verified ?? false, createdAt: d.createdAt))
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    func accept(inviteId: String) async throws {
        if await repo.isDecoy { throw SharedCaseError.notReady }
        let me = try await myID()
        let dtos = try await mapped { try await api.listInvites() }
        guard let inv = dtos.first(where: { $0.id == inviteId }) else { throw SharedCaseError.inviteMalformed }
        // Кейс с таким id уже мой собственный (не присоединённый): приглашение подменное, попыток не тратим.
        if !strings(Self.joinedKey).contains(inv.caseId),
           (try? await repo.listCases())?.contains(where: { $0.id == inv.caseId }) == true { throw SharedCaseError.inviteMalformed }
        _ = try await mapped { try await api.accept(inviteId: inviteId) }
        let secret: Data
        do {
            guard let blob = try await mapped({ try await api.fetchWrappedKey(caseId: inv.caseId) }) else { throw SharedCaseError.inviteMalformed }
            secret = try SharedCaseWrap.unwrap(blob, sharedSecret: try await dh(with: inv.fromUserId),
                                               caseId: inv.caseId, inviter: inv.fromUserId, invitee: me)
        } catch {
            // Ключ не подошёл: откатываем участие, чтобы не висеть «участником» без доступа.
            try? await api.revoke(caseId: inv.caseId, userId: me)
            throw error
        }
        var joined = strings(Self.joinedKey); joined.insert(inv.caseId); setStrings(joined, Self.joinedKey)
        mark(inv.caseId, shared: true)
        do { try await repo.unlockSharedCase(id: inv.caseId, secret: secret) }
        catch {
            // Запись кейса ещё не доступна этому устройству (нужен бэкенд): храним секрет в связке ключей для повторной попытки.
            try? keys.write(secret, account: pendingAccount(inv.caseId))
        }
    }

    func decline(inviteId: String) async throws {
        if await repo.isDecoy { return }
        var hidden = strings(Self.declinedKey); hidden.insert(inviteId); setStrings(hidden, Self.declinedKey)
    }

    func revoke(caseId: String, userId: String) async throws {
        if await repo.isDecoy { throw SharedCaseError.notReady }
        let me = try await myID()
        guard userId != me else { throw SharedCaseError.notOwner }
        let current = try await mapped { try await api.listMembers(caseId: caseId) }
        guard let mine = current.first(where: { $0.userId == me }), SharedRolePolicy.canManage(mine.role) else { throw SharedCaseError.notOwner }
        try await mapped { try await api.revoke(caseId: caseId, userId: userId) }
        _ = try? await members(caseId: caseId)
    }

    func leave(caseId: String) async throws {
        if await repo.isDecoy { throw SharedCaseError.notReady }
        let me = try await myID()
        try await mapped { try await api.revoke(caseId: caseId, userId: me) }
        keys.delete(pendingAccount(caseId))
        var joined = strings(Self.joinedKey); joined.remove(caseId); setStrings(joined, Self.joinedKey)
        mark(caseId, shared: false)
        await repo.lockCase(id: caseId)
    }

    func joinedCaseIds() async -> [String] { if await repo.isDecoy { return [] }; return Array(strings(Self.joinedKey)).sorted() }

    func isShared(caseId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return shared.contains(caseId)
    }

    /// TODO(backend): создать новый секрет, перешифровать sealed_header/файлы и разослать новым обёрнутые копии оставшимся участникам.
    /// Нужны: атомарная смена ключа кейса на сервере (версия ключа), перезапись blob'ов. До тех пор честно сообщаем «не реализовано».
    func rotateKeyAfterRevoke(caseId: String) async throws { throw SharedCaseError.notImplemented }
}
