import SwiftUI

/// Лист подписи: рисование пальцем + выбор из сохранённых.
/// Контракт: `onPick` вызывается с изображением подписи на ПРОЗРАЧНОМ фоне (PNG, обрезано по контуру).
struct SignatureSheet: View {
    let onPick: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Stroke { var points: [CGPoint]; var color: UIColor }
    private static let lineWidth: CGFloat = 3.4
    private static let inks: [(UIColor, String)] = [
        (UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1), "Чёрные чернила"),
        (UIColor(red: 0.05, green: 0.22, blue: 0.80, alpha: 1), "Синие чернила")
    ]

    @State private var strokes: [Stroke] = []
    @State private var current: Stroke?
    @State private var inkIndex = 0
    @State private var remember = true
    @State private var saved: [SavedSignature] = []
    @State private var pendingDelete: SavedSignature?

    private var hasInk: Bool { !strokes.isEmpty || current != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pad
                    controls
                    Toggle(isOn: $remember) {
                        Text("Запомнить подпись").font(.lk(15, .semibold))
                    }
                    .tint(Color.lkAccent)
                    .frame(minHeight: 44)
                    savedSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            Button(action: use) { Text("Использовать") }
                .buttonStyle(.lkPrimary)
                .disabled(!hasInk)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .background(Color.lkBg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .foregroundStyle(Color.lkText)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { saved = SignatureStore.shared.all() }
        .confirmationDialog("Удалить сохранённую подпись?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let p = pendingDelete {
                    SignatureStore.shared.delete(id: p.id)
                    Haptics.warning()
                    withAnimation(reduceMotion ? nil : LKMotion.snappy) { saved = SignatureStore.shared.all() }
                }
                pendingDelete = nil
            }
            Button("Отмена", role: .cancel) { pendingDelete = nil }
        }
    }

    // MARK: Части

    private var header: some View {
        HStack {
            Text("Подпись").font(.lk(20, .heavy))
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Color.lkCard, in: Circle())
            }
            .buttonStyle(LKPressStyle(scale: 0.9))
            .accessibilityLabel("Закрыть")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var pad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(white: 0.97))
            Canvas { ctx, size in
                // линия подписи
                var line = Path()
                line.move(to: CGPoint(x: 24, y: size.height - 52))
                line.addLine(to: CGPoint(x: size.width - 24, y: size.height - 52))
                ctx.stroke(line, with: .color(Color.black.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                let all = strokes + (current.map { [$0] } ?? [])
                for s in all {
                    ctx.stroke(Path(SignaturePath.path(for: s.points)), with: .color(Color(uiColor: s.color)),
                               style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
            if !hasInk {
                VStack(spacing: 6) {
                    Image(systemName: "signature").font(.system(size: 26, weight: .regular))
                    Text("Распишитесь здесь").font(.lk(15, .semibold))
                }
                .foregroundStyle(Color.black.opacity(0.3))
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .frame(height: 240)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if current == nil {
                        current = Stroke(points: [v.location], color: Self.inks[inkIndex].0)
                    } else if let last = current?.points.last, hypot(last.x - v.location.x, last.y - v.location.y) > 1.5 {
                        current?.points.append(v.location)
                    }
                }
                .onEnded { _ in
                    if let c = current { strokes.append(c) }
                    current = nil
                }
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hasInk)
        .accessibilityLabel("Поле для подписи")
        .accessibilityHint("Проведите пальцем, чтобы расписаться")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            ForEach(Self.inks.indices, id: \.self) { i in
                Button {
                    Haptics.soft()
                    inkIndex = i
                } label: {
                    Circle().fill(Color(uiColor: Self.inks[i].0))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().stroke(inkIndex == i ? Color.lkAccent : .clear, lineWidth: 2))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr(Self.inks[i].1))
                .accessibilityAddTraits(inkIndex == i ? .isSelected : [])
            }
            Spacer()
            Button {
                guard !strokes.isEmpty else { return }
                Haptics.soft()
                strokes.removeLast()
            } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(LKPressStyle(scale: 0.88))
            .disabled(strokes.isEmpty)
            .opacity(strokes.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Отменить штрих")
            Button {
                Haptics.warning()
                withAnimation(reduceMotion ? nil : LKMotion.snappy) { strokes = []; current = nil }
            } label: {
                Text("Очистить").font(.lk(15, .semibold)).foregroundStyle(Color.lkDanger)
                    .padding(.horizontal, 8).frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(!hasInk)
            .opacity(hasInk ? 1 : 0.4)
        }
    }

    @ViewBuilder private var savedSection: some View {
        if !saved.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: trf("Сохранённые · %lld/%lld", saved.count, SignatureStore.maxCount))
                    .font(.lk(13, .bold)).foregroundStyle(Color.lkMuted)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(saved) { s in
                            Button {
                                Haptics.soft()
                                onPick(s.image)
                                dismiss()
                            } label: {
                                Image(uiImage: s.image)
                                    .resizable().scaledToFit()
                                    .padding(10)
                                    .frame(width: 130, height: 74)
                                    .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(LKPressStyle(scale: 0.95))
                            .contextMenu {
                                Button("Удалить", systemImage: "trash", role: .destructive) { pendingDelete = s }
                            }
                            .accessibilityLabel("Сохранённая подпись")
                            .accessibilityHint("Нажмите, чтобы использовать")
                            .accessibilityAction(named: "Удалить") { pendingDelete = s }
                        }
                    }
                }
                Text("Нажмите, чтобы выбрать. Удерживайте, чтобы удалить.")
                    .font(.lk(12)).foregroundStyle(Color.lkMuted)
            }
        }
    }

    // MARK: Действия

    private func use() {
        let all = strokes + (current.map { [$0] } ?? [])
        guard let img = SignaturePath.render(strokes: all.map { ($0.points, $0.color) }, lineWidth: Self.lineWidth) else { return }
        Haptics.success()
        if remember { SignatureStore.shared.add(img) }
        onPick(img)
        dismiss()
    }
}

enum SignaturePath {
    /// Сглаженная кривая через середины отрезков (квадратичные Безье).
    static func path(for pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        guard pts.count > 2 else { p.addLine(to: pts.last ?? first); return p }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i])
        }
        if let last = pts.last { p.addLine(to: last) }
        return p
    }

    /// Прозрачный PNG-образ, обрезанный по контуру.
    static func render(strokes: [([CGPoint], UIColor)], lineWidth: CGFloat) -> UIImage? {
        let paths = strokes.map { (path(for: $0.0), $0.1) }
        var bounds = CGRect.null
        for (p, _) in paths { bounds = bounds.union(p.boundingBox) }
        guard !bounds.isNull else { return nil }
        let pad = lineWidth / 2 + 4
        let rect = bounds.insetBy(dx: -pad, dy: -pad)
        let f = UIGraphicsImageRendererFormat()
        f.scale = 3
        f.opaque = false
        return UIGraphicsImageRenderer(size: rect.size, format: f).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: -rect.minX, y: -rect.minY)
            c.setLineWidth(lineWidth)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            for (p, color) in paths {
                c.setStrokeColor(color.cgColor)
                c.addPath(p)
                c.strokePath()
            }
        }
    }
}
