import SwiftUI

/// Входящие приглашения и мои общие кейсы.
struct SharedCasesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Row: Identifiable { var id: String; var name: String; var count: Int }
    @State private var invites: [SharedInvite] = []
    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var busy: Set<String> = []
    @State private var error: String?
    @State private var membersFor: String?

    private var anim: Animation? { reduceMotion ? nil : LKMotion.spring }

    var body: some View {
        VStack(spacing: 0) {
            LKTopBar(title: "Общие кейсы", subtitle: "Для двоих").padding(.horizontal, 20).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error {
                        Label(tr(error), systemImage: "exclamationmark.triangle").font(.lk(13, .semibold)).foregroundStyle(Color.lkDanger)
                    }
                    if !loaded { LKSkeletonRows(count: 3, height: 80) }
                    else {
                        section("Приглашения") {
                            if invites.isEmpty { hint("Новых приглашений нет.") }
                            ForEach(Array(invites.enumerated()), id: \.element.id) { i, inv in inviteCard(inv).lkAppear(i)
                                .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity))) }
                        }
                        section("Мои общие кейсы") {
                            if rows.isEmpty { hint("Пока нет. Откройте кейс и выберите «Поделиться кейсом».") }
                            ForEach(rows) { r in
                                Button { membersFor = r.id } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "person.2.fill").foregroundStyle(Color.lkAccent).frame(width: 44, height: 44)
                                            .background(Color.lkAccent.opacity(0.12), in: Circle())
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(r.name).font(.lk(16, .bold))
                                            Text(verbatim: trf("Участников: %lld", r.count)).font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(Color.lkMuted)
                                    }
                                    .padding(14).lkCard()
                                }
                                .buttonStyle(LKPressStyle(scale: 0.97))
                                .accessibilityElement(children: .combine)
                                .accessibilityHint("Открыть участников")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .lkScreen()
        .sheet(item: Binding(get: { membersFor.map { IDBox(id: $0) } }, set: { membersFor = $0?.id })) { b in
            CaseMembersView(caseId: b.id).environment(store)
        }
        .task { await reload() }
    }

    private struct IDBox: Identifiable { let id: String }

    private func section<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t).font(.lk(13, .bold)).foregroundStyle(Color.lkMuted).textCase(.uppercase).accessibilityAddTraits(.isHeader)
            c()
        }
    }
    private func hint(_ s: String) -> some View {
        Text(s).font(.lk(14, .medium)).foregroundStyle(Color.lkMuted).frame(maxWidth: .infinity, alignment: .leading).padding(16).lkCard()
    }

    private func inviteCard(_ inv: SharedInvite) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SharedAvatar(name: inv.fromName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(inv.caseName ?? "Общий кейс").font(.lk(16, .bold))
                    Text(verbatim: trf("От: %@", inv.fromName)).font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
                }
                Spacer()
            }
            if !inv.fromVerified {
                Label("Контакт не проверен. Сверьте код безопасности, прежде чем принимать.", systemImage: "exclamationmark.shield")
                    .font(.lk(12, .semibold)).foregroundStyle(Color.lkWarn)
            }
            HStack(spacing: 10) {
                Button("Принять") { act(inv, accept: true) }.buttonStyle(.lkPrimary)
                Button("Отклонить") { act(inv, accept: false) }.buttonStyle(.lkSecondary)
            }
            .disabled(busy.contains(inv.id))
        }
        .padding(14).lkCard()
        .accessibilityElement(children: .contain)
    }

    private func act(_ inv: SharedInvite, accept: Bool) {
        busy.insert(inv.id)
        Task {
            do {
                if accept { try await store.sharedCases.accept(inviteId: inv.id) } else { try await store.sharedCases.decline(inviteId: inv.id) }
                withAnimation(anim) { invites.removeAll { $0.id == inv.id } }
                store.showToast(accept ? "Вы в кейсе" : "Приглашение скрыто")
                await reload()
            } catch { self.error = error.localizedDescription; store.showToast(error.localizedDescription, isError: true) }
            busy.remove(inv.id)
        }
    }

    private func reload() async {
        let svc = store.sharedCases
        let inv = (try? await svc.pendingInvites()) ?? []
        let cases = (try? await store.repo.listCases()) ?? []
        var ids = cases.map(\.id)
        for j in await svc.joinedCaseIds() where !ids.contains(j) { ids.append(j) }
        var out: [Row] = []
        for id in ids {
            guard let m = try? await svc.members(caseId: id) else { continue }
            let active = m.filter { $0.status != .revoked }
            guard svc.isShared(caseId: id) else { continue }
            out.append(Row(id: id, name: cases.first { $0.id == id }?.name ?? "Общий кейс", count: active.count))
        }
        withAnimation(anim) { invites = inv; rows = out; loaded = true }
    }
}
