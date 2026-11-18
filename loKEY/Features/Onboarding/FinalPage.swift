import SwiftUI

struct FinalPage: View {
    var body: some View {
        OnbPageLayout(page: .final, title: "Всё готово.\nЧто дальше?",
                      text: "Это лишь предложения: делайте в своём темпе, ничего не обязательно.",
                      artHeight: 150,
                      art: {
            ZStack {
                OnbRings(pulse: false).scaleEffect(0.6)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 54, weight: .bold)).foregroundStyle(Color.lkAccent)
                    .shadow(color: Color.lkAccent.opacity(0.4), radius: 16)
                    .accessibilityHidden(true)
            }
        }, extra: {
            OnbCard {
                OnbRow(icon: "folder.badge.plus", title: "Создайте первый кейс", text: "Например, «Документы» или «Здоровье».")
                OnbRow(icon: "person.badge.plus", title: "Добавьте контакт", text: "Только при встрече, по QR-коду.")
                OnbRow(icon: "bell.badge.fill", title: "Включите напоминания", text: "О сроках документов. Названия документов в уведомлениях не показываются.", tint: .lkWarn)
            }
            .padding(.top, 8)
            Text("Разрешения мы спросим позже, когда они понадобятся.")
                .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
        })
    }
}
