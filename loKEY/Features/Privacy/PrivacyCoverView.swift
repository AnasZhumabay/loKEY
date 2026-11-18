import SwiftUI

/// Заслонка, пока приложение неактивно / в фоне: скрывает содержимое в переключателе приложений.
struct PrivacyCoverView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        ZStack {
            Color(hex: 0x0A0D10)
            RadialGradient(colors: [Color.lkAccent.opacity(0.14), .clear],
                           center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 460)
            ghost
            Color(hex: 0x0A0D10).opacity(0.55)

            VStack(spacing: 22) {
                ZStack {
                    Circle().stroke(Color.lkAccent.opacity(0.4), lineWidth: 1)
                        .scaleEffect(breathe ? 1.06 : 1)
                        .opacity(breathe ? 1 : 0.5)
                    Circle().stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .padding(24)
                    RoundedRectangle(cornerRadius: 36, style: .continuous).fill(Color.lkAccent)
                        .frame(width: 112, height: 112)
                        .overlay(BrandMark(stem: .lkBg, ring: .lkBg).frame(width: 68))
                }
                .frame(width: 200, height: 200)

                VStack(spacing: 6) {
                    BrandWordmark(size: 26)
                    Label("Содержимое скрыто", systemImage: "lock")
                        .font(.lk(13, .bold)).foregroundStyle(Color(hex: 0xA9B0B8))
                }
            }
            VStack {
                Spacer()
                Text("ЭКРАН СКРЫТ В ПЕРЕКЛЮЧАТЕЛЕ ПРИЛОЖЕНИЙ")
                    .font(.lkMono(11)).tracking(0.9).foregroundStyle(Color.lkMuted)
                    .multilineTextAlignment(.center).padding(.horizontal, 16).padding(.bottom, 40)
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(Color.lkText)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Содержимое скрыто")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    private var ghost: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.lkAccent).frame(height: 170)
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.lkCard2).frame(height: 76)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.lkCard2).frame(height: 156)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 70)
        .blur(radius: 22).opacity(0.55)
    }
}
