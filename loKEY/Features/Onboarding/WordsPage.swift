import SwiftUI

struct WordsPage: View {
    var body: some View {
        OnbPageLayout(page: .words, title: "12 слов —\nзапасной вход",
                      text: "При создании аккаунта вы получите 12 слов восстановления. Они вернут доступ на новом телефоне. Запишите их на бумаге и храните офлайн.",
                      art: { MaskedWordsArt() },
                      extra: {
            OnbCard(stroke: Color.lkWarn.opacity(0.5), fill: Color.lkWarn.opacity(0.08)) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lkWarn)
                        .font(.system(size: 18, weight: .bold)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Важно").font(.lk(15, .heavy)).foregroundStyle(Color.lkText)
                        Text("Если потеряны и ключ, и 12 слов, вернуть доступ нельзя: сервер хранит только шифртекст и ничего не может расшифровать.")
                            .font(.lk(14, .medium)).foregroundStyle(Color.lkText2).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .padding(.top, 6)
        })
    }
}

/// Только маски — настоящие слова здесь не создаются и не показываются.
struct MaskedWordsArt: View {
    private let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    var body: some View {
        LazyVGrid(columns: cols, spacing: 8) {
            ForEach(1...12, id: \.self) { n in
                HStack(spacing: 6) {
                    Text("\(n)").font(.lkMono(10, .bold)).foregroundStyle(Color.lkMuted)
                    Text("••••••").font(.lkMono(13, .bold)).foregroundStyle(Color.lkAccent).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(height: 40)
                .background(Color.lkCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.lkBorder, lineWidth: 1))
                .lkAppear(n - 1)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Пример: 12 скрытых слов восстановления")
    }
}
