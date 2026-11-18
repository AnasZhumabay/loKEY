import SwiftUI

enum PDFSaveMode { case newVersion, copy }

/// Лист сохранения: выбор способа, прогресс, анимация успеха.
struct PDFSaveSheet: View {
    let perform: (PDFSaveMode, @escaping @Sendable (UploadProgress) -> Void) async throws -> Void
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode: PDFSaveMode = .newVersion
    @State private var phase: Phase = .choose
    @State private var progress = UploadProgress(stage: .encrypting, fraction: 0)
    @State private var errorText: String?
    @State private var checkScale: CGFloat = 0.3

    private enum Phase { case choose, working, done }

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(Color.lkTrack).frame(width: 40, height: 5).padding(.top, 8)
            switch phase {
            case .choose: chooser
            case .working: working
            case .done: done
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.lkBg.ignoresSafeArea())
        .foregroundStyle(Color.lkText)
        .preferredColorScheme(.dark)
        .presentationDetents([.height(phase == .choose ? 400 : 300)])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(phase != .choose)
        .animation(reduceMotion ? nil : LKMotion.spring, value: phase)
    }

    private var chooser: some View {
        VStack(spacing: 14) {
            Text("Сохранить документ").font(.lk(20, .heavy))
            option(.newVersion, icon: "clock.arrow.circlepath", title: "Сохранить как новую версию",
                   sub: "Заменит текущий файл, старая версия останется в истории")
            option(.copy, icon: "doc.on.doc", title: "Сохранить как копию",
                   sub: "Новый файл «… (подписан).pdf» рядом с оригиналом")
            if let errorText {
                Label(tr(errorText), systemImage: "exclamationmark.triangle.fill")
                    .font(.lk(13, .semibold)).foregroundStyle(Color.lkDanger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Сохранить") { start() }
                .buttonStyle(.lkPrimary)
            Button("Отмена") { dismiss() }
                .buttonStyle(LKPressStyle())
                .font(.lk(16, .bold)).foregroundStyle(Color.lkMuted)
                .frame(minHeight: 44)
        }
    }

    private func option(_ m: PDFSaveMode, icon: String, title: String, sub: String) -> some View {
        let on = mode == m
        return Button {
            Haptics.soft()
            withAnimation(reduceMotion ? nil : LKMotion.snappy) { mode = m }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(on ? Color.lkAccent : Color.lkMuted).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.lk(16, .bold))
                    Text(sub).font(.lk(13)).foregroundStyle(Color.lkMuted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(on ? Color.lkAccent : Color.lkTrack)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .lkCard(radius: 18, fill: on ? Color.lkRaised : Color.lkCard, stroke: on ? Color.lkAccent.opacity(0.6) : Color.lkBorderSoft)
        }
        .buttonStyle(LKPressStyle(scale: 0.98))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var working: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            ProgressView(value: min(max(overall, 0), 1)).tint(Color.lkAccent)
            Text(stageText).font(.lk(16, .bold))
            Text("Не закрывайте экран").font(.lk(13)).foregroundStyle(Color.lkMuted)
            Spacer()
        }
    }

    private var done: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 20)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72)).foregroundStyle(Color.lkAccent)
                .scaleEffect(checkScale)
            Text("Документ подписан").font(.lk(20, .heavy))
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var stageText: String {
        switch progress.stage {
        case .encrypting: return "Шифруем…"
        case .uploading: return "Загружаем…"
        case .verifying: return "Проверяем…"
        case .done: return "Готово"
        }
    }
    private var overall: Double {
        switch progress.stage {
        case .encrypting: return progress.fraction * 0.3
        case .uploading: return 0.3 + progress.fraction * 0.6
        case .verifying: return 0.9 + progress.fraction * 0.1
        case .done: return 1
        }
    }

    private func start() {
        errorText = nil
        phase = .working
        progress = UploadProgress(stage: .encrypting, fraction: 0)
        let m = mode
        Task {
            do {
                try await perform(m) { p in
                    Task { @MainActor in progress = p }
                }
                Haptics.success()
                phase = .done
                withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.55)) { checkScale = 1 }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                onFinished()
            } catch {
                Haptics.error()
                errorText = (error as? VaultError)?.message ?? "Не удалось сохранить. Попробуйте ещё раз"
                phase = .choose
            }
        }
    }
}
