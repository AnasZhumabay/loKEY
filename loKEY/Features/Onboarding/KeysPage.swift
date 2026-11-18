import SwiftUI

struct KeysPage: View {
    var body: some View {
        OnbPageLayout(page: .keys, title: "Свой ключ\nна каждый кейс",
                      text: "Кейс открывается вашим лицом или ключом. Один кейс — один ключ: если открыт один, остальные остаются закрытыми.",
                      art: { KeyLockArt() },
                      extra: {
            VStack(alignment: .leading, spacing: 12) {
                OnbRow(icon: "faceid", title: "Вход по Face ID", text: "Быстро и удобно на вашем iPhone.")
                OnbRow(icon: "key.fill", title: "Или 32-символьный ключ", text: "Запасной способ открыть кейс без Face ID.")
            }
            .padding(.top, 6)
        })
    }
}

/// Ключ вставляется в замок, замок закрывается. Без движения — готовая картинка с закрытым замком.
struct KeyLockArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var step = 2     // 0 — ключ слева, 1 — в замке, 2 — замок закрыт

    var body: some View {
        ZStack {
            OnbRings(pulse: false)
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.lkCard)
                    .frame(width: 112, height: 112)
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(step == 2 ? Color.lkAccent.opacity(0.7) : Color.lkBorder, lineWidth: 1))
                    .shadow(color: Color.lkAccent.opacity(step == 2 ? 0.35 : 0), radius: 18)
                Image(systemName: step == 2 ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(step == 2 ? Color.lkAccent : Color.lkText2)
                    .contentTransition(.symbolEffect(.replace))
            }
            Image(systemName: "key.fill")
                .font(.system(size: 40, weight: .bold)).foregroundStyle(Color.lkText)
                .rotationEffect(.degrees(-45))
                .offset(x: step == 0 ? -96 : (step == 1 ? -30 : -6), y: step == 2 ? 0 : 4)
                .opacity(step == 2 ? 0 : 1)
                .scaleEffect(step == 2 ? 0.6 : 1)
            OnbChip(text: "32 символа", icon: "number").offset(x: 70, y: 104)
            OnbChip(text: "Face ID", icon: "faceid").offset(x: -82, y: -102)
        }
        .task {
            if reduce { step = 2; return }
            while !Task.isCancelled {
                step = 0
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { step = 1 }
                try? await Task.sleep(for: .milliseconds(800))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { step = 2 }
                Haptics.lock()
                try? await Task.sleep(for: .milliseconds(2200))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ключ открывает замок кейса")
    }
}
