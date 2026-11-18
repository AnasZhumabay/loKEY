import SwiftUI

/// Участники кейса: роли, статусы, отзыв доступа (владелец) или выход (участник).
struct CaseMembersView: View {
    let caseId: String
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var members: [SharedMember] = []
    @State private var loaded = false
    @State private var revokeTarget: SharedMember?
    @State private var confirmLeave = false
    @State private var note: String?

    private var me: SharedMember? { members.first { $0.isMe } }
    private var iAmOwner: Bool { me.map { SharedRolePolicy.canManage($0.role) } ?? true }

    var body: some View {
        VStack(spacing: 0) {
            LKTopBar(title: "Участники").padding(.horizontal, 20).padding(.top, 8)
            ScrollView {
                VStack(spacing: 10) {
                    if !loaded { LKSkeletonRows(count: 2, height: 70) }
                    ForEach(Array(members.enumerated()), id: \.element.id) { i, m in row(m).lkAppear(i) }
                    if let note { Text(note).font(.lk(13, .medium)).foregroundStyle(Color.lkWarn).padding(12).lkCard() }
                    Text("Отзыв доступа не стирает то, что человек уже видел или скопировал. Если вы отозвали доступ, лучше сменить ключ кейса.")
                        .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).padding(.top, 6)
                    if iAmOwner, members.contains(where: { $0.status == .revoked }) {
                        Button("Сменить ключ кейса") { Task { await rotate() } }.buttonStyle(.lkSecondary)
                    }
                    if !iAmOwner {
                        Button("Выйти из кейса", role: .destructive) { confirmLeave = true }.buttonStyle(.lkSecondary).padding(.top, 8)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .lkScreen()
        .task { await reload() }
        .confirmationDialog(trf("Отозвать доступ у «%@»?", revokeTarget?.name ?? ""), isPresented: Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }), titleVisibility: .visible) {
            Button("Отозвать доступ", role: .destructive) { if let t = revokeTarget { Task { await revoke(t) } } }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Человек не сможет открывать кейс дальше, но то, что он уже видел или скопировал, останется у него. Рекомендуем сменить ключ кейса.") }
        .confirmationDialog("Выйти из кейса?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { Task { await leave() } }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func row(_ m: SharedMember) -> some View {
        HStack(spacing: 12) {
            SharedAvatar(name: m.name, tint: m.status == .revoked ? .lkMuted : .lkAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text(m.name).font(.lk(16, .bold))
                HStack(spacing: 6) {
                    SharedRoleTag(role: m.role)
                    Text(m.status.title).font(.lk(12, .semibold)).foregroundStyle(m.status == .active ? Color.lkAccent : Color.lkMuted)
                }
            }
            Spacer()
            if iAmOwner, !m.isMe, m.role != .owner, m.status != .revoked {
                Button { revokeTarget = m } label: { Image(systemName: "person.badge.minus").foregroundStyle(Color.lkDanger).frame(width: 44, height: 44) }
                    .accessibilityLabel(trf("Отозвать доступ: %@", m.name))
            }
        }
        .padding(12).lkCard()
        .opacity(m.status == .revoked ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    private func reload() async {
        let list = (try? await store.sharedCases.members(caseId: caseId)) ?? []
        withAnimation(reduceMotion ? nil : LKMotion.spring) { members = list; loaded = true }
    }
    private func revoke(_ m: SharedMember) async {
        do { try await store.sharedCases.revoke(caseId: caseId, userId: m.id); store.showToast("Доступ отозван"); await reload() }
        catch { store.showToast(error.localizedDescription, isError: true) }
        revokeTarget = nil
    }
    private func leave() async {
        do { try await store.sharedCases.leave(caseId: caseId); store.showToast("Вы вышли из кейса"); dismiss() }
        catch { store.showToast(error.localizedDescription, isError: true) }
    }
    private func rotate() async {
        do { try await store.sharedCases.rotateKeyAfterRevoke(caseId: caseId) }
        catch { note = "Смена ключа пока недоступна: нужна поддержка сервера. Пока считайте, что отозванный участник мог сохранить копию." }
    }
}
