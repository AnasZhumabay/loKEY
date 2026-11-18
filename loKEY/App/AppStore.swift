import SwiftUI
import Observation

enum AppConfig {
    /// true — приложение работает на локальной «заглушке бэкенда». false — на живом API.
    static let useMocks = true
    /// Заполнить демо-данными (4 кейса) при первом запуске в режиме моков.
    static let seedDemoData = true
    /// В моках Face ID «проходит» без настоящего датчика (удобно на симуляторе).
    /// Только для отладки и только вместе с моками. В боевой сборке Face ID обойти нельзя.
    static var bypassBiometrics: Bool {
        #if DEBUG
        return useMocks
        #else
        return false
        #endif
    }
    static let apiBaseURL = URL(string: "https://api.lokey.example")!
    static let storageLimitBytes: Int64 = 5_000_000_000   // 5 ГБ (десятичные, как в iOS): бесплатный тариф
}

/// Пользовательские настройки на устройстве (не на сервере).
enum Prefs {
    private static let d = UserDefaults.standard
    static var onboardingDone: Bool {
        get {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-lokeyShowOnboarding") { return false }   // для скриншотов
            #endif
            return d.bool(forKey: "onboardingDone")
        }
        set { d.set(newValue, forKey: "onboardingDone") }
    }
    static var autoLockMinutes: Int {
        get { d.object(forKey: "autoLockMinutes") as? Int ?? 15 }
        set { d.set(newValue, forKey: "autoLockMinutes") }
    }
    static var faceID: Bool { get { d.object(forKey: "faceID") as? Bool ?? true } set { d.set(newValue, forKey: "faceID") } }
    static var language: String { get { d.string(forKey: "language") ?? "system" } set { d.set(newValue, forKey: "language") } }
    static var keysSaved: Bool { get { d.bool(forKey: "keysSaved") } set { d.set(newValue, forKey: "keysSaved") } }
    static var shakeToLock: Bool { get { d.object(forKey: "shakeToLock") as? Bool ?? true } set { d.set(newValue, forKey: "shakeToLock") } }
    static var hideNamesInWidgets: Bool { get { d.bool(forKey: "hideNamesInWidgets") } set { d.set(newValue, forKey: "hideNamesInWidgets") } }
}

@MainActor
@Observable
final class AppStore {
    enum Phase { case launching, onboarding, signedOut, signedIn }
    struct Toast: Identifiable, Equatable { let id = UUID(); var text: String; var isError: Bool }

    /// Единственная зависимость от «данных». Во View можно вызывать `store.repo.…` напрямую,
    /// но после любых изменений кейсов/файлов нужно вызвать `await store.refreshCases()`.
    let repo: VaultRepository
    let chat: ChatRepository
    let reminders: ReminderService
    let backup: BackupService
    let sharedCases: SharedCaseService
    private(set) var chatUnread = 0

    private(set) var phase: Phase = .launching
    private(set) var account: AccountDTO?
    private(set) var cases: [VaultCase] = []
    private(set) var storage: StorageUsage?
    /// Секунд до автоблокировки; nil — нет открытых кейсов (или режим «сразу»).
    private(set) var secondsUntilAutoLock: Int?
    var toast: Toast?
    var isPrivacyCovered = false

    var autoLockMinutes: Int { didSet { Prefs.autoLockMinutes = autoLockMinutes; noteActivity() } }
    var faceIDEnabled: Bool { didSet { Prefs.faceID = faceIDEnabled } }
    var hideNamesInWidgets: Bool {
        didSet {
            Prefs.hideNamesInWidgets = hideNamesInWidgets
            // сразу обновляем снимок для виджетов, иначе имена остаются в App Group до следующего обновления списка
            WidgetSync.publish(cases: cases, secondsLeft: secondsUntilAutoLock, hideNames: hideNamesInWidgets, limitBytes: storage?.limitBytes, force: true)
        }
    }
    var keysSaved: Bool = Prefs.keysSaved { didSet { Prefs.keysSaved = keysSaved } }
    var shakeToLock: Bool = Prefs.shakeToLock { didSet { Prefs.shakeToLock = shakeToLock } }
    var language: AppLanguage = AppLanguage(rawValue: Prefs.language) ?? .system {
        didSet { Prefs.language = language.rawValue; LKBundle.language = language }
    }

    private var lastActivity = Date()
    @ObservationIgnored private var chatTick = 0
    private var backgroundedAt: Date?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// Сервисы 1.3 необязательны: без них (превью, старые вызовы) строятся на новой «заглушке бэкенда» или живом API.
    init(repo: VaultRepository, chat: ChatRepository, reminders: ReminderService? = nil,
         backup: BackupService? = nil, sharedCases: SharedCaseService? = nil) {
        self.repo = repo
        self.chat = chat
        self.reminders = reminders ?? ReminderServiceImpl(repo: repo)
        self.backup = backup ?? AppEnvironment.backupService(repo: repo, services: AppEnvironment.makeServices())
        self.sharedCases = sharedCases ?? AppEnvironment.sharedCaseService(repo: repo, chat: chat, services: AppEnvironment.makeServices())
        autoLockMinutes = Prefs.autoLockMinutes
        faceIDEnabled = Prefs.faceID
        hideNamesInWidgets = Prefs.hideNamesInWidgets
    }

    // MARK: Производные
    var unlockedCases: [VaultCase] { cases.filter(\.isUnlocked) }
    func vaultCase(_ id: String) -> VaultCase? { cases.first { $0.id == id } }

    // MARK: Жизненный цикл
    func bootstrap() async {
        guard phase == .launching else { return }
        #if DEBUG
        // Для скриншотов вступления: показываем его, даже если сессия или Prefs.onboardingDone уже есть.
        defer { if ProcessInfo.processInfo.arguments.contains("-lokeyShowOnboarding") { phase = .onboarding } }
        #endif
        account = await repo.restoreSession()
        #if DEBUG
        let demoLoginRequested = AppConfig.useMocks && ProcessInfo.processInfo.arguments.contains("-lokeyDemoLogin")
        #else
        let demoLoginRequested = false
        #endif
        // Мок-бэкенд живёт в памяти, поэтому после перезапуска сессии у него нет. Берём зашифрованный снимок с диска,
        // сразу показываем кейсы из кэша и только потом (stale-while-revalidate) заново подключаемся.
        if account == nil, AppConfig.useMocks, !demoLoginRequested, let snap = await repo.offlineSnapshot() {
            cases = await repo.cachedCases(for: snap)
            account = AccountDTO(id: snap.accountId, email: snap.email, username: snap.username, backupEmail: nil,
                                 mfaEnabled: false, createdAt: snap.savedAt)
            phase = .signedIn
            if let fresh = await repo.resumeOfflineSession(snap) {
                account = fresh
            } else {
                account = nil; cases = []
                phase = Prefs.onboardingDone ? .signedOut : .onboarding
                startTimer(); return
            }
        }
        #if DEBUG
        // Только для автотестов в мок-режиме: быстрый вход без набора пароля.
        if account == nil, AppConfig.useMocks, ProcessInfo.processInfo.arguments.contains("-lokeyDemoLogin") {
            _ = try? await login(identifier: "demo@lokey.app", password: "lokey-demo")
            startTimer(); return
        }
        #endif
        if let acc = account {
            phase = .signedIn
            if await repo.isDecoy {
                // Перезапуск в режиме приманки: настоящий кэш, чаты и напоминания не трогаем.
                await reminders.setSuspended(true)
                await refreshCases()
                startTimer(); return
            }
            // Кэш кейсов показываем сразу (если он есть для этого аккаунта), затем обновляем с сервера.
            if cases.isEmpty, let snap = await repo.offlineSnapshot(), snap.accountId == acc.id {
                cases = await repo.cachedCases(for: snap)
            }
            await configureChat(acc)
            await refreshCases()
        } else {
            phase = Prefs.onboardingDone ? .signedOut : .onboarding
        }
        startTimer()
    }

    func finishOnboarding() {
        Prefs.onboardingDone = true
        phase = account == nil ? .signedOut : .signedIn
    }

    // MARK: Аккаунт
    func login(identifier: String, password: String) async throws -> LoginOutcome {
        let outcome = try await repo.login(identifier: identifier, password: password)
        if case .signedIn(let acc) = outcome { await didSignIn(acc) }
        return outcome
    }
    func verifyMFA(challengeId: String, code: String) async throws {
        await didSignIn(try await repo.verifyMFA(challengeId: challengeId, code: code))
    }
    func register(email: String, username: String, password: String) async throws {
        await didSignIn(try await repo.register(email: email, username: username, password: password))
    }
    private func didSignIn(_ acc: AccountDTO) async {
        await reminders.setSuspended(false)
        account = acc
        Prefs.onboardingDone = true
        phase = .signedIn
        await configureChat(acc)
        await refreshCases()
        noteActivity()
    }
    /// История чата хранится на устройстве в зашифрованном виде (ключ — из Keychain).
    private func configureChat(_ acc: AccountDTO) async {
        let history = await repo.makeHistoryStore()
        try? await chat.configure(accountID: acc.id, username: acc.username, historyStore: history)
    }
    /// `wipeChats` — стереть и локальную историю чатов. По умолчанию история остаётся (зашифрованной) до следующего входа.
    func signOut(wipeChats: Bool = false) async {
        if await repo.isDecoy {
            // Выход из приманки: настоящие сессия, кэш, чаты и напоминания не трогаем и не стираем.
            await repo.lockAll()
            try? await repo.logout()
            await chat.reset(); chatUnread = 0
            account = nil; cases = []; storage = nil; secondsUntilAutoLock = nil
            phase = .signedOut
            return
        }
        await repo.lockAll()
        await repo.clearLocalPersistence(wipeChats: wipeChats)
        try? await repo.logout()
        await chat.reset(); chatUnread = 0
        await reminders.clearAll()
        account = nil; cases = []; storage = nil; secondsUntilAutoLock = nil
        phase = .signedOut
    }
    func updateAccount(_ acc: AccountDTO) { account = acc }

    /// Режим «под принуждением»: верный PIN включает приманку. Снаружи ничего не меняется (ни баннера, ни иконки).
    /// Возвращает false, если PIN не «принудительный» — тогда экран ведёт себя как при обычной ошибке.
    func enterDuress(pin: String) async -> Bool {
        guard await repo.unlockAppWithDuress(pin: pin) else { return false }
        await reminders.setSuspended(true)        // напоминания реального хранилища не видны и не сканируются
        await chat.reset(); chatUnread = 0       // настоящие переписки в приманке не показываем
        await refreshCases()
        noteActivity()
        return true
    }

    // MARK: Данные
    func refreshCases() async {
        if let c = try? await repo.listCases() { cases = c }
        if let s = try? await repo.storageUsage() { storage = s }
        tick()
        WidgetSync.publish(cases: cases, secondsLeft: secondsUntilAutoLock, hideNames: hideNamesInWidgets, limitBytes: storage?.limitBytes)
    }

    /// Забирает входящие сообщения и обновляет бейдж. Звук/вибрацию подаёт только новый непрочитанный.
    func refreshChat() async {
        _ = await chat.expireDue(now: Date())      // исчезающие: просроченное не лежит в памяти и файле
        let added = await chat.sync()
        let total = await chat.unreadTotal
        if added > 0 && total > chatUnread { Haptics.soft() }
        if total != chatUnread { chatUnread = total }
    }

    func unlock(caseID: String, method: UnlockMethod) async throws {
        try await repo.unlockCase(id: caseID, method: method)
        Haptics.soft()
        noteActivity()
        await refreshCases()
    }
    func lock(caseID: String) async {
        await repo.lockCase(id: caseID)
        Haptics.lock()
        await refreshCases()
    }
    func lockAll() async {
        await repo.lockAll()
        Haptics.lock()
        await refreshCases()
    }

    // MARK: Автоблокировка
    /// Вызывать при любом действии пользователя внутри открытого кейса.
    func noteActivity() { lastActivity = Date(); tick() }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
                self?.chatTick += 1
                if let s = self, s.chatTick % 4 == 0, s.phase == .signedIn { await s.refreshChat() }
            }
        }
    }

    private func tick() {
        guard !unlockedCases.isEmpty, autoLockMinutes > 0 else {
            secondsUntilAutoLock = nil
            LiveActivityController.sync(openCaseNames: unlockedCases.map(\.name), secondsLeft: nil)
            return
        }
        let left = max(0, autoLockMinutes * 60 - Int(Date().timeIntervalSince(lastActivity)))
        secondsUntilAutoLock = left
        LiveActivityController.sync(openCaseNames: unlockedCases.map(\.name), secondsLeft: left)
        if left == 0 { Task { await lockAll() } }
    }

    func handleScene(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isPrivacyCovered = false
            if let b = backgroundedAt, autoLockMinutes > 0,
               Date().timeIntervalSince(b) >= Double(autoLockMinutes * 60) { Task { await lockAll() } }
            backgroundedAt = nil
        case .inactive:
            isPrivacyCovered = true
        case .background:
            isPrivacyCovered = true
            backgroundedAt = Date()
            Task { _ = await chat.expireDue(now: Date()) }
            if autoLockMinutes == 0 { Task { await lockAll() } }
        @unknown default: break
        }
    }

    // MARK: Тосты
    func showToast(_ text: String, isError: Bool = false) {
        toast = Toast(text: text, isError: isError)
        isError ? Haptics.error() : Haptics.success()
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            if !Task.isCancelled { self?.toast = nil }
        }
    }
    func showError(_ error: Error) {
        showToast((error as? VaultError)?.message ?? "Что-то пошло не так", isError: true)
    }
}
