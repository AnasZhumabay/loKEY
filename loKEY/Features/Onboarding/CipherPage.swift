import SwiftUI

struct CipherPage: View {
    var body: some View {
        OnbPageLayout(page: .cipher, title: "Шифруется\nна телефоне",
                      text: "Каждый файл закрывается AES-256-GCM прямо на устройстве. Сервер видит только набор байтов — без ключа это просто шум.",
                      artHeight: 290,
                      art: {
            ZStack {
                OnbRings(pulse: false)
                CipherDemo()
            }
        }, extra: {
            OnbRow(icon: "eye.slash.fill", title: "Сервер видит только шифртекст",
                   text: "Но не скрыто, кто с кем переписывается и когда: эти метаданные сервер видит.")
                .padding(.top, 6)
        })
    }
}

/// Интерактивный пример: нажмите «Зашифровать» и увидите, что получает сервер. Данные вымышленные.
struct CipherDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 0      // 0 — открытый текст, 1 — шифр
    @State private var running = false
    private let lines = ["Паспорт · скан.pdf", "Иван Иванов", "Серия 0000 № 000000"]
    private let glyphs = Array("0123456789ABCDEF#%&@")

    private func shown(_ s: String, seed: Int) -> String {
        let n = s.count
        let k = Int(progress * Double(n))
        var rng = SplitMix(seed: UInt64(seed) &* 7919 &+ UInt64(progress * 20))
        return String(s.enumerated().map { i, c in
            if c == " " { return c }
            return i < k ? glyphs[Int(rng.next() % UInt64(glyphs.count))] : c
        })
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: progress >= 1 ? "lock.fill" : "doc.text.fill")
                        .foregroundStyle(progress >= 1 ? Color.lkAccent : Color.lkText2)
                        .contentTransition(.symbolEffect(.replace))
                    Text(progress >= 1 ? "Так видит сервер" : "Так видите вы")
                        .font(.lk(11, .heavy)).tracking(0.6).foregroundStyle(Color.lkMuted)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                    Text(shown(l, seed: i + 1))
                        .font(progress > 0 ? .lkMono(i == 0 ? 15 : 13, .semibold) : .lk(i == 0 ? 15 : 13, i == 0 ? .bold : .medium))
                        .foregroundStyle(progress > 0 ? Color.lkAccent : (i == 0 ? Color.lkText : Color.lkText2))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .padding(14).frame(width: 240, alignment: .leading)
            .background(Color.lkCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(progress >= 1 ? Color.lkAccent.opacity(0.6) : Color.lkBorder, lineWidth: 1))
            .shadow(color: Color.lkAccent.opacity(progress >= 1 ? 0.3 : 0), radius: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(progress >= 1 ? tr("Так видит сервер: набор байтов") : tr("Так видите вы: пример документа"))

            Button { run() } label: {
                Label(tr(progress >= 1 ? "Расшифровать" : "Зашифровать"), systemImage: progress >= 1 ? "lock.open.fill" : "lock.fill")
                    .font(.lk(14, .heavy)).foregroundStyle(Color.lkBg)
                    .padding(.horizontal, 18).frame(minHeight: 44).background(Color.lkAccent, in: Capsule())
            }
            .buttonStyle(LKPressStyle(scale: 0.92)).disabled(running)
            .accessibilityIdentifier("onboardingCipherButton")
        }
    }

    private func run() {
        guard !running else { return }
        let target: Double = progress >= 1 ? 0 : 1
        if reduceMotion { progress = target; Haptics.soft(); return }
        running = true; Haptics.soft()
        Task {
            let steps = 18
            for i in 1...steps {
                try? await Task.sleep(for: .milliseconds(40))
                progress = target == 1 ? Double(i) / Double(steps) : 1 - Double(i) / Double(steps)
            }
            progress = target; running = false; Haptics.success()
        }
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
