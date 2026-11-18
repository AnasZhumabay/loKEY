import SwiftUI

struct ProtectionPage: View {
    var body: some View {
        OnbPageLayout(page: .protection, title: "Защита —\nв нужный момент",
                      text: "Выберите, что включить позже. Сейчас ничего не меняется.",
                      artHeight: 0,
                      art: { Color.clear },
                      extra: {
            OnbCard {
                OnbRow(icon: "iphone.radiowaves.left.and.right", title: "Встряхните телефон",
                       text: "Все кейсы закроются, пока приложение открыто.")
                OnbRow(icon: "clock.badge.checkmark.fill", title: "Автоблокировка",
                       text: "По умолчанию через 15 минут.")
                OnbRow(icon: "theatermasks.fill", title: "Режим приманки",
                       text: "Второй PIN открывает пустое хранилище вместо настоящего.", tint: .lkPurple)
                OnbRow(icon: "flame.fill", title: "Аварийное стирание",
                       text: "После N неверных попыток ключ кейса удаляется с устройства.", tint: .lkWarn)
            }
            .padding(.top, 8)
            OnbCard(stroke: Color.lkBorder, fill: Color.lkCard2) {
                Text("Честные границы").font(.lk(13, .heavy)).tracking(0.4).foregroundStyle(Color.lkMuted)
                Text("Скриншот заблокировать нельзя (запись экрана можно). Сервер видит метаданные: кто кому пишет и когда.")
                    .font(.lk(13, .medium)).foregroundStyle(Color.lkText2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
    }
}
