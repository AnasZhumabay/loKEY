import SwiftUI

// MARK: - Знак loKEY (стержень ключа переходит в «l» и «o»)

struct BrandMark: View {
    var stem: Color = .lkText
    var ring: Color = .lkAccent
    var body: some View {
        GeometryReader { g in
            let s = g.size.width / 244
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 14 * s, y: 122 * s))
                    p.addLine(to: CGPoint(x: 142 * s, y: 14 * s))
                    p.addLine(to: CGPoint(x: 142 * s, y: 122 * s))
                }
                .stroke(stem, style: StrokeStyle(lineWidth: 26 * s, lineCap: .round, lineJoin: .round))
                Circle().stroke(ring, lineWidth: 26 * s)
                    .frame(width: 60 * s, height: 60 * s)
                    .position(x: 198 * s, y: 92 * s)
            }
        }
        .aspectRatio(244.0 / 137.0, contentMode: .fit)
        .accessibilityLabel("loKEY")
    }
}

/// Надпись «loKEY» с бирюзовым «lo»
struct BrandWordmark: View {
    var size: CGFloat = 22
    var body: some View {
        (Text("lo").foregroundColor(.lkAccent) + Text("KEY").foregroundColor(.lkText))
            .font(.lk(size, .heavy))
            .tracking(-size * 0.02)
    }
}

// MARK: - Фон экрана

struct GlowBackground: View {
    var color: Color = .lkAccent
    var strength: Double = 0.2
    var body: some View {
        ZStack {
            Color.lkBg
            GeometryReader { g in
                RadialGradient(colors: [color.opacity(strength), .clear],
                               center: .center, startRadius: 0, endRadius: 210)
                    .frame(width: 420, height: 420)
                    .position(x: g.size.width * 0.35, y: 40)
                RadialGradient(colors: [Color.lkPurple.opacity(strength * 0.4), .clear],
                               center: .center, startRadius: 0, endRadius: 170)
                    .frame(width: 340, height: 340)
                    .position(x: g.size.width * 1.1, y: g.size.height * 0.75)
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Стандартный экран loKEY: тёмный фон со свечением, скрытый системный navigation bar.
    func lkScreen(glow: Color = .lkAccent, strength: Double = 0.2) -> some View {
        self
            .background(GlowBackground(color: glow, strength: strength))
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .foregroundStyle(Color.lkText)
    }
    /// Карточка: фон, тонкая рамка, скругление
    func lkCard(radius: CGFloat = 24, fill: Color = .lkCard, stroke: Color = .lkBorderSoft) -> some View {
        self.background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(stroke, lineWidth: 1))
    }
}

// MARK: - Кнопки

struct LKPrimaryButtonStyle: ButtonStyle {
    var fill: Color = .lkAccent
    var fg: Color = .lkBg
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lk(17, .heavy))
            .foregroundStyle(enabled ? fg : Color.lkMuted)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(enabled ? fill : Color.lkRaised, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .medium), trigger: configuration.isPressed) { o, n in !o && n }
    }
}

struct LKSecondaryButtonStyle: ButtonStyle {
    var tint: Color = .lkText
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lk(16, .bold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 52)
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LKPrimaryButtonStyle {
    static var lkPrimary: LKPrimaryButtonStyle { .init() }
    static func lkPrimary(fill: Color, fg: Color = .lkBg) -> LKPrimaryButtonStyle { .init(fill: fill, fg: fg) }
}
extension ButtonStyle where Self == LKSecondaryButtonStyle {
    static var lkSecondary: LKSecondaryButtonStyle { .init() }
}

/// Круглая иконка-кнопка 44×44 (назад, поиск, аккаунт, меню…)
struct LKIconButton: View {
    let systemName: String
    let label: String
    var tint: Color = .lkText
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(Color.lkCard, in: Circle())
                .overlay(Circle().stroke(Color.lkBorder, lineWidth: 1))
        }
        .buttonStyle(LKPressStyle(scale: 0.88))
        .accessibilityLabel(tr(label))
    }
}

// MARK: - Чипы, теги, прогресс

struct LKChip: View {
    let title: String
    var count: Int? = nil
    var selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count { Text("\(count)").opacity(0.7) }
            }
            .font(.lk(13, selected ? .bold : .semibold))
            .foregroundStyle(selected ? Color.lkBg : Color.lkText2)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(selected ? Color.lkText : .clear, in: Capsule())
            .overlay(Capsule().stroke(selected ? .clear : Color.white.opacity(0.1), lineWidth: 1))
            .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct LevelTag: View {
    let level: SecurityLevel
    var suffix: String? = nil
    var body: some View {
        Text(level.title + (suffix.map { " · \($0)" } ?? ""))
            .font(.lk(10, .heavy)).tracking(1)
            .foregroundStyle(level.tint)
    }
}

/// Кольцо обратного отсчёта автоблокировки: «тает», в последние 30 с — оранжевое и мигает.
struct AutoLockPill: View {
    let secondsLeft: Int?
    var total: Int = 900
    var body: some View {
        let warn = (secondsLeft ?? 99) <= 30
        let color: Color = secondsLeft == nil ? .lkMuted : (warn ? .lkWarn : .lkAccent)
        let progress = secondsLeft.map { 1 - Double($0) / Double(max(total, 1)) } ?? 0
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 3)
                Circle().trim(from: 0, to: 1 - progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            Text(secondsLeft.map(LKFormat.clock) ?? "закрыто")
                .font(.lkMono(12, .semibold))
                .contentTransition(.numericText(countsDown: true))
        }
        .foregroundStyle(color)
        .animation(.easeOut(duration: 0.3), value: secondsLeft)
        .padding(.leading, 6).padding(.trailing, 11).frame(height: 30)
        .background(Color.lkBg, in: Capsule())
        .phaseAnimator(warn ? [1.0, 0.45] : [1.0]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(secondsLeft.map { trf("До автоблокировки %@", LKFormat.clock($0)) } ?? tr("Кейсы закрыты"))
    }
}

// MARK: - Поля ввода

struct LKField<Content: View>: View {
    let title: String
    var error: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.lk(13, .bold)).foregroundStyle(Color.lkText2)
            content
                .font(.lk(16, .medium))
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .background(error == nil ? Color.lkCard : Color.lkDanger.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(error == nil ? Color.white.opacity(0.1) : Color.lkDanger, lineWidth: error == nil ? 1 : 1.5))
            if let error {
                Label(tr(error), systemImage: "exclamationmark.circle")
                    .font(.lk(13, .semibold)).foregroundStyle(Color.lkDanger)
            }
        }
    }
}

// MARK: - Тост

struct ToastView: View {
    let text: String
    let isError: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.lkDanger : Color.lkAccent)
            Text(text).font(.lk(14, .semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.lkBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
    }
}

/// Тонкая «шапка» экрана с кнопкой назад
struct LKTopBar<Trailing: View>: View {
    @Environment(\.dismiss) private var dismiss
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            LKIconButton(systemName: "chevron.left", label: "Назад") { dismiss() }
            Spacer()
            if let title {
                VStack(spacing: 1) {
                    Text(title).font(.lk(16, .heavy)).lineLimit(1).minimumScaleFactor(0.7)
                    if let subtitle { Text(subtitle).font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted) }
                }
            }
            Spacer()
            trailing.frame(minWidth: 44)
        }
        .frame(height: 44)
    }
}
extension LKTopBar where Trailing == EmptyView {
    init(title: String? = nil, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}
