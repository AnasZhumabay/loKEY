import SwiftUI
import UIKit

/// Защита от записи экрана и зеркалирования: пока экран снимается, всё содержимое закрыто заслонкой.
/// Скриншот ОС заблокировать не может — после него показываем предупреждение.
private struct CaptureGuard: ViewModifier {
    @Environment(AppStore.self) private var store
    @State private var captured = UIScreen.main.isCaptured

    func body(content: Content) -> some View {
        content
            .overlay {
                if captured { CaptureShield().transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.2), value: captured)
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                let now = UIScreen.main.isCaptured
                if now && !captured { Haptics.warning() }
                captured = now
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                guard store.phase == .signedIn, !store.unlockedCases.isEmpty else { return }
                Haptics.warning()
                store.showToast("Скриншот открытого кейса. Проверьте, что в галерее нет секретных данных.", isError: true)
            }
    }
}

private struct CaptureShield: View {
    var body: some View {
        ZStack {
            Color(hex: 0x0A0D10)
            VStack(spacing: 18) {
                Image(systemName: "record.circle").font(.system(size: 54, weight: .light)).foregroundStyle(Color.lkDanger)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Идёт запись экрана").font(.lk(22, .heavy))
                Text("Содержимое loKEY скрыто, пока экран записывается или транслируется. Остановите запись, чтобы продолжить.")
                    .font(.lk(14, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func lkCaptureGuard() -> some View { modifier(CaptureGuard()) }
}
