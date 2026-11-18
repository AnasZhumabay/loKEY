import SwiftUI

/// Единые анимации приложения. Все уважают «Уменьшение движения».
enum LKMotion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.82)
    static let soft = Animation.easeOut(duration: 0.45)
}

/// Плавное появление списка: снизу вверх с задержкой по индексу.
private struct LKAppear: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .opacity(shown || reduce ? 1 : 0)
            .offset(y: shown || reduce ? 0 : 18)
            .scaleEffect(shown || reduce ? 1 : 0.97)
            .onAppear {
                guard !shown else { return }
                withAnimation(LKMotion.spring.delay(Double(min(index, 10)) * 0.055)) { shown = true }
            }
    }
}

/// Нажатие карточки: лёгкое «вдавливание» + haptic.
struct LKPressStyle: ButtonStyle {
    var scale: CGFloat = 0.965
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? 0.04 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: configuration.isPressed) { old, new in !old && new }
    }
}

/// Мерцающая полоса (скелетоны, «идёт проверка»).
private struct LKShimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content.overlay {
            if !reduce {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.6)
                }
                .allowsHitTesting(false)
                .mask(content)
            }
        }
        .onAppear {
            guard !reduce else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

/// Мягкая пульсация (индикатор «защита активна», статус).
private struct LKPulse: ViewModifier {
    var amount: CGFloat
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .scaleEffect(on && !reduce ? 1 + amount : 1)
            .opacity(on && !reduce ? 0.85 : 1)
            .onAppear {
                guard !reduce else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

extension View {
    func lkAppear(_ index: Int = 0) -> some View { modifier(LKAppear(index: index)) }
    func lkShimmer() -> some View { modifier(LKShimmer()) }
    func lkPulse(_ amount: CGFloat = 0.06) -> some View { modifier(LKPulse(amount: amount)) }
}

// MARK: - Лого с «рисованием» при запуске

struct AnimatedBrandMark: View {
    @State private var stem: CGFloat = 0
    @State private var ring: CGFloat = 0
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        GeometryReader { g in
            let s = g.size.width / 244
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 14 * s, y: 122 * s))
                    p.addLine(to: CGPoint(x: 142 * s, y: 14 * s))
                    p.addLine(to: CGPoint(x: 142 * s, y: 122 * s))
                }
                .trim(from: 0, to: stem)
                .stroke(Color.lkText, style: StrokeStyle(lineWidth: 26 * s, lineCap: .round, lineJoin: .round))
                Circle().trim(from: 0, to: ring)
                    .stroke(Color.lkAccent, style: StrokeStyle(lineWidth: 26 * s, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 60 * s, height: 60 * s)
                    .position(x: 198 * s, y: 92 * s)
                    .shadow(color: Color.lkAccent.opacity(glow ? 0.7 : 0), radius: glow ? 18 : 0)
            }
        }
        .aspectRatio(244.0 / 137.0, contentMode: .fit)
        .accessibilityLabel("loKEY")
        .onAppear {
            if reduce { stem = 1; ring = 1; return }
            withAnimation(.easeInOut(duration: 0.8)) { stem = 1 }
            withAnimation(.easeInOut(duration: 0.7).delay(0.6)) { ring = 1 }
            withAnimation(.easeOut(duration: 0.6).delay(1.2)) { glow = true }
        }
    }
}

// MARK: - Конфетти / вспышка

struct ConfettiBurst: View {
    @State private var go = false
    private let items: [(angle: Double, dist: CGFloat, size: CGFloat, color: Color)] = (0..<26).map { i in
        let cols: [Color] = [.lkAccent, .lkText, .lkWarn, .lkAccent.opacity(0.6)]
        return (Double(i) / 26 * 360 + Double((i * 37) % 13), CGFloat(90 + (i * 53) % 110), CGFloat(5 + (i * 7) % 6), cols[i % cols.count])
    }
    var body: some View {
        ZStack {
            ForEach(items.indices, id: \.self) { i in
                let it = items[i]
                RoundedRectangle(cornerRadius: 2).fill(it.color)
                    .frame(width: it.size, height: it.size * 1.6)
                    .rotationEffect(.degrees(go ? it.angle * 2 : 0))
                    .offset(x: go ? cos(it.angle * .pi / 180) * it.dist : 0,
                            y: go ? sin(it.angle * .pi / 180) * it.dist + 40 : 0)
                    .opacity(go ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { withAnimation(.easeOut(duration: 1.3)) { go = true } }
    }
}

// MARK: - Zoom-переход карточка → экран (iOS 18+, на 17 — обычный push)

private struct ZoomNSKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    var lkZoomNS: Namespace.ID? {
        get { self[ZoomNSKey.self] }
        set { self[ZoomNSKey.self] = newValue }
    }
}

private struct ZoomSource: ViewModifier {
    let id: AnyHashable
    @Environment(\.lkZoomNS) private var ns
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let ns { content.matchedTransitionSource(id: id, in: ns) } else { content }
    }
}
private struct ZoomTarget: ViewModifier {
    let id: AnyHashable
    @Environment(\.lkZoomNS) private var ns
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let ns { content.navigationTransition(.zoom(sourceID: id, in: ns)) } else { content }
    }
}
extension View {
    func lkZoomSource(_ id: AnyHashable) -> some View { modifier(ZoomSource(id: id)) }
    func lkZoomTarget(_ id: AnyHashable) -> some View { modifier(ZoomTarget(id: id)) }
}
