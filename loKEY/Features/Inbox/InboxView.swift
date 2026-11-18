import SwiftUI

/// «Входящие»: файлы, присланные через «Поделиться в loKEY». Перенос в ОТКРЫТЫЙ кейс.
struct InboxView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var items: [InboxItem] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var selected: Set<String> = []
    @State private var caseID: String?
    @State private var moving = false
    @State private var moveProgress: Double = 0
    @State private var moveLabel = ""
    @State private var movedCount: Int?
    @State private var deleteTarget: InboxItem?
    @State private var confirmDeleteSelected = false

    private var cases: [VaultCase] { store.unlockedCases }
    private var targetCase: VaultCase? { cases.first { $0.id == caseID } ?? cases.first }
    private var anim: Animation? { reduceMotion ? nil : LKMotion.spring }

    var body: some View {
        VStack(spacing: 0) {
            LKTopBar(title: "Входящие", subtitle: items.isEmpty ? nil : "\(items.count) \(tr(plural(items.count)))") {
                if !items.isEmpty && !moving {
                    Button(tr(allSelected ? "Снять" : "Все")) {
                        Haptics.soft()
                        withAnimation(anim) { selected = allSelected ? [] : Set(items.map(\.id)) }
                    }
                    .font(.lk(14, .bold)).foregroundStyle(Color.lkAccent)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(tr(allSelected ? "Снять выбор со всех" : "Выбрать все"))
                }
            }
            .padding(.horizontal, 16)

            ZStack {
                content
                if movedCount != nil { successOverlay }
            }
        }
        .lkScreen()
        .task { await reload(initial: true) }
        .onAppear { store.noteActivity() }
        .confirmationDialog("Удалить из входящих?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible, presenting: deleteTarget) { item in
            Button("Удалить из входящих", role: .destructive) { delete([item.id]) }
            Button("Отмена", role: .cancel) {}
        } message: { item in Text(verbatim: trf("«%@» будет удалён безвозвратно.", item.name)) }
        .confirmationDialog(trf("Удалить выбранные (%lld)?", selected.count), isPresented: $confirmDeleteSelected, titleVisibility: .visible) {
            Button("Удалить из входящих", role: .destructive) { delete(Array(selected)) }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Файлы будут удалены безвозвратно.") }
    }

    private var allSelected: Bool { !items.isEmpty && selected.count == items.count }

    // MARK: Состояния

    @ViewBuilder private var content: some View {
        if loading {
            ScrollView { LKSkeletonRows(count: 4) }
        } else if let loadError {
            message(icon: "exclamationmark.triangle", title: "Не удалось загрузить", text: loadError,
                    button: "Повторить") { Task { await reload(initial: true) } }
        } else if items.isEmpty {
            message(icon: "tray", title: "Пусто",
                    text: "Откройте файл в любом приложении, нажмите «Поделиться» и выберите loKEY — он появится здесь.",
                    button: "Назад") { router.pop() }
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            row(item).lkAppear(i)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                footer
            }
        }
    }

    private func message(icon: String, title: String, text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(Color.lkAccent)
                .frame(width: 84, height: 84).background(Color.lkAccent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(title).font(.lk(20, .heavy))
            Text(text).font(.lk(14, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center)
            Button(tr(button), action: action).buttonStyle(.lkPrimary).padding(.top, 8)
            Spacer(); Spacer()
        }
        .padding(.horizontal, 32)
        .lkAppear()
    }

    // MARK: Строка

    private func row(_ item: InboxItem) -> some View {
        let isSel = selected.contains(item.id)
        let kind = FileKind(rawValue: item.kind) ?? .other
        return Button {
            guard !moving else { return }
            Haptics.soft()
            withAnimation(anim) { if isSel { selected.remove(item.id) } else { selected.insert(item.id) } }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: kind.systemName).font(.system(size: 19, weight: .semibold)).foregroundStyle(kind.tint)
                    .frame(width: 46, height: 46)
                    .background(kind.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.lk(15, .bold)).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: "\(LKFormat.bytes(item.bytes)) · \(relative(item.addedAt))")
                        .font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted).lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(isSel ? Color.lkAccent : Color.lkMuted)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 12).frame(minHeight: 68)
            .lkCard(radius: 20, fill: isSel ? Color.lkAccent.opacity(0.08) : .lkCard,
                    stroke: isSel ? Color.lkAccent.opacity(0.5) : .lkBorderSoft)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(LKPressStyle())
        .contextMenu {
            Button(role: .destructive) { deleteTarget = item } label: { Label("Удалить из входящих", systemImage: "trash") }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(LKFormat.bytes(item.bytes)), \(relative(item.addedAt))")
        .accessibilityAddTraits(isSel ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Удалить из входящих") { deleteTarget = item }
    }

    // MARK: Нижняя панель

    @ViewBuilder private var footer: some View {
        VStack(spacing: 12) {
            if cases.isEmpty {
                VStack(spacing: 10) {
                    Label("Откройте кейс, чтобы переместить файлы", systemImage: "lock.open")
                        .font(.lk(14, .bold)).foregroundStyle(Color.lkText2).multilineTextAlignment(.center)
                    Button("Открыть кейс") { router.pop() }.buttonStyle(.lkPrimary)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(cases) { c in casePill(c) }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
                if moving {
                    VStack(spacing: 8) {
                        ProgressView(value: moveProgress).tint(Color.lkAccent)
                        Text(moveLabel).font(.lk(13, .semibold)).foregroundStyle(Color.lkMuted)
                    }
                    .frame(minHeight: 56)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(trf("%lld процентов", Int(moveProgress * 100)))
                } else {
                    Button { startMove() } label: {
                        Text(verbatim: selected.isEmpty ? tr("Выберите файлы") : trf("Переместить (%lld) в «%@»", selected.count, targetCase?.name ?? ""))
                            .lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 16)
                    }
                    .buttonStyle(.lkPrimary)
                    .disabled(selected.isEmpty || targetCase == nil)
                    if !selected.isEmpty {
                        Button("Удалить выбранные", role: .destructive) { confirmDeleteSelected = true }
                            .font(.lk(14, .bold)).foregroundStyle(Color.lkDanger)
                            .frame(minHeight: 44)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 12)
        .background(Color.lkBg.opacity(0.92).overlay(alignment: .top) { Rectangle().fill(Color.lkBorderSoft).frame(height: 1) })
        .animation(anim, value: selected.isEmpty)
    }

    private func casePill(_ c: VaultCase) -> some View {
        let on = c.id == targetCase?.id
        return Button {
            guard !moving else { return }
            Haptics.soft(); withAnimation(anim) { caseID = c.id }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: c.icon.systemName).font(.system(size: 15, weight: .semibold))
                Text(c.name).font(.lk(14, on ? .heavy : .semibold)).lineLimit(1)
            }
            .foregroundStyle(on ? Color.lkBg : Color.lkText2)
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(on ? Color.lkAccent : Color.lkCard, in: Capsule())
            .overlay(Capsule().stroke(on ? .clear : Color.lkBorder, lineWidth: 1))
        }
        .buttonStyle(LKPressStyle(scale: 0.94))
        .accessibilityLabel(trf("Кейс %@", c.name))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var successOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Color.lkAccent)
                .symbolEffect(.bounce, value: movedCount)
            Text(verbatim: trf("Перемещено: %lld", movedCount ?? 0)).font(.lk(18, .heavy))
            if let t = targetCase { Text(verbatim: trf("в «%@»", t.name)).font(.lk(14, .semibold)).foregroundStyle(Color.lkMuted) }
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    // MARK: Логика

    private func reload(initial: Bool = false) async {
        if initial { loading = true; loadError = nil }
        do {
            let list = try await Task.detached(priority: .userInitiated) { try InboxStore.list() }.value
            withAnimation(anim) {
                items = list
                selected = selected.intersection(Set(list.map(\.id)))
                loadError = nil
            }
        } catch {
            loadError = error.localizedDescription
        }
        if caseID == nil || !cases.contains(where: { $0.id == caseID }) { caseID = cases.first?.id }
        loading = false
    }

    private func startMove() {
        guard let target = targetCase, !moving else { return }
        let chosen = items.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        store.noteActivity()
        moving = true; moveProgress = 0
        Task {
            var done = 0
            var failure: Error?
            for item in chosen {
                moveLabel = trf("Шифрую «%@» (%lld из %lld)", item.name, done + 1, chosen.count)
                do {
                    let data = try await Task.detached(priority: .userInitiated) { try InboxStore.open(item.id) }.value
                    let kind = FileKind(rawValue: item.kind) ?? .other
                    let total = Double(chosen.count), base = Double(done)
                    _ = try await store.repo.addFile(caseID: target.id, name: item.name, kind: kind, data: data, note: nil) { p in
                        Task { @MainActor in moveProgress = max(moveProgress, (base + p.fraction * 0.95) / total) }
                    }
                    InboxStore.remove(item.id)
                    done += 1
                    withAnimation(anim) { moveProgress = Double(done) / Double(chosen.count) }
                } catch {
                    failure = error
                    break
                }
            }
            await store.refreshCases()
            await reload()
            moving = false
            if let failure {
                Haptics.error()
                store.showError(failure)
            }
            if done > 0 {
                Haptics.success()
                withAnimation(anim) { movedCount = done }
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                withAnimation(anim) { movedCount = nil }
            }
        }
    }

    private func delete(_ ids: [String]) {
        Haptics.warning()
        Task {
            await Task.detached { ids.forEach { InboxStore.remove($0) } }.value
            await reload()
            store.showToast("Удалено из входящих")
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = LKBundle.uiLocale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func plural(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "файл" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "файла" }
        return "файлов"
    }
}
