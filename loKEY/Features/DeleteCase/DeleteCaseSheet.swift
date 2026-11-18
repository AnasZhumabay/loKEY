import SwiftUI

struct DeleteCaseSheet: View {
    let caseID: String
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var typed = ""
    @State private var progress: Double = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var isDeleting = false
    @State private var done = false
    @State private var snapshot: VaultCase?
    @FocusState private var focused: Bool

    private var vaultCase: VaultCase? { store.vaultCase(caseID) ?? snapshot }
    private var name: String { vaultCase?.name ?? "" }
    private var matches: Bool {
        !name.isEmpty && typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name.lowercased()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "trash").font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.lkDanger)
                        .frame(width: 56, height: 56)
                        .background(Color(hex: 0xFF7A6E, opacity: 0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(hex: 0xFF7A6E, opacity: 0.4), lineWidth: 1))
                    Text(verbatim: trf("Удалить кейс\n«%@»?", name))
                        .font(.lk(24, .heavy)).tracking(-0.7).lineSpacing(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.top, 14)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                warning

                VStack(alignment: .leading, spacing: 8) {
                    Text("Чтобы подтвердить, введите название кейса")
                        .font(.lk(13, .bold)).foregroundStyle(Color.lkText2)
                    TextField(name, text: $typed)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.lk(16, .semibold))
                        .tint(Color.lkDanger)
                        .padding(.horizontal, 16).frame(height: 54)
                        .background(Color.lkBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(focused ? Color.lkDanger : Color.white.opacity(0.1), lineWidth: 1))
                        .onChange(of: typed) { _, _ in cancelHold() }
                }

                VStack(spacing: 10) {
                    holdButton
                    Button { dismiss() } label: { Text("Отмена") }
                        .buttonStyle(.lkSecondary).disabled(isDeleting)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .foregroundStyle(Color.lkText)
        .preferredColorScheme(.dark)
        .onAppear { if snapshot == nil { snapshot = store.vaultCase(caseID) } }
        .onDisappear { cancelHold() }
    }

    private var warning: some View {
        let files = vaultCase?.fileCount ?? 0
        let size = LKFormat.bytes(vaultCase?.bytes ?? 0)
        return (Text("Будут стёрты ") + Text(verbatim: "\(files) \(tr(Self.pluralFiles(files))) · \(size)").bold().foregroundColor(.lkText)
                + Text(" и ключ кейса. Откатить это нельзя: даже если вы передумаете, мы не сможем ничего вернуть."))
            .font(.lk(14, .medium)).foregroundStyle(Color(hex: 0xA9B0B8)).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var holdButton: some View {
        let label: String = !matches ? "Введите название"
            : (done ? "Удалено" : (progress > 0 ? "Держите…" : "Удерживайте, чтобы удалить навсегда"))
        return ZStack {
            Capsule().fill(matches ? Color.lkDangerSolid : Color.lkTrack)
            GeometryReader { g in
                Rectangle().fill(Color.white.opacity(0.22)).frame(width: g.size.width * progress)
            }
            .clipShape(Capsule())
            HStack(spacing: 8) {
                if isDeleting { ProgressView().tint(.white) } else { Image(systemName: "trash").font(.system(size: 16, weight: .bold)) }
                Text(label).lineLimit(1).minimumScaleFactor(0.75)
            }
            .font(.lk(16, .heavy))
            .foregroundStyle(matches ? Color.white : Color(hex: 0x6E7681))
        }
        .frame(height: 56)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in beginHold() }
                .onEnded { _ in if !done { cancelHold() } }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Удалить кейс навсегда")
        .accessibilityValue(tr(matches ? "" : "Сначала введите название"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Нажмите и удерживайте")
        .accessibilityAction { if matches && !isDeleting { Task { await performDelete() } } }
    }

    private func beginHold() {
        guard matches, holdTask == nil, !isDeleting, !done else { return }
        focused = false
        withAnimation(.linear(duration: 1)) { progress = 1 }
        holdTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            Haptics.heavy()
            await performDelete()
        }
    }

    private func cancelHold() {
        guard !isDeleting else { return }
        holdTask?.cancel()
        holdTask = nil
        if progress > 0 { withAnimation(.easeOut(duration: 0.2)) { progress = 0 } }
    }

    private func performDelete() async {
        guard !isDeleting else { return }
        isDeleting = true
        do {
            try await store.repo.purgeCase(id: caseID)
            done = true
            await store.refreshCases()
            dismiss()
            router.popToRoot()
            store.showToast("Кейс удалён")
        } catch {
            store.showError(error)
            isDeleting = false
            holdTask = nil
            withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
        }
    }

    private static func pluralFiles(_ n: Int) -> String {
        let a = n % 100, b = n % 10
        if a >= 11 && a <= 14 { return "файлов" }
        switch b { case 1: return "файл"; case 2, 3, 4: return "файла"; default: return "файлов" }
    }
}
