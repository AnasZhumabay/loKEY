import SwiftUI

/// Выбор контакта и роли для общего кейса.
struct ShareCaseSheet: View {
    let caseId: String
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var contacts: [ChatContact] = []
    @State private var loaded = false
    @State private var selected: String?
    @State private var role: SharedRole = .viewer
    @State private var sending = false
    @State private var done = false
    @State private var error: String?

    private var contact: ChatContact? { contacts.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            LKTopBar(title: "Поделиться кейсом").padding(.horizontal, 20).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Выберите контакт из чата. Ключ кейса оборачивается общим ключом с этим человеком: сервер его не видит.")
                        .font(.lk(14, .medium)).foregroundStyle(Color.lkText2)
                    if !loaded { LKSkeletonRows(count: 3, height: 64) }
                    else if contacts.isEmpty {
                        Text("Контактов пока нет. Добавьте человека в чате через QR при встрече.").font(.lk(14, .medium)).foregroundStyle(Color.lkMuted).padding(16).lkCard()
                    }
                    ForEach(contacts) { c in
                        Button { withAnimation(reduceMotion ? nil : LKMotion.snappy) { selected = c.id } } label: {
                            HStack(spacing: 12) {
                                SharedAvatar(name: c.name)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).font(.lk(16, .bold))
                                    Text(c.verified ? "Проверен" : "Не проверен").font(.lk(12, .semibold)).foregroundStyle(c.verified ? Color.lkAccent : Color.lkWarn)
                                }
                                Spacer()
                                Image(systemName: selected == c.id ? "checkmark.circle.fill" : "circle").foregroundStyle(selected == c.id ? Color.lkAccent : Color.lkMuted)
                            }
                            .padding(12).lkCard(stroke: selected == c.id ? .lkAccent : .lkBorderSoft)
                        }
                        .buttonStyle(LKPressStyle(scale: 0.97))
                        .accessibilityAddTraits(selected == c.id ? .isSelected : [])
                    }
                    if let c = contact {
                        if !c.verified {
                            Label("Вы не сверяли код безопасности с этим контактом. Если ключ подменён, приглашение получит чужой человек. Сверьте код в чате до отправки.", systemImage: "exclamationmark.triangle.fill")
                                .font(.lk(13, .semibold)).foregroundStyle(Color.lkWarn).padding(12)
                                .background(Color.lkWarn.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                        Picker("Роль", selection: $role) {
                            ForEach(SharedRolePolicy.assignable, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        Text(role == .editor
                             ? "Редактор сможет открывать файлы, добавлять, менять и удалять их."
                             : "Просмотр: человек сможет открывать файлы, но не менять. Это правило приложения: уже открытое он может сохранить или сфотографировать.")
                            .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
                        if let error { Text(error).font(.lk(13, .semibold)).foregroundStyle(Color.lkDanger) }
                        Button { send(c) } label: {
                            Label(tr(done ? "Приглашение отправлено" : "Отправить приглашение"), systemImage: done ? "checkmark" : "paperplane")
                        }
                        .buttonStyle(.lkPrimary).disabled(sending || done)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .lkScreen()
        .task {
            contacts = await store.chat.threads().map(\.contact)
            loaded = true
        }
    }

    private func send(_ c: ChatContact) {
        sending = true; error = nil
        Task {
            do {
                try await store.sharedCases.invite(caseId: caseId, contactId: c.id, role: role)
                withAnimation(reduceMotion ? nil : LKMotion.spring) { done = true }
                store.showToast("Приглашение отправлено")
                try? await Task.sleep(for: .seconds(0.9)); dismiss()
            } catch { self.error = error.localizedDescription }
            sending = false
        }
    }
}
