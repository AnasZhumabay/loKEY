import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

// MARK: - Палитра и знак (виджет не видит DesignSystem приложения)

private extension Color {
    init(w hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
    static let wBg = Color(w: 0x0E1115)
    static let wCard = Color(w: 0x161A20)
    static let wCard2 = Color(w: 0x1C2128)
    static let wTrack = Color(w: 0x20252D)
    static let wAccent = Color(w: 0x3EC6BE)
    static let wText = Color(w: 0xF2F2EE)
    static let wMuted = Color(w: 0x8B939E)
    static let wWarn = Color(w: 0xF2A65A)
    static let wPurple = Color(w: 0xC7B4FF)
    static func wLevel(_ raw: String) -> Color {
        switch raw { case "critical": return .wWarn; case "sensitive": return .wPurple; default: return .wMuted }
    }
}

private struct WBrandMark: View {
    var stem: Color = .wText
    var ring: Color = .wAccent
    var body: some View {
        GeometryReader { g in
            let s = g.size.width / 244
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 14 * s, y: 122 * s))
                    p.addLine(to: CGPoint(x: 142 * s, y: 14 * s))
                    p.addLine(to: CGPoint(x: 142 * s, y: 122 * s))
                }
                .stroke(stem, style: StrokeStyle(lineWidth: 28 * s, lineCap: .round, lineJoin: .round))
                Circle().stroke(ring, lineWidth: 28 * s).frame(width: 60 * s, height: 60 * s)
                    .position(x: 198 * s, y: 92 * s)
            }
        }
        .aspectRatio(244.0 / 137.0, contentMode: .fit)
    }
}

private func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let a = n % 100, b = n % 10
    if a >= 11 && a <= 14 { return many }
    switch b { case 1: return one; case 2, 3, 4: return few; default: return many }
}

private func bytesText(_ n: Int64) -> String {
    let f = ByteCountFormatter(); f.allowedUnits = [.useKB, .useMB, .useGB]; f.countStyle = .file
    return f.string(fromByteCount: n)
}

// MARK: - Провайдер

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snap: WidgetSnapshot(
            openCount: 2, total: 4,
            items: [.init(name: "Документы", level: "critical", isOpen: true), .init(name: "Финансы", level: "sensitive", isOpen: false)],
            usedBytes: 312_000_000, hideNames: false, secondsLeft: 768, updatedAt: .now))
    }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : SnapshotEntry(date: .now, snap: .load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let e = SnapshotEntry(date: .now, snap: .load())
        completion(Timeline(entries: [e], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

// MARK: - Малый: «2 / 4 кейса открыты»

struct OpenCountWidgetView: View {
    let snap: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                WBrandMark().frame(width: 30)
                Spacer()
                Circle().fill(snap.openCount > 0 ? Color.wAccent : Color.wMuted).frame(width: 8, height: 8)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                (Text("\(snap.openCount)").font(.system(size: 44, weight: .heavy)).tracking(-2)
                 + Text(" / \(snap.total)").font(.system(size: 16, weight: .semibold)).foregroundColor(.wMuted))
                    .foregroundStyle(Color.wText)
                Text(snap.openCount == 0 ? "кейсов открыто" : plural(snap.openCount, "кейс открыт", "кейса открыты", "кейсов открыто"))
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.wAccent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(Color.wCard, for: .widget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Открыто кейсов \(snap.openCount) из \(snap.total)")
    }
}

struct OpenCountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "loKEY.openCount", provider: SnapshotProvider()) { e in OpenCountWidgetView(snap: e.snap) }
            .configurationDisplayName("Открытые кейсы")
            .description("Сколько кейсов сейчас открыто.")
            .supportedFamilies([.systemSmall])
    }
}

// MARK: - Малый: «Закрыть все» (только вид, без действия)

struct LockAllWidgetView: View {
    var body: some View {
        VStack(alignment: .leading) {
            Image(systemName: "lock").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.wAccent)
                .frame(width: 40, height: 40).background(Color.wBg, in: Circle())
            Spacer()
            VStack(alignment: .leading, spacing: 3) {
                Text("Закрыть все").font(.system(size: 20, weight: .heavy)).tracking(-0.6).lineLimit(2).minimumScaleFactor(0.8)
                Text("одним касанием").font(.system(size: 12, weight: .bold)).opacity(0.7)
            }
        }
        .foregroundStyle(Color.wBg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(Color.wAccent, for: .widget)
    }
}

struct LockAllWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "loKEY.lockAll", provider: SnapshotProvider()) { _ in LockAllWidgetView() }
            .configurationDisplayName("Закрыть все")
            .description("Быстрый доступ к loKEY.")
            .supportedFamilies([.systemSmall])
    }
}

// MARK: - Средний: кейсы

struct CasesWidgetView: View {
    let snap: WidgetSnapshot
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                (Text("lo").foregroundColor(.wAccent) + Text("KEY · кейсы").foregroundColor(.wText))
                    .font(.system(size: 13, weight: .heavy))
                Spacer()
                Text("\(bytesText(snap.usedBytes)) / 1 ГБ")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Color.wMuted)
            }
            if snap.items.isEmpty {
                Text("Кейсов пока нет").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.wMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Открытые кейсы показываем первыми
                let sorted = snap.items.sorted { $0.isOpen && !$1.isOpen }
                HStack(spacing: 8) {
                    ForEach(Array(sorted.prefix(2).enumerated()), id: \.offset) { _, it in tile(it) }
                    if sorted.count < 2 { Color.clear }
                }
            }
        }
        .containerBackground(Color.wCard, for: .widget)
    }

    private func tile(_ it: WidgetSnapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(it.name ?? "Кейс").font(.system(size: 13, weight: .heavy)).lineLimit(1)
            if it.isOpen, let left = snap.secondsLeft {
                let end = snap.updatedAt.addingTimeInterval(TimeInterval(left))
                if end > .now {
                    (Text("открыт · ") + Text(timerInterval: Date.now...end, countsDown: true))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.wAccent).monospacedDigit()
                } else {
                    Text("закрыт").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.wMuted)
                }
            } else {
                Text(it.isOpen ? "открыт" : "закрыт").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(it.isOpen ? Color.wAccent : Color.wMuted)
            }
        }
        .foregroundStyle(Color.wText)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.wCard2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.wLevel(it.level)).frame(height: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CasesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "loKEY.cases", provider: SnapshotProvider()) { e in CasesWidgetView(snap: e.snap) }
            .configurationDisplayName("Кейсы")
            .description("Названия и состояние кейсов. Без файлов и превью.")
            .supportedFamilies([.systemMedium])
    }
}

// MARK: - Live Activity

struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LoKEYTimerAttributes.self) { ctx in
            // Экран блокировки
            VStack(spacing: 10) {
                header(ctx.state)
                bar(ctx.state)
            }
            .padding(16)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(Color.wAccent)
        } dynamicIsland: { ctx in
            let tint: Color = ctx.state.isWarning ? .wWarn : .wAccent
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "key.horizontal").foregroundStyle(tint)
                        .frame(width: 36, height: 36).background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(ctx.state)).font(.system(size: 15, weight: .heavy)).lineLimit(1)
                        Text("Закроется автоматически").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.wMuted)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    clock(ctx.state, size: 24).frame(width: 70, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) { bar(ctx.state) }
            } compactLeading: {
                WBrandMark(ring: tint).frame(width: 26)
            } compactTrailing: {
                clock(ctx.state, size: 13).frame(width: 46)
            } minimal: {
                WBrandMark(ring: tint).frame(width: 20)
            }
        }
    }

    private func title(_ s: LoKEYTimerAttributes.ContentState) -> String {
        s.title.isEmpty ? "Открыто: \(s.openCount)" : (s.openCount == 1 ? "Кейс «\(s.title)» открыт" : "Открыто: \(s.title)")
    }

    private func clock(_ s: LoKEYTimerAttributes.ContentState, size: CGFloat) -> some View {
        Group {
            if s.endsAt > .now {
                Text(timerInterval: Date.now...s.endsAt, countsDown: true, showsHours: false)
            } else { Text("0:00") }
        }
        .font(.system(size: size, weight: .bold, design: .monospaced)).monospacedDigit()
        .foregroundStyle(s.isWarning ? Color.wWarn : Color.wAccent).multilineTextAlignment(.trailing)
    }

    private func header(_ s: LoKEYTimerAttributes.ContentState) -> some View {
        HStack(spacing: 10) {
            WBrandMark().frame(width: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(s)).font(.system(size: 15, weight: .heavy)).foregroundStyle(Color.wText).lineLimit(1)
                Text("Закроется автоматически").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.wMuted)
            }
            Spacer()
            clock(s, size: 24)
        }
    }

    private func bar(_ s: LoKEYTimerAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            Group {
                if s.endsAt > .now {
                    ProgressView(timerInterval: s.endsAt.addingTimeInterval(-TimeInterval(s.totalSeconds))...s.endsAt,
                                 countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                } else { ProgressView(value: 0) }
            }
            .progressViewStyle(.linear).tint(s.isWarning ? Color.wWarn : Color.wAccent)
            Button(intent: LockAllIntent()) {
                Label("Закрыть все", systemImage: "lock.fill").font(.system(size: 13, weight: .heavy)).foregroundStyle(Color.wBg)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(s.isWarning ? Color.wWarn : Color.wAccent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Bundle

@main
struct LoKEYWidgetsBundle: WidgetBundle {
    var body: some Widget {
        OpenCountWidget()
        LockAllWidget()
        CasesWidget()
        TimerLiveActivity()
    }
}
