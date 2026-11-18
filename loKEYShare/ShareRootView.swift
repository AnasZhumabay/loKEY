import SwiftUI

private extension Color {
    init(shareHex hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
    static let shBg = Color(shareHex: 0x0E1115)
    static let shCard = Color(shareHex: 0x161A20)
    static let shAccent = Color(shareHex: 0x3EC6BE)
    static let shText = Color(shareHex: 0xF2F2EE)
    static let shMuted = Color(shareHex: 0x8B939E)
    static let shDanger = Color(shareHex: 0xFF8A7E)
}

/// Знак loKEY, нарисованный фигурами (без ассетов).
private struct ShareMark: View {
    var body: some View {
        GeometryReader { g in
            let s = g.size.width / 244
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 14 * s, y: 122 * s))
                    p.addLine(to: CGPoint(x: 142 * s, y: 14 * s))
                    p.addLine(to: CGPoint(x: 142 * s, y: 122 * s))
                }
                .stroke(Color.shText, style: StrokeStyle(lineWidth: 26 * s, lineCap: .round, lineJoin: .round))
                Circle().stroke(Color.shAccent, lineWidth: 26 * s)
                    .frame(width: 60 * s, height: 60 * s)
                    .position(x: 198 * s, y: 92 * s)
            }
        }
        .aspectRatio(244.0 / 137.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct ShareCheck: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.26, y: r.minY + r.height * 0.52))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.69))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.75, y: r.minY + r.height * 0.33))
        return p
    }
}

private struct SuccessCheck: View {
    @State private var ring: CGFloat = 0
    @State private var tick: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        ZStack {
            Circle().fill(Color.shAccent.opacity(0.12))
            Circle().trim(from: 0, to: ring).stroke(Color.shAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            ShareCheck().trim(from: 0, to: tick).stroke(Color.shAccent, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 88, height: 88)
        .onAppear {
            if reduce { ring = 1; tick = 1; return }
            withAnimation(.easeOut(duration: 0.5)) { ring = 1 }
            withAnimation(.easeOut(duration: 0.35).delay(0.4)) { tick = 1 }
        }
        .accessibilityHidden(true)
    }
}

private struct ProgressRing: View {
    let value: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 6)
            Circle().trim(from: 0, to: max(0.03, value)).stroke(Color.shAccent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: value)
            Text("\(Int(value * 100))%").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Color.shText)
                .contentTransition(.numericText())
        }
        .frame(width: 88, height: 88)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Сохранение")
        .accessibilityValue("\(Int(value * 100)) процентов")
    }
}

struct ShareRootView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch model.phase {
                case .loading: centered { ProgressView().tint(Color.shAccent).scaleEffect(1.3); Text("Читаю файлы…").font(.callout).foregroundStyle(Color.shMuted) }
                case .ready: readyContent
                case .saving: centered { ProgressRing(value: model.progress); Text("Шифрую и сохраняю…").font(.headline).foregroundStyle(Color.shText) }
                case .done:
                    centered {
                        SuccessCheck()
                        Text("Готово. Откройте loKEY и выберите кейс.").font(.headline).foregroundStyle(Color.shText).multilineTextAlignment(.center)
                    }
                case .failed(let msg): failedContent(msg)
                }
            }
            .transition(.opacity)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.shBg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.phase)
    }

    private var header: some View {
        VStack(spacing: 10) {
            ShareMark().frame(width: 54)
            Text("Сохранить в loKEY").font(.system(size: 20, weight: .heavy)).foregroundStyle(Color.shText)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.bottom, 16)
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 16) { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }

    private var readyContent: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.entries) { row($0) }
                }
            }
            Text("Файлы зашифруются и попадут во «Входящие». В кейс их можно переместить в приложении.")
                .font(.footnote).foregroundStyle(Color.shMuted).multilineTextAlignment(.center)
            Button { model.save() } label: {
                Text("Сохранить во «Входящие»").font(.system(size: 17, weight: .heavy)).foregroundStyle(Color.shBg)
                    .frame(maxWidth: .infinity, minHeight: 54).background(model.readyEntries.isEmpty ? Color.shMuted.opacity(0.4) : Color.shAccent, in: Capsule())
            }
            .disabled(model.readyEntries.isEmpty)
            Button { model.cancel() } label: {
                Text("Отмена").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.shMuted)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private func row(_ e: ShareEntry) -> some View {
        HStack(spacing: 12) {
            Group {
                if let t = e.thumbnail {
                    Image(uiImage: t).resizable().scaledToFill()
                } else {
                    Image(systemName: icon(e.kind)).font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.shAccent)
                }
            }
            .frame(width: 46, height: 46)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(e.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.shText).lineLimit(1).truncationMode(.middle)
                if let p = e.problem {
                    Text(p).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.shDanger).lineLimit(2)
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(e.bytes), countStyle: .file))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.shMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.shCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "pdf": return "doc.richtext"
        case "jpg", "png", "heic": return "photo"
        case "video": return "video"
        case "note": return "note.text"
        default: return "doc"
        }
    }

    private func failedContent(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(Color.shDanger)
            Text("Не удалось сохранить").font(.headline).foregroundStyle(Color.shText)
            Text(msg).font(.callout).foregroundStyle(Color.shMuted).multilineTextAlignment(.center)
            Spacer()
            if !model.readyEntries.isEmpty {
                Button { model.backToList() } label: {
                    Text("Назад к списку").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.shText)
                        .frame(maxWidth: .infinity, minHeight: 50).overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                }
            }
            Button { model.cancel() } label: {
                Text("Закрыть").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.shMuted)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }
}
