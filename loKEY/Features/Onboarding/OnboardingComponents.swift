import SwiftUI

/// Общий каркас страницы: иллюстрация, заголовок, текст и дополнительный блок. Прокручивается при крупном шрифте.
struct OnbPageLayout<Art: View, Extra: View>: View {
    let page: OnboardingPage
    let title: String
    let text: String
    var artHeight: CGFloat = 250
    @ViewBuilder var art: () -> Art
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                art()
                    .frame(maxWidth: .infinity)
                    .frame(height: artHeight)
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr(title))
                        .font(.lk(30, .heavy)).tracking(-1)
                        .minimumScaleFactor(0.75)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(tr(text))
                        .font(.lk(16, .medium)).foregroundStyle(Color.lkText2).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    extra()
                }
                .padding(.top, 14).padding(.horizontal, 24).padding(.bottom, 36)
            }
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Color.lkBg.opacity(0), Color.lkBg.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                .frame(height: 22).allowsHitTesting(false).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboardingPage-\(page.number)")
    }
}

extension OnbPageLayout where Extra == EmptyView {
    init(page: OnboardingPage, title: String, text: String, artHeight: CGFloat = 250, @ViewBuilder art: @escaping () -> Art) {
        self.init(page: page, title: title, text: text, artHeight: artHeight, art: art, extra: { EmptyView() })
    }
}

/// Строка «иконка + заголовок + пояснение».
struct OnbRow: View {
    let icon: String
    let title: String
    var text: String? = nil
    var tint: Color = .lkAccent
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold)).foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(title)).font(.lk(15, .bold)).foregroundStyle(Color.lkText)
                if let text { Text(tr(text)).font(.lk(13, .medium)).foregroundStyle(Color.lkMuted).lineSpacing(2) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Карточка-контейнер.
struct OnbCard<Content: View>: View {
    var stroke: Color = .lkBorderSoft
    var fill: Color = .lkCard
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(stroke, lineWidth: 1))
    }
}

/// Концентрические кольца за иллюстрацией; «дышат», если разрешено движение.
struct OnbRings: View {
    var pulse = true
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.06), lineWidth: 1).frame(width: 236, height: 236)
                .scaleEffect(on ? 1.04 : 1)
            Circle().stroke(Color.white.opacity(0.09), lineWidth: 1).frame(width: 178, height: 178)
            Circle().fill(Color.lkAccent.opacity(0.06)).frame(width: 124, height: 124)
            Circle().stroke(Color.lkAccent.opacity(on ? 0.5 : 0.3), lineWidth: 1).frame(width: 124, height: 124)
        }
        .onAppear {
            guard pulse, !reduce else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { on = true }
        }
        .accessibilityHidden(true)
    }
}

struct OnbChip: View {
    let text: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.lkAccent) }
            Text(tr(text)).font(.lk(11, .bold)).tracking(0.4)
        }
        .foregroundStyle(Color.lkText2)
        .padding(.horizontal, 10).frame(minHeight: 28)
        .background(Color.lkCard, in: Capsule())
        .overlay(Capsule().stroke(Color.lkBorder, lineWidth: 1))
    }
}
