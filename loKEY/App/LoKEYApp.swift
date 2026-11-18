import SwiftUI

@main
struct LoKEYApp: App {
    @State private var store: AppStore

    init() {
        LKFont.register()
        LKBundle.language = AppLanguage(rawValue: Prefs.language) ?? .system
        let env = AppEnvironment.makeAll()
        let s = AppStore(repo: env.repo, chat: env.chat, reminders: env.reminders, backup: env.backup, sharedCases: env.sharedCases)
        _store = State(initialValue: s)
        // Кнопка «Закрыть все» в Live Activity / Dynamic Island
        LockAllBridge.handler = { await s.lockAll() }
    }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .lkCaptureGuard()
                .environment(store)
                .overlay {
                    // Экран приватности в переключателе приложений
                    if store.isPrivacyCovered { PrivacyCoverView().transition(.opacity) }
                }
                .animation(.easeOut(duration: 0.15), value: store.isPrivacyCovered)
                .onChange(of: scenePhase) { _, new in
                    store.handleScene(new)
                    if new == .active { Task { await store.reminders.schedule() } }
                }
        }
    }
}

/// Единственное место, где выбирается «заглушка» или «живой» бэкенд.
enum AppEnvironment {
    struct Wiring {
        let repo: VaultRepository
        let chat: ChatRepository
        let reminders: ReminderService
        let backup: BackupService
        let sharedCases: SharedCaseService
    }

    static func makeServices() -> APIServices {
        AppConfig.useMocks ? MockBackend.makeServices() : LiveBackend.makeServices(baseURL: AppConfig.apiBaseURL)
    }

    static func backupService(repo: VaultRepository, services: APIServices) -> BackupService {
        let cloud: CloudBackupStore = AppConfig.useMocks ? LocalFolderBackupStore() : ICloudDriveBackupStore()
        return BackupServiceImpl(repo: repo, backupAPI: services.backup, events: services.securityEvents, cloud: cloud)
    }

    static func sharedCaseService(repo: VaultRepository, chat: ChatRepository, services: APIServices) -> SharedCaseService {
        if AppConfig.useMocks {
            // Мок: добавляем демо-приглашение от Алисы; id аккаунта известен только после входа, поэтому читаем лениво.
            let me: @Sendable () async -> String = { (try? await chat.myInvite().userID) ?? "mock-me" }
            let api = DemoSharedCaseAPI(base: MockSharedCaseAPI(meProvider: me), meProvider: me)
            return SharedCaseServiceImpl(repo: repo, chat: chat, api: api, agreement: LazyDemoKeyAgreement(myID: me))
        }
        // Живой режим: настоящий X25519-обмен с контактом (ChatRepositoryImpl), без демо-секрета.
        return SharedCaseServiceImpl(repo: repo, chat: chat, api: services.sharedCases, agreement: chat as? ChatKeyAgreement)
    }

    @MainActor
    static func makeAll() -> Wiring {
        let services = makeServices()
        let repo = VaultRepositoryImpl(api: services)
        let chat = ChatRepositoryImpl(api: services.chat)
        return Wiring(repo: repo, chat: chat, reminders: ReminderServiceImpl(repo: repo),
                      backup: backupService(repo: repo, services: services),
                      sharedCases: sharedCaseService(repo: repo, chat: chat, services: services))
    }

    @MainActor
    static func make() -> (VaultRepository, ChatRepository) {
        let e = makeAll()
        return (e.repo, e.chat)
    }
}
