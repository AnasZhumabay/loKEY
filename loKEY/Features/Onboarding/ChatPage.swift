import SwiftUI

struct ChatPage: View {
    var body: some View {
        OnbPageLayout(page: .chat, title: "Чат только\nс теми, кого знаете",
                      text: "Переписка шифруется от конца до конца. Контакт добавляется лично по QR-коду, а 60-значный код безопасности помогает убедиться, что это тот самый человек.",
                      artHeight: 270,
                      art: { MockChatArt() },
                      extra: {
            VStack(alignment: .leading, spacing: 12) {
                OnbRow(icon: "qrcode", title: "Знакомство лицом к лицу", text: "Никакого поиска по номеру: добавить можно только при встрече.")
                OnbRow(icon: "timer", title: "Исчезающие сообщения", text: "Можно удалить у обоих: «Удалить для всех».")
            }
            .padding(.top, 6)
        })
    }
}

/// Макет чата из простых вью. Вымышленные имя и сообщения.
struct MockChatArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = 4        // сколько элементов видно
    @State private var vanish = false

    private func bubble(_ text: String, mine: Bool, timer: Bool = false) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            HStack(spacing: 6) {
                Text(tr(text)).font(.lk(13, .medium))
                if timer { Image(systemName: "timer").font(.system(size: 11, weight: .bold)) }
            }
            .foregroundStyle(mine ? Color.lkBg : Color.lkText)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(mine ? Color.lkAccent : Color.lkRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !mine { Spacer(minLength: 40) }
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("А").font(.lk(14, .heavy)).foregroundStyle(Color.lkBg)
                    .frame(width: 32, height: 32).background(Color.lkPurple, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Айдана").font(.lk(14, .bold)).foregroundStyle(Color.lkText)
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 10, weight: .bold))
                        Text("Код безопасности совпал").font(.lk(11, .semibold))
                    }.foregroundStyle(Color.lkAccent)
                }
                Spacer(minLength: 0)
                Image(systemName: "qrcode").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.lkText2)
            }
            .padding(.horizontal, 4)
            Divider().overlay(Color.lkBorder)
            VStack(spacing: 8) {
                if shown >= 1 { bubble("Привет! Это Айдана.", mine: false).transition(.move(edge: .bottom).combined(with: .opacity)) }
                if shown >= 2 { bubble("Скан отправил, смотри", mine: true).transition(.move(edge: .bottom).combined(with: .opacity)) }
                if shown >= 3 {
                    bubble("Это сообщение исчезнет", mine: true, timer: true)
                        .opacity(vanish ? 0.12 : 1).blur(radius: vanish ? 3 : 0)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(14)
        .frame(width: 292, height: 210)
        .background(Color.lkCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.lkBorder, lineWidth: 1))
        .shadow(color: Color.lkAccent.opacity(0.12), radius: 20, y: 8)
        .task {
            if reduce { shown = 3; vanish = false; return }
            while !Task.isCancelled {
                vanish = false; shown = 0
                for i in 1...3 {
                    try? await Task.sleep(for: .milliseconds(650))
                    withAnimation(LKMotion.spring) { shown = i }
                }
                try? await Task.sleep(for: .milliseconds(1600))
                withAnimation(.easeIn(duration: 0.9)) { vanish = true }
                try? await Task.sleep(for: .milliseconds(1800))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Пример чата: контакт подтверждён кодом безопасности, одно сообщение исчезает")
    }
}
