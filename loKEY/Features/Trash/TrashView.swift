import SwiftUI

/// Корзина: файлы хранятся 30 дней, затем удаляются автоматически.
struct TrashView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    @State private var files: [VaultFile] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var confirmPurge: VaultFile?
    @State private var confirmClear = false

    private static let retentionDays = 30

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                LKIconButton(systemName: "chevron.left", label: "Назад") { router.pop() }
                Spacer()
                Text("Корзина").font(.lk(17, .heavy))
                Spacer()
                if !files.isEmpty {
                    Button("Очистить") { confirmClear = true }
                        .font(.lk(15, .bold)).foregroundStyle(Color.lkDanger)
                        .frame(minWidth: 44, minHeight: 44)
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8)

            content
        }
        .lkScreen()
        .task { await load() }
        .confirmationDialog("Удалить навсегда?", isPresented: Binding(get: { confirmPurge != nil }, set: { if !$0 { confirmPurge = nil } }),
                            titleVisibility: .visible, presenting: confirmPurge) { f in
            Button("Удалить навсегда", role: .destructive) { purge(f) }
            Button("Отмена", role: .cancel) {}
        } message: { f in
            Text(verbatim: trf("«%@» нельзя будет восстановить.", f.name))
        }
        .confirmationDialog("Очистить корзину?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Удалить всё навсегда", role: .destructive) { clearAll() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(verbatim: trf("Все файлы в корзине (%lld) будут удалены без возможности восстановления.", files.count))
        }
    }

    @ViewBuilder private var content: some View {
        if loading && files.isEmpty {
            LKSkeletonRows(count: 4); Spacer()
        } else if let loadError, files.isEmpty {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(Color.lkWarn)
                Text(loadError).font(.lk(15, .medium)).foregroundStyle(Color.lkText2).multilineTextAlignment(.center)
                Button("Повторить") { Task { await load() } }.buttonStyle(.lkSecondary).frame(maxWidth: 200)
            }.padding(24)
            Spacer()
        } else if files.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "trash").font(.system(size: 40, weight: .light)).foregroundStyle(Color.lkMuted)
                Text("Корзина пуста").font(.lk(20, .heavy))
                Text(verbatim: trf("Удалённые файлы хранятся здесь %lld дней.", Self.retentionDays))
                    .font(.lk(14, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center)
            }.padding(24)
            Spacer()
        } else {
            List {
                Section {
                    ForEach(files) { f in row(f) }
                } footer: {
                    Text(verbatim: trf("Файлы удаляются из корзины автоматически через %lld дней.", Self.retentionDays))
                        .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted).padding(.top, 8)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .refreshable { await load() }
        }
    }

    private func daysLeft(_ f: VaultFile) -> Int {
        guard let d = f.deletedAt else { return Self.retentionDays }
        let end = d.addingTimeInterval(Double(Self.retentionDays) * 86400)
        return max(0, Int(ceil(end.timeIntervalSinceNow / 86400)))
    }

    private func row(_ f: VaultFile) -> some View {
        let caseName = store.vaultCase(f.caseID)?.name
        return HStack(spacing: 12) {
            Text(f.kind.label).font(.lkMono(10, .bold)).foregroundStyle(f.kind.tint)
                .frame(width: 44, height: 44)
                .background(Color.lkRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(f.name).font(.lk(16, .bold)).lineLimit(1)
                Text([caseName, f.deletedAt.map { trf("удалён %@", Self.dateFormatter.string(from: $0)) }, LKFormat.bytes(f.bytes)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).lineLimit(1)
                Text(verbatim: trf("Удалится через %lld дн.", daysLeft(f))).font(.lk(12, .semibold)).foregroundStyle(Color.lkWarn)
            }
            Spacer(minLength: 4)
            Button { restore(f) } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.lkAccent).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).accessibilityLabel("Восстановить")
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear).listRowSeparatorTint(Color.lkBorder)
        .swipeActions(edge: .leading) {
            Button { restore(f) } label: { Label("Восстановить", systemImage: "arrow.uturn.backward") }.tint(Color.lkAccentDim)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { confirmPurge = f } label: { Label("Удалить навсегда", systemImage: "trash") }
        }
        .contextMenu {
            Button { restore(f) } label: { Label("Восстановить", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { confirmPurge = f } label: { Label("Удалить навсегда", systemImage: "trash") }
        }
    }

    private static var dateFormatter: DateFormatter {
        let d = DateFormatter(); d.locale = LKBundle.uiLocale; d.dateFormat = "d MMM"; return d
    }

    // MARK: Actions

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            files = try await store.repo.listTrash().sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
            loadError = nil
        } catch {
            loadError = (error as? VaultError)?.message ?? "Не удалось загрузить корзину"
        }
    }

    private func restore(_ f: VaultFile) {
        Task {
            do {
                try await store.repo.restoreFile(id: f.id)
                await store.refreshCases()
                await load()
                store.showToast("Файл восстановлен")
            } catch { store.showError(error) }
        }
    }

    private func purge(_ f: VaultFile) {
        Task {
            do {
                try await store.repo.purgeFile(id: f.id)
                await store.refreshCases()
                await load()
            } catch { store.showError(error) }
        }
    }

    private func clearAll() {
        let all = files
        Task {
            var failed = false
            for f in all {
                do { try await store.repo.purgeFile(id: f.id) } catch { failed = true; store.showError(error); break }
            }
            await store.refreshCases()
            await load()
            if !failed { store.showToast("Корзина очищена") }
        }
    }
}
