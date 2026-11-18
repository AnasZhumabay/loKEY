import SwiftUI

/// Список чатов в духе Instagram/Threads: крупный заголовок, поиск, лента контактов, фильтры, строки без рамок.
struct ChatListView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    enum Filter: String, CaseIterable { case all = "Все", unread = "Непрочитанные", verified = "Проверенные" }
    @State private var threads: [ChatThread] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var removeTarget: ChatThread?
    @FocusState private var searchFocused: Bool

    private var filtered: [ChatThread] {
        threads.filter { t in
            switch filter {
            case .all: break
            case .unread: if t.unread == 0 { return false }
            case .verified: if !t.contact.verified { return false }
            }
            let q = query.trimmingCharacters(in: .whitespaces)
            return q.isEmpty || t.contact.name.localizedCaseInsensitiveContains(q) || (t.last?.text ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    searchField
                    if !threads.isEmpty && query.isEmpty { contactsStrip }
                    if !threads.isEmpty { chips }
                    if !loaded { LKSkeletonRows(count: 4, height: 70).padding(.horizontal, -16) }
                    else if threads.isEmpty { empty }
                    else if filtered.isEmpty {
                        Text(query.isEmpty ? "В этой категории пока пусто." : "Ничего не найдено").font(.lk(14, .medium)).foregroundStyle(Color.lkMuted)
                            .frame(maxWidth: .infinity).padding(.top, 30)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { i, t in row(t).lkAppear(i) }
                        }
                        .animation(LKMotion.spring, value: filtered.map(\.id))
                    }
                    footnote
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 40)
            }
            .scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
        }
        .lkScreen()
        .navigationBarBackButtonHidden(true).toolbar(.hidden, for: .navigationBar)
        .task {
            while !Task.isCancelled {
                await store.refreshChat()
                let t = await store.chat.threads()
                withAnimation(LKMotion.snappy) { threads = t; loaded = true }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        .confirmationDialog("Удалить чат?", isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
                            titleVisibility: .visible, presenting: removeTarget) { t in
            Button(trf("Удалить чат с %@", t.contact.name), role: .destructive) { Task { await store.chat.removeContact(id: t.contact.id); Haptics.warning() } }
            Button("Отмена", role: .cancel) {}
        } message: { _ in Text("Переписка и ключи этого чата будут стёрты с телефона.") }
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 10) {
            // Как корневая вкладка список не в стеке: «Назад» там некуда вести.
            if !router.path.isEmpty { LKIconButton(systemName: "chevron.left", label: "Назад") { router.pop() } }
            Text("Сообщения").font(.lk(26, .heavy)).tracking(-0.7)
            if store.chatUnread > 0 {
                Text("\(store.chatUnread)").font(.lk(13, .heavy)).foregroundStyle(Color.lkBg)
                    .padding(.horizontal, 8).frame(minWidth: 24, minHeight: 24).background(Color.lkAccent, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            LKIconButton(systemName: "square.and.pencil", label: "Добавить контакт") { router.push(.addContact) }
        }
        .animation(LKMotion.spring, value: store.chatUnread)
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(searchFocused ? Color.lkAccent : Color.lkMuted)
            TextField("Поиск", text: $query).font(.lk(16, .medium)).focused($searchFocused).autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.lkMuted).frame(width: 36, height: 36) }
                    .accessibilityLabel("Очистить")
            }
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(Color.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().stroke(searchFocused ? Color.lkAccent.opacity(0.6) : .clear, lineWidth: 1.5))
        .animation(LKMotion.snappy, value: searchFocused)
    }

    // MARK: Лента контактов (как «заметки» в Instagram)

    private var contactsStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                Button { router.push(.addContact) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.lkAccent)
                            .frame(width: 64, height: 64)
                            .background(Circle().strokeBorder(Color.lkAccent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
                        Text("Новый").font(.lk(11, .semibold)).foregroundStyle(Color.lkMuted)
                    }
                }
                .buttonStyle(LKPressStyle(scale: 0.92)).accessibilityLabel("Добавить контакт")
                ForEach(threads) { t in
                    Button { router.push(.chat(contactID: t.contact.id)) } label: {
                        VStack(spacing: 6) {
                            ZStack(alignment: .bottomTrailing) {
                                ChatAvatar(name: t.contact.name, size: 58)
                                    .padding(3)
                                    .overlay(Circle().stroke(t.unread > 0 ? AnyShapeStyle(LinearGradient(colors: [.lkAccent, .lkPurple], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color.white.opacity(0.1)), lineWidth: 2.5))
                                if t.contact.verified {
                                    Image(systemName: "checkmark.seal.fill").font(.system(size: 14)).foregroundStyle(Color.lkAccent)
                                        .background(Circle().fill(Color.lkBg).padding(-1))
                                }
                            }
                            Text(t.contact.name).font(.lk(11, t.unread > 0 ? .bold : .semibold)).lineLimit(1).frame(width: 70)
                                .foregroundStyle(t.unread > 0 ? Color.lkText : Color.lkMuted)
                        }
                    }
                    .buttonStyle(LKPressStyle(scale: 0.92))
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { f in
                    let n: Int? = f == .unread ? threads.filter { $0.unread > 0 }.count : nil
                    LKChip(title: f.rawValue, count: (n ?? 0) > 0 ? n : nil, selected: filter == f) {
                        withAnimation(LKMotion.snappy) { filter = f }; Haptics.soft()
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Строки

    private func row(_ t: ChatThread) -> some View {
        let unread = t.unread > 0
        return Button { router.push(.chat(contactID: t.contact.id)) } label: {
            HStack(spacing: 14) {
                ChatAvatar(name: t.contact.name, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(t.contact.name).font(.lk(16, unread ? .heavy : .bold)).lineLimit(1)
                        if t.contact.verified { Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(Color.lkAccent) }
                        if t.contact.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Color.lkMuted) }
                    }
                    HStack(spacing: 4) {
                        Text(preview(t)).font(.lk(14, unread ? .semibold : .medium)).foregroundStyle(unread ? Color.lkText : Color.lkMuted).lineLimit(1)
                        if let l = t.last { Text("· " + Self.time(l.at)).font(.lk(13, .medium)).foregroundStyle(Color.lkMuted).fixedSize() }
                    }
                }
                Spacer(minLength: 6)
                if unread {
                    Circle().fill(Color.lkAccent).frame(width: 11, height: 11).shadow(color: Color.lkAccent.opacity(0.6), radius: 4)
                        .transition(.scale.combined(with: .opacity))
                } else if t.last?.fromMe == true {
                    Image(systemName: "paperplane").font(.system(size: 13)).foregroundStyle(Color.lkMuted)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 4).frame(minHeight: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(LKPressStyle(scale: 0.98))
        .contextMenu {
            Button { Task { await store.chat.setPinned(!t.contact.pinned, contactID: t.contact.id) } } label: {
                Label(tr(t.contact.pinned ? "Открепить" : "Закрепить"), systemImage: t.contact.pinned ? "pin.slash" : "pin")
            }
            Button { router.push(.safety(contactID: t.contact.id)) } label: { Label("Код безопасности", systemImage: "checkmark.shield") }
            Button(role: .destructive) { removeTarget = t } label: { Label("Удалить чат", systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
    }

    private func preview(_ t: ChatThread) -> String {
        guard let l = t.last else { return "Нажмите, чтобы написать" }
        let body: String
        if l.deleted { body = "Сообщение удалено" }
        else if let s = l.sticker, let st = ChatSticker.by(s) { body = st.emoji + " Стикер" }
        else if let a = l.attachment { body = "📎 " + a.name }
        else { body = l.text }
        return (l.fromMe ? "Вы: " : "") + body
    }

    private static func time(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "вчера" }
        return d.formatted(.dateTime.day().month(.abbreviated).locale(LKBundle.uiLocale))
    }

    private var footnote: some View {
        Label("Все чаты защищены сквозным шифрованием", systemImage: "lock.fill")
            .font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted).frame(maxWidth: .infinity).padding(.top, 14)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.lkAccent.opacity(0.08)).frame(width: 110, height: 110)
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 38)).foregroundStyle(Color.lkAccent)
                    .phaseAnimator([0.0, -6.0]) { v, y in v.offset(y: y) } animation: { _ in .easeInOut(duration: 1.4) }
            }
            Text("Пока нет чатов").font(.lk(20, .heavy))
            Text("Добавьте собеседника: покажите ему свой QR-код или отсканируйте его код. Так никто посторонний не окажется в чате.")
                .font(.lk(14, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center).padding(.horizontal, 12)
            Button { router.push(.addContact) } label: { Label("Добавить контакт", systemImage: "qrcode.viewfinder") }
                .buttonStyle(.lkPrimary).padding(.top, 6)
        }
        .padding(.top, 36)
    }
}

struct ChatAvatar: View {
    let name: String
    var size: CGFloat = 44
    var body: some View {
        Text(String(name.prefix(1)).uppercased()).font(.lk(size * 0.42, .heavy)).foregroundStyle(Color.lkBg)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [.lkAccent, .lkPurple], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .accessibilityHidden(true)
    }
}
