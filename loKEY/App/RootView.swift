import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var router = Router()

    var body: some View {
        ZStack {
            Group {
            switch store.phase {
            case .launching:
                ZStack { GlowBackground(); AnimatedBrandMark().frame(width: 130) }
            case .onboarding:
                OnboardingView()
            case .signedOut:
                AuthView()
            case .signedIn:
                MainShell()
            }
            }
            // Смена языка пересобирает экраны; router живёт выше, поэтому вкладка и навигация сохраняются.
            .id(store.language)
        }
        .environment(\.locale, store.language.locale ?? Locale.autoupdatingCurrent)
        .environment(router)
        .overlay(alignment: .top) {
            if let t = store.toast {
                ToastView(text: t.text, isError: t.isError)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: store.toast)
        .animation(.easeOut(duration: 0.3), value: store.phase)
        .preferredColorScheme(.dark)
        .task { await store.bootstrap() }
        .onReceive(NotificationCenter.default.publisher(for: .lkDeviceShake)) { _ in
            guard store.phase == .signedIn, store.shakeToLock, !store.unlockedCases.isEmpty else { return }
            Task {
                await store.lockAll()
                router.popToRoot()
                store.showToast("Все кейсы закрыты встряхиванием")
            }
        }
    }
}

/// Главная оболочка: NavigationStack + плавающая нижняя панель на корневых экранах.
struct MainShell: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Namespace private var zoomNS

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            ZStack(alignment: .bottom) {
                Group {
                    switch router.tab {
                    case .cases: HomeView()
                    case .favorites: FavoritesView()
                    case .journal: JournalView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(router.tab)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                FloatingTabBar()
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .unlock(let id): UnlockView(caseID: id)
                case .vaultCase(let id): CaseView(caseID: id).lkZoomTarget(id)
                case .file(let fid, let cid): FileViewerView(fileID: fid, caseID: cid)
                case .trash: TrashView()
                case .sessions: SessionsView()
                case .plans: PlansView()
                case .chats: ChatListView()
                case .chat(let id): ChatView(contactID: id)
                case .addContact: AddContactView()
                case .safety(let id): SafetyNumberView(contactID: id)
                case .inbox: InboxView()
                }
            }
        }
        .tint(.lkAccent)
        .environment(\.lkZoomNS, zoomNS)
        .animation(.easeOut(duration: 0.22), value: router.tab)
        .fullScreenCover(item: $router.cover) { cover in
            switch cover { case .newCase: NewCaseFlowView() }
        }
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .deleteCase(let id):
                DeleteCaseSheet(caseID: id)
                    .presentationDetents([.large])
                    .presentationBackground(Color.lkCard)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { store.noteActivity() })
        #if DEBUG
        // Только для автотестов: сразу открыть кейс по имени (аргумент запуска -lokeyOpenCase "Имя").
        .task {
            let a = ProcessInfo.processInfo.arguments
            guard let i = a.firstIndex(of: "-lokeyOpenCase"), i + 1 < a.count else { return }
            for _ in 0..<40 {
                if let c = store.cases.first(where: { $0.name == a[i + 1] && $0.isUnlocked }) { router.push(.vaultCase(caseID: c.id)); return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        #endif
    }
}

/// Плавающая панель из макета: 4 вкладки и круглая «+» по центру.
struct FloatingTabBar: View {
    @Environment(Router.self) private var router
    @Namespace private var pillNS

    var body: some View {
        HStack(spacing: 0) {
            tab(.cases, "square.grid.2x2", "Кейсы")
            tab(.favorites, "star", "Избранное")
            Button { router.cover = .newCase } label: {
                Image(systemName: "plus").font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Color.lkBg)
                    .frame(width: 52, height: 52).background(Color.lkAccent, in: Circle())
            }
            .buttonStyle(LKPressStyle(scale: 0.88)).accessibilityLabel("Новый кейс")
            .frame(maxWidth: .infinity)
            tab(.journal, "waveform.path.ecg", "Журнал")
            tab(.settings, "slider.horizontal.3", "Настройки")
        }
        .padding(.horizontal, 8).frame(height: 68)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.lkCard2.opacity(0.6), in: Capsule())
        .overlay(Capsule().stroke(Color.lkBorder, lineWidth: 1))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func tab(_ t: AppTab, _ icon: String, _ title: String) -> some View {
        let on = router.tab == t
        return Button {
            withAnimation(LKMotion.snappy) { router.tab = t }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: on && t == .favorites ? "star.fill" : icon).font(.system(size: 21, weight: .medium))
                    .symbolEffect(.bounce, value: on)
                    .scaleEffect(on ? 1.12 : 1)
                Text(title).font(.lk(10, on ? .bold : .semibold))
            }
            .foregroundStyle(on ? Color.lkAccent : Color.lkMuted)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                if on {
                    Capsule().fill(Color.lkAccent.opacity(0.12)).padding(.vertical, 4)
                        .matchedGeometryEffect(id: "tabPill", in: pillNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LKPressStyle(scale: 0.9))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Нужно, чтобы работал свайп «назад» при скрытом системном navigation bar.
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
