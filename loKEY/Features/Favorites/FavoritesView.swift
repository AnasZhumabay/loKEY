import SwiftUI

struct FavoritesView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum LoadState { case loading, loaded, failed(String) }
    @State private var files: [VaultFile] = []
    @State private var state: LoadState = .loading
    @State private var caseFilter: String?          // nil — все кейсы
    @State private var starPulse = false

    private var openIDs: [String] { store.unlockedCases.map(\.id) }

    private var visibleFiles: [VaultFile] { files.filter { caseFilter == nil || $0.caseID == caseFilter } }

    private var groups: [(VaultCase, [VaultFile])] {
        store.unlockedCases.compactMap { c in
            guard caseFilter == nil || caseFilter == c.id else { return nil }
            let f = files.filter { $0.caseID == c.id }.sorted { $0.createdAt > $1.createdAt }
            return f.isEmpty ? nil : (c, f)
        }
    }

    private var pinned: [VaultFile] { Array(visibleFiles.sorted { $0.createdAt > $1.createdAt }.prefix(6)) }

    private func caseOf(_ f: VaultFile) -> VaultCase? { store.vaultCase(f.caseID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text("Избранное").font(.lk(30, .heavy)).tracking(-0.9)
                if !files.isEmpty {
                    Text("\(files.count)").font(.lk(14, .heavy)).foregroundStyle(Color.lkBg)
                        .padding(.horizontal, 9).frame(height: 24).background(Color.lkWarn, in: Capsule())
                        .contentTransition(.numericText()).transition(.scale.combined(with: .opacity))
                }
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 16).padding(.top, 8)
            .animation(LKMotion.spring, value: files.count)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .lkScreen(glow: .lkWarn, strength: 0.14)
        .task(id: openIDs) { await load() }
    }

    @ViewBuilder private var content: some View {
        if store.unlockedCases.isEmpty {
            lockedState
        } else {
            switch state {
            case .loading where files.isEmpty:
                ScrollView { LKSkeletonRows(count: 5) }.scrollDisabled(true)
            case .failed(let m) where files.isEmpty:
                message(icon: "exclamationmark.triangle", title: "Не удалось загрузить", text: m, button: "Повторить") {
                    Task { await load() }
                }
            default:
                if groups.isEmpty && caseFilter == nil { emptyState } else { list }
            }
        }
    }

    // MARK: Состояния

    private var lockedState: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle().fill(Color.lkWarn.opacity(0.08)).frame(width: 120, height: 120)
                Circle().stroke(Color.lkWarn.opacity(0.25), lineWidth: 1).frame(width: 120, height: 120)
                    .scaleEffect(starPulse ? 1.25 : 1).opacity(starPulse ? 0 : 1)
                Image(systemName: "lock.fill").font(.system(size: 36, weight: .semibold)).foregroundStyle(Color.lkWarn)
                    .symbolEffect(.bounce, value: starPulse)
            }
            .onAppear { guard !reduceMotion else { return }; withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { starPulse = true } }
            Text("Нет открытых кейсов").font(.lk(22, .heavy)).tracking(-0.4)
            Text("Избранные файлы видны только из открытых кейсов. Откройте кейс, чтобы увидеть их здесь.")
                .font(.lk(15, .medium)).foregroundStyle(Color(hex: 0xA9B0B8)).multilineTextAlignment(.center).lineSpacing(3)
            Button("К кейсам") { router.tab = .cases }.buttonStyle(.lkPrimary).padding(.top, 8)
            Spacer()
        }
        .padding(.horizontal, 32).padding(.bottom, 110).frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "star.fill").font(.system(size: 40)).foregroundStyle(Color.lkWarn)
                .frame(width: 112, height: 112)
                .background(Color.lkWarn.opacity(0.1), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(Color.lkWarn.opacity(0.3), lineWidth: 1))
                .phaseAnimator(reduceMotion ? [0.0] : [0.0, 1.0]) { v, p in v.scaleEffect(1 + p * 0.06).rotationEffect(.degrees(p * 6)) } animation: { _ in .easeInOut(duration: 1.3) }
            Text("Пока ничего нет").font(.lk(22, .heavy)).tracking(-0.4)
            VStack(alignment: .leading, spacing: 10) {
                step("1", "Откройте файл в кейсе")
                step("2", "Нажмите звёздочку рядом с ним")
                step("3", "Он появится здесь для быстрого доступа")
            }
            .padding(16).frame(maxWidth: 300).lkCard(radius: 20)
            Spacer()
        }
        .padding(.horizontal, 24).padding(.bottom, 110).frame(maxWidth: .infinity)
    }

    private func step(_ n: String, _ t: String) -> some View {
        HStack(spacing: 12) {
            Text(n).font(.lk(12, .heavy)).foregroundStyle(Color.lkBg).frame(width: 22, height: 22).background(Color.lkWarn, in: Circle())
            Text(t).font(.lk(14, .semibold)).foregroundStyle(Color.lkText2)
        }
    }

    // MARK: Список

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if pinned.count > 1 || (pinned.count == 1 && caseFilter == nil) { pinnedCarousel }
                caseChips
                if groups.isEmpty {
                    Text("В этом кейсе нет избранных файлов.").font(.lk(14, .medium)).foregroundStyle(Color.lkMuted)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                }
                ForEach(Array(groups.enumerated()), id: \.element.0.id) { gi, g in
                    let (c, fs) = g
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: c.icon.systemName).font(.system(size: 13, weight: .semibold)).foregroundStyle(c.level.tint)
                                .frame(width: 30, height: 30).background(c.level.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text(c.name).font(.lk(16, .heavy)).tracking(-0.2)
                            Spacer()
                            Text("\(fs.count)").font(.lkMono(12, .bold)).foregroundStyle(Color.lkMuted)
                        }
                        .padding(.horizontal, 4)
                        VStack(spacing: 8) {
                            ForEach(fs) { f in
                                row(f, tint: c.level.tint)
                                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                            }
                        }
                    }
                    .lkAppear(gi)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 124)
            .animation(LKMotion.spring, value: files.map(\.id))
        }
        .scrollIndicators(.hidden)
        .refreshable { await load() }
    }

    private var pinnedCarousel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ЧАСТО НУЖНО").font(.lk(11, .heavy)).tracking(1.1).foregroundStyle(Color.lkMuted).padding(.horizontal, 4)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Array(pinned.enumerated()), id: \.element.id) { i, f in
                        Button { router.push(.file(fileID: f.id, caseID: f.caseID)) } label: { pinnedCard(f) }
                            .buttonStyle(LKPressStyle(scale: 0.96))
                            .scrollTransition(axis: .horizontal) { c, p in
                                c.scaleEffect(p.isIdentity ? 1 : 0.92).opacity(p.isIdentity ? 1 : 0.6)
                            }
                            .lkAppear(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 0, for: .scrollContent)
        }
    }

    private func pinnedCard(_ f: VaultFile) -> some View {
        let tint = f.kind.tint
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: f.kind.systemName).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 44, height: 44).background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer()
                Image(systemName: "star.fill").font(.system(size: 14)).foregroundStyle(Color.lkWarn)
            }
            Spacer(minLength: 8)
            Text(f.name).font(.lk(16, .heavy)).tracking(-0.2).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(Color.lkText)
            HStack(spacing: 6) {
                Text(f.kind.label).font(.lkMono(10, .bold)).foregroundStyle(tint)
                Text("·").foregroundStyle(Color.lkMuted)
                Text(caseOf(f)?.name ?? "").lineLimit(1).font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted)
            }
            .padding(.top, 3)
        }
        .padding(14).frame(width: 220, height: 150, alignment: .leading)
        .background(LinearGradient(colors: [tint.opacity(0.18), Color.lkCard], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(tint.opacity(0.28), lineWidth: 1))
    }

    private var caseChips: some View {
        let open = store.unlockedCases.filter { c in files.contains { $0.caseID == c.id } }
        return Group {
            if open.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        LKChip(title: "Все", count: files.count, selected: caseFilter == nil) { setFilter(nil) }
                        ForEach(open) { c in
                            LKChip(title: c.name, count: files.filter { $0.caseID == c.id }.count, selected: caseFilter == c.id) { setFilter(c.id) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func setFilter(_ id: String?) {
        withAnimation(LKMotion.snappy) { caseFilter = id }
        Haptics.soft(); store.noteActivity()
    }

    private func row(_ f: VaultFile, tint caseTint: Color) -> some View {
        let tint = f.kind.tint
        return Button { router.push(.file(fileID: f.id, caseID: f.caseID)) } label: {
            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Image(systemName: f.kind.systemName).font(.system(size: 17, weight: .semibold))
                    Text(f.kind.label).font(.lkMono(9, .bold))
                }
                .foregroundStyle(tint).frame(width: 50, height: 50)
                .background(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.07)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(tint.opacity(0.25), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.name).font(.lk(16, .bold)).lineLimit(1)
                    Text(meta(f)).font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button { unfavorite(f) } label: {
                    Image(systemName: "star.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.lkWarn)
                        .frame(width: 40, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(LKPressStyle(scale: 0.75))
                .accessibilityLabel("Убрать из избранного")
            }
            .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 72)
            .background(Color.lkCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.lkBorderSoft, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(LKPressStyle(scale: 0.975))
        .contextMenu {
            Button { router.push(.file(fileID: f.id, caseID: f.caseID)) } label: { Label("Открыть", systemImage: "arrow.up.right.square") }
            Button(role: .destructive) { unfavorite(f) } label: { Label("Убрать из избранного", systemImage: "star.slash") }
        }
        .accessibilityElement(children: .combine)
    }

    private func unfavorite(_ f: VaultFile) {
        store.noteActivity()
        Task {
            do {
                _ = try await store.repo.updateFile(id: f.id, name: nil, note: nil, favorite: false, offline: nil)
                Haptics.soft()
                withAnimation(LKMotion.spring) { files.removeAll { $0.id == f.id } }
                if let id = caseFilter, !files.contains(where: { $0.caseID == id }) { withAnimation(LKMotion.snappy) { caseFilter = nil } }
            } catch { store.showError(error) }
        }
    }

    private func meta(_ f: VaultFile) -> String {
        let size = LKFormat.bytes(f.bytes)
        if let n = f.note, !n.isEmpty { return "\(n) · \(size)" }
        return "\(f.kind.label) · \(size)"
    }

    private func message(icon: String, title: String, text: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon).font(.system(size: 32, weight: .semibold)).foregroundStyle(Color.lkAccent)
                .frame(width: 84, height: 84).lkCard(radius: 28)
            Text(title).font(.lk(22, .heavy)).tracking(-0.4)
            Text(text).font(.lk(15, .medium)).foregroundStyle(Color(hex: 0xA9B0B8)).multilineTextAlignment(.center).lineSpacing(3)
            if let button {
                Button(tr(button), action: action).buttonStyle(.lkPrimary).padding(.top, 10)
            }
            Spacer()
        }
        .padding(.horizontal, 32).padding(.bottom, 110)
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        guard !store.unlockedCases.isEmpty else { files = []; return }
        do {
            files = try await store.repo.favoriteFiles()
            state = .loaded
        } catch {
            state = .failed((error as? VaultError)?.message ?? "Что-то пошло не так")
        }
    }
}
