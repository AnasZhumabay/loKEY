import SwiftUI

/// Блок «Хранилище»: занято / лимит, сегментная полоса по кейсам и легенда.
/// Переехал с главного экрана; встраивается в Настройки (`StorageUsageCard()`), данные берёт из `store.storage`.
struct StorageUsageCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var barIn = false

    private let palette: [Color] = [.lkAccent, .lkPurple, .lkWarn, .lkDanger, .lkText2]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let st = store.storage {
                HStack(alignment: .firstTextBaseline) {
                    (Text(LKFormat.bytes(st.usedBytes)).font(.lk(22, .heavy))
                     + Text(" ") + Text("из").font(.lk(14, .semibold)).foregroundColor(.lkMuted)
                     + Text(verbatim: " " + LKFormat.bytes(st.limitBytes)).font(.lk(14, .semibold)).foregroundColor(.lkMuted))
                        .tracking(-0.2).contentTransition(.numericText())
                    Spacer()
                    Text("\(Int((st.fraction * 100).rounded()))%").font(.lk(13, .bold)).foregroundStyle(Color.lkAccent)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.lkAccent.opacity(0.14), in: Capsule())
                }
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(Array(st.perCase.enumerated()), id: \.element.id) { i, c in
                            let w = st.limitBytes > 0 ? g.size.width * CGFloat(c.bytes) / CGFloat(st.limitBytes) : 0
                            if w > 0 { Rectangle().fill(palette[i % palette.count]).frame(width: max(w, 2)) }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: g.size.width, alignment: .leading)
                    .background(Color.lkRaised)
                    .clipShape(Capsule())
                    .scaleEffect(x: barIn ? 1 : 0.001, anchor: .leading)
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                    ForEach(Array(st.perCase.enumerated()), id: \.element.id) { i, c in
                        HStack(spacing: 6) {
                            Circle().fill(palette[i % palette.count]).frame(width: 8, height: 8)
                            Text(verbatim: "\(c.name) · \(LKFormat.bytes(c.bytes))").lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .font(.lk(12, .semibold)).foregroundStyle(Color.lkText2)
                    }
                }
            } else {
                HStack { ProgressView(); Text("Считаем место…").font(.lk(14, .medium)).foregroundStyle(Color.lkMuted) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if reduceMotion { barIn = true } else { withAnimation(.easeOut(duration: 0.9).delay(0.2)) { barIn = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.storage.map { tr("Занято") + " " + LKFormat.bytes($0.usedBytes) + " " + tr("из") + " " + LKFormat.bytes($0.limitBytes) } ?? tr("Считаем место…"))
    }
}
