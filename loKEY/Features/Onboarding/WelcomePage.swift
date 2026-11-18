import SwiftUI

struct WelcomePage: View {
    var body: some View {
        OnbPageLayout(page: .welcome, title: "Ключ есть\nтолько у вас",
                      text: "loKEY хранит документы и переписку так, что открыть их можете только вы. Файлы шифруются на iPhone ещё до отправки.",
                      art: {
            ZStack {
                OnbRings()
                AnimatedBrandMark().frame(width: 128)
                OnbChip(text: "AES-256-GCM").offset(x: -78, y: -108)
                OnbChip(text: "только на iPhone", icon: "iphone").offset(x: 52, y: 104)
            }
        }, extra: {
            VStack(alignment: .leading, spacing: 12) {
                OnbRow(icon: "lock.shield.fill", title: "Кейсы с отдельными ключами")
                OnbRow(icon: "bubble.left.and.bubble.right.fill", title: "Чат со сквозным шифрованием")
            }
            .padding(.top, 6)
        })
    }
}
