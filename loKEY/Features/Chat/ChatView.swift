import SwiftUI

/// Переписка: тема чата, ответы, реакции, правка и удаление, сведения о сообщении, эмодзи и стикеры.
/// Каждое сообщение шифруется отдельным ключом; правка, удаление, реакции и тема тоже идут внутри шифртекста.
struct ChatView: View {
    let contactID: String

    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Panel { case emoji, stickers }

    @State private var contact: ChatContact?
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var showAttach = false
    @State private var showTheme = false
    @State private var confirmClear = false
    @State private var confirmRemove = false
    @State private var panel: Panel?
    @State private var menuMessage: ChatMessage?
    @State private var editing: ChatMessage?
    @State private var replyingTo: ChatMessage?
    @State private var infoMessage: ChatMessage?
    @State private var deleteTarget: ChatMessage?
    @State private var dragID: String?
    @State private var dragX: CGFloat = 0
    /// Переопределение таймера для следующего сообщения (nil у `msgTTLSet == false` = «как в чате»).
    @State private var msgTTLSet = false
    @State private var msgTTL: TimeInterval?
    @FocusState private var focused: Bool

    private var msgOptions: ChatSendOptions { msgTTLSet ? .ttl(msgTTL) : .chatDefault }
    private var effectiveTTL: TimeInterval? { msgTTLSet ? msgTTL : contact?.disappearAfter }
    private var theme: ChatTheme { ChatTheme.by(contact?.theme) }

    var body: some View {
        ZStack {
            theme.wallpaperGradient.ignoresSafeArea().animation(.easeInOut(duration: 0.5), value: theme.id)
            VStack(spacing: 0) {
                topBar
                thread
                inputArea
            }
            if let m = menuMessage {
                MessageMenu(message: m, theme: theme, canEdit: canEdit(m),
                            onReact: { emoji in toggleReaction(m, emoji) },
                            onReply: { replyingTo = m; editing = nil; focused = true },
                            onCopy: { UIPasteboard.general.string = m.text; Haptics.success(); store.showToast("Скопировано") },
                            onEdit: { editing = m; replyingTo = nil; draft = m.text; panel = nil; focused = true },
                            onInfo: { infoMessage = m },
                            onDelete: { deleteTarget = m },
                            onClose: { withAnimation(LKMotion.spring) { menuMessage = nil } })
                    .transition(.opacity)
                    .zIndex(5)
            }
        }
        .navigationBarBackButtonHidden(true).toolbar(.hidden, for: .navigationBar)
        .task {
            while !Task.isCancelled {
                await store.refreshChat()
                _ = await store.chat.expireDue(now: Date())      // исчезающие: стираются из памяти и с диска
                contact = await store.chat.contact(id: contactID)
                let m = await store.chat.messages(contactID: contactID)
                if m != messages { messages = m }
                await store.chat.markRead(contactID: contactID)
                await store.refreshChat()
                try? await Task.sleep(for: .seconds(1.0))
            }
        }
        .sheet(isPresented: $showAttach) {
            ChatAttachSheet(defaultTTL: contact?.disappearAfter) { att, opts in
                let reply = replyingTo?.id
                _ = try await store.chat.send(text: "", attachment: att, sticker: nil, replyTo: reply, options: opts, to: contactID)
                replyingTo = nil
                await reload()
            }
                .presentationDetents([.large]).presentationBackground(Color.lkCard)
        }
        .sheet(isPresented: $showTheme) {
            ChatThemeSheet(current: theme.id) { id in
                Task { await store.chat.setTheme(id, contactID: contactID); contact = await store.chat.contact(id: contactID); Haptics.success() }
            }
            .presentationDetents([.fraction(0.62)]).presentationBackground(Color.lkCard)
        }
        .sheet(item: $infoMessage) { m in
            MessageInfoSheet(message: m, theme: theme, contactName: contact?.name ?? "").presentationDetents([.large]).presentationBackground(Color.lkCard)
        }
        .confirmationDialog("Удалить сообщение?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible, presenting: deleteTarget) { m in
            Button("Удалить у меня", role: .destructive) { Task { try? await store.chat.delete(messageID: m.id, forEveryone: false, contactID: contactID); await reload() } }
            if m.fromMe {
                Button("Удалить у всех", role: .destructive) {
                    Task {
                        do { try await store.chat.delete(messageID: m.id, forEveryone: true, contactID: contactID) }
                        catch { store.showToast((error as? ChatError)?.errorDescription ?? "Не удалось удалить", isError: true) }
                        await reload()
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: { m in Text(m.fromMe ? "«Удалить у всех» заменит сообщение у собеседника пометкой об удалении." : "Сообщение исчезнет только на этом телефоне.") }
        .confirmationDialog("Очистить историю?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Очистить у меня", role: .destructive) { Task { await store.chat.clearHistory(contactID: contactID); messages = [] } }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Сообщения удалятся только на этом телефоне.") }
        .confirmationDialog("Удалить контакт?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { Task { await store.chat.removeContact(id: contactID); router.pop() } }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Переписка и ключи этого чата будут стёрты с телефона.") }
    }

    private func reload() async { messages = await store.chat.messages(contactID: contactID) }

    private func canEdit(_ m: ChatMessage) -> Bool {
        m.fromMe && !m.deleted && m.sticker == nil && m.attachment == nil && Date().timeIntervalSince(m.at) <= 15 * 60
    }

    // MARK: Шапка

    private var topBar: some View {
        HStack(spacing: 10) {
            LKIconButton(systemName: "chevron.left", label: "Назад") { router.pop() }
            if let c = contact {
                ChatAvatar(name: c.name, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(c.name).font(.lk(16, .heavy)).lineLimit(1)
                        if c.verified { Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(theme.accent) }
                    }
                    Label(tr(c.disappearAfter == nil ? "Защищённый чат" : "Сообщения исчезают"), systemImage: c.disappearAfter == nil ? "lock.fill" : "timer")
                        .font(.lk(11, .semibold)).foregroundStyle(theme.accent).labelStyle(.titleAndIcon)
                }
            }
            Spacer()
            Menu {
                Button { showTheme = true } label: { Label("Тема чата", systemImage: "paintpalette") }
                Button { router.push(.safety(contactID: contactID)) } label: { Label("Код безопасности", systemImage: "checkmark.shield") }
                Menu {
                    Picker("Исчезающие сообщения", selection: Binding(get: { contact?.disappearAfter }, set: { v in
                        Task { await store.chat.setDisappear(v, contactID: contactID); contact = await store.chat.contact(id: contactID) }
                    })) { ForEach(ChatDisappearPreset.all, id: \.title) { t in Text(LocalizedStringKey(t.title)).tag(t.seconds) } }
                } label: { Label("Исчезающие сообщения", systemImage: "timer") }
                Button { confirmClear = true } label: { Label("Очистить историю", systemImage: "eraser") }
                Button(role: .destructive) { confirmRemove = true } label: { Label("Удалить контакт", systemImage: "person.badge.minus") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                    .background(Color.lkCard.opacity(0.8), in: Circle()).overlay(Circle().stroke(Color.lkBorder, lineWidth: 1))
            }
            .accessibilityLabel("Меню чата")
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        .background(.ultraThinMaterial.opacity(0.6))
    }

    // MARK: Лента

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    banner.padding(.bottom, 10)
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                        let prev = i > 0 ? messages[i - 1] : nil
                        let next = i + 1 < messages.count ? messages[i + 1] : nil
                        if let prev { if !Calendar.current.isDate(prev.at, inSameDayAs: m.at) { daySeparator(m.at) } } else { daySeparator(m.at) }
                        let first = prev.map { $0.fromMe != m.fromMe || !Calendar.current.isDate($0.at, inSameDayAs: m.at) || m.at.timeIntervalSince($0.at) > 300 } ?? true
                        let last = next.map { $0.fromMe != m.fromMe || $0.at.timeIntervalSince(m.at) > 300 } ?? true
                        if m.system != nil {
                            systemRow(m).id(m.id).transition(.opacity)
                        } else {
                            MessageRow(message: m, theme: theme, first: first, last: last, dragX: dragID == m.id ? dragX : 0,
                                       onLongPress: { Haptics.rigid(); withAnimation(LKMotion.spring) { menuMessage = m } },
                                       onDoubleTap: { toggleReaction(m, "❤️") },
                                       onReplyTap: { id in withAnimation(LKMotion.spring) { proxy.scrollTo(id, anchor: .center) } },
                                       onShown: { shown(m) })
                                .id(m.id)
                                .padding(.top, first && prev != nil ? 8 : 0)
                                .simultaneousGesture(swipeReply(m))
                                .transition(.asymmetric(insertion: .move(edge: m.fromMe ? .trailing : .leading).combined(with: .opacity).combined(with: .scale(scale: 0.92)),
                                                        removal: .opacity.combined(with: .scale(scale: 0.85))))
                        }
                    }
                    Color.clear.frame(height: 8).id("end")
                }
                .padding(.horizontal, 12).padding(.top, 8)
                .animation(LKMotion.spring, value: messages.map(\.id))
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in withAnimation(LKMotion.spring) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: panel) { _, _ in withAnimation(LKMotion.spring) { proxy.scrollTo("end", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    /// Таймер входящего исчезающего сообщения стартует, когда оно ВПЕРВЫЕ показано (не при получении).
    private func shown(_ m: ChatMessage) {
        guard !m.fromMe, m.ttl != nil, m.expiresAt == nil else { return }
        Task { await store.chat.messageShown(ids: [m.id], contactID: contactID); await reload() }
    }

    private func systemText(_ m: ChatMessage) -> Text {
        guard case .disappear(let s)? = m.system else { return Text(m.text) }
        if s == nil { return Text("Исчезающие сообщения: выкл") }
        return Text("Исчезающие сообщения: \(Text(LocalizedStringKey(ChatDisappearPreset.title(for: s))))")
    }

    private func systemRow(_ m: ChatMessage) -> some View {
        Label { systemText(m) } icon: { Image(systemName: "timer") }
            .font(.lk(11, .bold)).foregroundStyle(theme.accent).padding(.horizontal, 12).padding(.vertical, 6)
            .background(theme.accent.opacity(0.1), in: Capsule()).padding(.vertical, 10)
            .frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }

    private func swipeReply(_ m: ChatMessage) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { v in
                guard abs(v.translation.width) > abs(v.translation.height) * 1.6, !m.deleted else { return }
                let dx = m.fromMe ? min(0, v.translation.width) : max(0, v.translation.width)
                dragID = m.id; dragX = max(-70, min(70, dx * 0.6))
                if abs(dragX) > 42, abs(dragX) < 46 { Haptics.soft() }
            }
            .onEnded { _ in
                if abs(dragX) > 42 { replyingTo = m; editing = nil; focused = true; Haptics.rigid() }
                withAnimation(LKMotion.spring) { dragX = 0 }
                dragID = nil
            }
    }

    private var banner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold))
                Text("Сообщения защищены сквозным шифрованием. Прочитать их можете только вы и собеседник.")
                    .font(.lk(12, .semibold)).multilineTextAlignment(.leading)
            }
            .foregroundStyle(theme.accent).padding(12)
            .background(theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let c = contact, !c.verified {
                Button { router.push(.safety(contactID: contactID)) } label: {
                    Label("Контакт не проверен. Сверьте код безопасности", systemImage: "exclamationmark.shield")
                        .font(.lk(12, .bold)).foregroundStyle(Color.lkWarn).padding(.horizontal, 12).frame(height: 34)
                        .background(Color.lkWarn.opacity(0.1), in: Capsule())
                }
                .buttonStyle(LKPressStyle(scale: 0.96))
            }
        }
    }

    private func daySeparator(_ d: Date) -> some View {
        let cal = Calendar.current
        let t = cal.isDateInToday(d) ? "Сегодня" : (cal.isDateInYesterday(d) ? "Вчера" : d.formatted(.dateTime.day().month(.wide).locale(LKBundle.uiLocale)))
        return Text(t).font(.lk(11, .bold)).foregroundStyle(Color.lkMuted).padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.white.opacity(0.06), in: Capsule()).padding(.vertical, 10)
    }

    // MARK: Ввод

    private var inputArea: some View {
        VStack(spacing: 0) {
            if let e = editing { contextBar(icon: "pencil", title: "Изменение сообщения", text: e.text) { editing = nil; draft = "" } }
            else if let r = replyingTo {
                contextBar(icon: "arrowshape.turn.up.left", title: r.fromMe ? tr("Ответ себе") : trf("Ответ %@", contact?.name ?? ""), text: preview(r)) { replyingTo = nil }
            }
            if editing == nil, contact != nil, focused || !draft.isEmpty || msgTTLSet || effectiveTTL != nil { ttlChip.transition(.move(edge: .bottom).combined(with: .opacity)) }
            inputBar
            if panel != nil {
                EmojiPanel(mode: panel ?? .emoji, accent: theme.accent, onModeChange: { panel = $0 },
                           onEmoji: { draft += $0; Haptics.soft() },
                           onBackspace: { if !draft.isEmpty { draft.removeLast() } },
                           onSticker: { id in Task { await send(text: "", attachment: nil, sticker: id) } })
                    .frame(height: 300).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(.ultraThinMaterial).background(Color.lkBg.opacity(0.6))
        .animation(LKMotion.spring, value: panel)
        .animation(LKMotion.spring, value: editing?.id)
        .animation(LKMotion.spring, value: replyingTo?.id)
        .animation(LKMotion.spring, value: focused)
    }

    /// Таймер для следующего сообщения: перекрывает таймер чата. После отправки возвращается «как в чате».
    private var ttlChip: some View {
        let title = ChatDisappearPreset.title(for: effectiveTTL)
        return HStack {
            Menu {
                Button { msgTTLSet = false; Haptics.soft() } label: { Label("Как в чате", systemImage: "arrow.uturn.backward") }
                ForEach(ChatDisappearPreset.all, id: \.title) { p in
                    Button { msgTTLSet = true; msgTTL = p.seconds; Haptics.soft() } label: { Text(LocalizedStringKey(p.title)) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "timer").font(.system(size: 12, weight: .bold))
                    Text("Таймер: \(Text(LocalizedStringKey(title)))").font(.lk(12, .bold))
                }
                .foregroundStyle(effectiveTTL == nil ? Color.lkMuted : theme.accent).padding(.horizontal, 12).frame(height: 30)
                .background((effectiveTTL == nil ? Color.white.opacity(0.07) : theme.accent.opacity(0.14)), in: Capsule())
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Таймер исчезновения сообщения")
            .accessibilityValue(Text(LocalizedStringKey(title)))
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func preview(_ m: ChatMessage) -> String {
        if m.deleted { return "Сообщение удалено" }
        if m.sticker != nil { return "Стикер" }
        if let a = m.attachment { return "📎 " + a.name }
        return m.text
    }

    private func contextBar(icon: String, title: String, text: String, onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 3, height: 34)
            Image(systemName: icon).foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.lk(12, .heavy)).foregroundStyle(theme.accent)
                Text(text).font(.lk(13, .medium)).foregroundStyle(Color.lkMuted).lineLimit(1)
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(Color.lkMuted).frame(width: 40, height: 40) }
                .accessibilityLabel("Отменить")
        }
        .padding(.horizontal, 16).padding(.top, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var inputBar: some View {
        let can = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
        return HStack(alignment: .bottom, spacing: 10) {
            Button { focused = false; panel = nil; showAttach = true } label: {
                Image(systemName: "plus").font(.system(size: 18, weight: .bold)).foregroundStyle(theme.onMine)
                    .frame(width: 42, height: 42).background(theme.mineGradient, in: Circle())
            }
            .buttonStyle(LKPressStyle(scale: 0.88)).accessibilityLabel("Прикрепить файл из кейса")
            HStack(alignment: .bottom, spacing: 4) {
                TextField("Сообщение", text: $draft, axis: .vertical)
                    .font(.lk(16, .medium)).lineLimit(1...5).focused($focused).tint(theme.accent)
                    .padding(.leading, 16).padding(.vertical, 11)
                    .onChange(of: focused) { _, f in if f { panel = nil } }
                Button {
                    if panel == nil { focused = false; panel = .emoji } else { panel = nil; focused = true }
                    Haptics.soft()
                } label: {
                    Image(systemName: panel == nil ? "face.smiling" : "keyboard").font(.system(size: 20, weight: .medium)).foregroundStyle(panel == nil ? Color.lkMuted : theme.accent)
                        .frame(width: 42, height: 42).contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel("Эмодзи и стикеры")
            }
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(focused ? theme.accent.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1.2))
            Button { if can { submit() } else { Task { await send(text: "", attachment: nil, sticker: "heart") } } } label: {
                ZStack {
                    if can || editing != nil {
                        Image(systemName: editing != nil ? "checkmark" : "arrow.up").font(.system(size: 18, weight: .heavy)).foregroundStyle(theme.onMine)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Text("❤️").font(.system(size: 24)).transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 44, height: 44)
                .background(can ? AnyShapeStyle(theme.mineGradient) : AnyShapeStyle(Color.clear), in: Circle())
            }
            .buttonStyle(LKPressStyle(scale: 0.86)).accessibilityLabel(tr(can ? "Отправить" : "Отправить сердце"))
            .animation(LKMotion.snappy, value: can)
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
    }

    private func submit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let e = editing {
            editing = nil; draft = ""
            Task {
                do { try await store.chat.edit(messageID: e.id, text: t, contactID: contactID); Haptics.success() }
                catch { store.showToast((error as? ChatError)?.errorDescription ?? "Не удалось изменить", isError: true) }
                await reload()
            }
        } else {
            Task { await send(text: t, attachment: nil, sticker: nil) }
        }
    }

    private func toggleReaction(_ m: ChatMessage, _ emoji: String) {
        let mine = m.reactions.first { $0.fromMe }?.emoji
        Haptics.soft()
        withAnimation(LKMotion.spring) { menuMessage = nil }
        Task {
            try? await store.chat.react(messageID: m.id, emoji: mine == emoji ? nil : emoji, contactID: contactID)
            await reload()
        }
    }

    private func send(text: String, attachment: ChatAttachment?, sticker: String?) async {
        let opts = msgOptions
        msgTTLSet = false
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || attachment != nil || sticker != nil, !sending else { return }
        sending = true; defer { sending = false }
        let reply = replyingTo?.id
        if sticker == nil && attachment == nil { draft = "" }
        replyingTo = nil
        Haptics.soft()
        do { _ = try await store.chat.send(text: t, attachment: attachment, sticker: sticker, replyTo: reply, options: opts, to: contactID) }
        catch { store.showToast((error as? ChatError)?.errorDescription ?? "Не удалось отправить", isError: true) }
        await reload()
    }
}

// MARK: - Строка сообщения

private struct MessageRow: View {
    let message: ChatMessage
    let theme: ChatTheme
    let first: Bool
    let last: Bool
    let dragX: CGFloat
    let onLongPress: () -> Void
    let onDoubleTap: () -> Void
    let onReplyTap: (String) -> Void
    var onShown: () -> Void = {}

    var body: some View {
        let m = message
        HStack(alignment: .bottom, spacing: 0) {
            if m.fromMe { Spacer(minLength: 56) }
            VStack(alignment: m.fromMe ? .trailing : .leading, spacing: 3) {
                BubbleContent(message: m, theme: theme, first: first, last: last, onReplyTap: onReplyTap)
                    .overlay(alignment: m.fromMe ? .bottomLeading : .bottomTrailing) { reactions }
                    .overlay(alignment: m.fromMe ? .topLeading : .topTrailing) {
                        if (m.ttl != nil || m.expiresAt != nil), !m.deleted {
                            CountdownRing(total: m.ttl ?? 1, expires: m.expiresAt, tint: theme.accent).padding(3)
                                .background(Color.lkCard, in: Circle()).offset(x: m.fromMe ? -8 : 8, y: -6).transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.bottom, m.reactions.isEmpty ? 0 : 12)
                if last { meta }
            }
            .offset(x: dragX)
            .overlay(alignment: m.fromMe ? .trailing : .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill").foregroundStyle(theme.accent).opacity(min(1, abs(dragX) / 40))
                    .scaleEffect(min(1, abs(dragX) / 40)).offset(x: m.fromMe ? 36 : -36)
            }
            if !m.fromMe { Spacer(minLength: 56) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !m.deleted { onDoubleTap() } }
        .onLongPressGesture(minimumDuration: 0.35) { if !m.deleted { onLongPress() } }
        .onAppear { onShown() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((m.fromMe ? "Вы: " : "") + (m.deleted ? "Сообщение удалено" : (m.sticker != nil ? "Стикер" : (m.attachment?.name ?? m.text))))
        .accessibilityAction(named: "Меню сообщения") { if !m.deleted { onLongPress() } }
    }

    @ViewBuilder private var reactions: some View {
        if !message.reactions.isEmpty {
            HStack(spacing: 2) {
                ForEach(Array(message.reactions.enumerated()), id: \.offset) { _, r in Text(r.emoji).font(.system(size: 13)) }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.lkCard, in: Capsule()).overlay(Capsule().stroke(Color.lkBg, lineWidth: 2))
            .overlay(Capsule().stroke(theme.accent.opacity(0.4), lineWidth: 1))
            .offset(x: message.fromMe ? 8 : -8, y: 12)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var meta: some View {
        HStack(spacing: 4) {
            if message.edited { Text("изменено") }
            if message.ttl != nil || message.expiresAt != nil { Image(systemName: "timer").font(.system(size: 9)) }
            if message.noForward { Image(systemName: "lock.fill").font(.system(size: 9)).accessibilityLabel("Пересылка запрещена") }
            Text(message.at.formatted(date: .omitted, time: .shortened)).font(.lkMono(10, .medium))
            if message.fromMe {
                switch message.state {
                case .sending: Image(systemName: "clock").font(.system(size: 9))
                case .sent: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                case .failed: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(Color.lkDanger)
                }
            }
        }
        .font(.lk(10, .medium)).foregroundStyle(Color.lkMuted).padding(.horizontal, 4)
    }
}

/// Пузырь без жестов: используется и в ленте, и в превью меню.
private struct BubbleContent: View {
    let message: ChatMessage
    let theme: ChatTheme
    var first = true
    var last = true
    var onReplyTap: ((String) -> Void)?

    private func shape(_ m: ChatMessage) -> UnevenRoundedRectangle {
        let big: CGFloat = 22, small: CGFloat = 6
        if m.fromMe {
            return UnevenRoundedRectangle(topLeadingRadius: big, bottomLeadingRadius: big, bottomTrailingRadius: last ? small : small, topTrailingRadius: first ? big : small, style: .continuous)
        }
        return UnevenRoundedRectangle(topLeadingRadius: first ? big : small, bottomLeadingRadius: last ? small : small, bottomTrailingRadius: big, topTrailingRadius: big, style: .continuous)
    }

    var body: some View {
        let m = message
        if m.deleted {
            Label("Сообщение удалено", systemImage: "nosign").font(.lk(13, .medium)).italic().foregroundStyle(Color.lkMuted)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .overlay(shape(m).stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        } else if let sid = m.sticker, let st = ChatSticker.by(sid) {
            VStack(alignment: m.fromMe ? .trailing : .leading, spacing: 4) {
                if let r = m.reply { replyQuote(r, onTheme: false) }
                StickerView(sticker: st, size: 128)
            }
        } else if m.attachment == nil, m.reply == nil, EmojiSet.isBigEmoji(m.text) {
            Text(m.text).font(.system(size: 58)).padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let r = m.reply { replyQuote(r, onTheme: m.fromMe) }
                if let a = m.attachment {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.fill").font(.system(size: 20)).foregroundStyle(m.fromMe ? theme.onMine : theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.lk(14, .bold)).lineLimit(1)
                            Text(LKFormat.bytes(Int64(a.bytes))).font(.lk(11, .medium)).opacity(0.7)
                        }
                    }
                }
                if !m.text.isEmpty { Text(m.text).font(.lk(15, .medium)).fixedSize(horizontal: false, vertical: true) }
                if m.noForward {
                    Label("Без пересылки", systemImage: "lock.fill").font(.lk(10, .bold)).opacity(0.75)
                }
            }
            .foregroundStyle(m.fromMe ? theme.onMine : Color.lkText)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background { if m.fromMe { shape(m).fill(theme.mineGradient) } else { shape(m).fill(Color.lkCard) } }
            .overlay { if !m.fromMe { shape(m).stroke(Color.lkBorderSoft, lineWidth: 1) } }
        }
    }

    private func replyQuote(_ r: ChatReply, onTheme: Bool) -> some View {
        Button { onReplyTap?(r.id) } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(onTheme ? theme.onMine.opacity(0.7) : theme.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.fromMe ? "Вы" : "Собеседник").font(.lk(11, .heavy))
                    Text(r.text).font(.lk(12, .medium)).lineLimit(2).opacity(0.85)
                }
            }
            .foregroundStyle(onTheme ? theme.onMine : Color.lkText2)
            .padding(8).frame(maxWidth: 240, alignment: .leading)
            .background((onTheme ? Color.black.opacity(0.14) : Color.white.opacity(0.06)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Меню сообщения (как в Instagram)

private struct MessageMenu: View {
    let message: ChatMessage
    let theme: ChatTheme
    let canEdit: Bool
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onInfo: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.45)).ignoresSafeArea()
                .onTapGesture { onClose() }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 12) {
                reactionBar
                BubbleContent(message: message, theme: theme).allowsHitTesting(false).scaleEffect(shown ? 1 : 0.92)
                actions
            }
            .padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: message.fromMe ? .trailing : .leading)
            .scaleEffect(shown ? 1 : 0.9, anchor: message.fromMe ? .topTrailing : .topLeading).opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(LKMotion.spring) { shown = true } }
    }

    private var reactionBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(EmojiSet.quick.enumerated()), id: \.offset) { i, e in
                let mine = message.reactions.first { $0.fromMe }?.emoji == e
                Button { onReact(e) } label: {
                    Text(e).font(.system(size: 28)).frame(width: 44, height: 44)
                        .background(mine ? theme.accent.opacity(0.25) : Color.clear, in: Circle())
                        .scaleEffect(shown ? 1 : 0.3)
                        .animation(LKMotion.spring.delay(Double(i) * 0.04), value: shown)
                }
                .buttonStyle(LKPressStyle(scale: 1.25))
            }
        }
        .padding(6).background(Color.lkCard, in: Capsule()).overlay(Capsule().stroke(Color.lkBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            action("Ответить", "arrowshape.turn.up.left") { onClose(); onReply() }
            if !message.text.isEmpty, message.fromMe || message.canForward { Divider().overlay(Color.white.opacity(0.06)); action("Копировать", "doc.on.doc") { onClose(); onCopy() } }
            if canEdit { Divider().overlay(Color.white.opacity(0.06)); action("Изменить", "pencil") { onClose(); onEdit() } }
            Divider().overlay(Color.white.opacity(0.06)); action("Сведения", "info.circle") { onClose(); onInfo() }
            Divider().overlay(Color.white.opacity(0.06)); action("Удалить", "trash", destructive: true) { onClose(); onDelete() }
        }
        .frame(width: 230).background(Color.lkCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.lkBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }

    private func action(_ title: String, _ icon: String, destructive: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button { Haptics.soft(); run() } label: {
            HStack { Text(title).font(.lk(15, .semibold)); Spacer(); Image(systemName: icon).font(.system(size: 15, weight: .semibold)) }
                .foregroundStyle(destructive ? Color.lkDanger : Color.lkText).padding(.horizontal, 16).frame(height: 46).contentShape(Rectangle())
        }
        .buttonStyle(LKPressStyle(scale: 0.98))
    }
}

// MARK: - Сведения о сообщении

private struct MessageInfoSheet: View {
    let message: ChatMessage
    let theme: ChatTheme
    let contactName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Сведения").font(.lk(20, .heavy)); Spacer()
                Button("Готово") { dismiss() }.font(.lk(16, .bold)).foregroundStyle(Color.lkAccent).frame(minHeight: 44)
            }.padding(.horizontal, 20).padding(.top, 16)
            ScrollView {
                VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 16) {
                    BubbleContent(message: message, theme: theme).frame(maxWidth: .infinity, alignment: message.fromMe ? .trailing : .leading)
                    VStack(spacing: 0) {
                        row("paperplane", "Отправитель", message.fromMe ? "Вы" : contactName)
                        div; row("clock", "Время", message.at.formatted(date: .abbreviated, time: .standard))
                        div; row("checkmark.circle", "Статус", status)
                        if message.edited { div; row("pencil", "Правка", "Сообщение было изменено") }
                        if let e = message.expiresAt {
                            div; countdownRow(e)
                            div; row("timer", "Исчезнет", e.formatted(date: .abbreviated, time: .shortened))
                        } else if let t = message.ttl {
                            div; row("timer", "Исчезнет", message.fromMe ? trf("Через %@", ChatDisappearPreset.title(for: t)) : trf("Через %@ после показа", ChatDisappearPreset.title(for: t)))
                        }
                        if message.noForward { div; row("lock.fill", "Пересылка", "Запрещена отправителем (пометка клиента)") }
                        if !message.reactions.isEmpty { div; row("face.smiling", "Реакции", message.reactions.map { ($0.fromMe ? "Вы " : "") + $0.emoji }.joined(separator: "  ")) }
                    }
                    .padding(.horizontal, 14).lkCard(radius: 20)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Шифрование", systemImage: "lock.shield.fill").font(.lk(13, .heavy)).foregroundStyle(Color.lkAccent)
                        encRow("Алгоритм", "AES-256-GCM")
                        if let c = message.counter { encRow("Ключ сообщения", "№\(c) в цепочке (одноразовый)") }
                        if message.cipherBytes > 0 { encRow("Размер шифртекста", "\(message.cipherBytes) Б") }
                        Text("Сервер видел только случайные байты. Подтверждений прочтения нет: приложение не сообщает, открыл ли собеседник сообщение.")
                            .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.lkAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 30)
            }
        }
        .lkScreen()
    }

    private var status: String {
        guard message.fromMe else { return "Получено и расшифровано" }
        switch message.state { case .sending: return "Отправляется"; case .sent: return "Принято сервером"; case .failed: return "Не отправлено" }
    }
    /// «Исчезнет через …»: обновляется каждую секунду.
    private func countdownRow(_ e: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 12) {
                Image(systemName: "hourglass").foregroundStyle(Color.lkText2).frame(width: 22)
                Text("Исчезнет через").font(.lk(14, .semibold)); Spacer(minLength: 8)
                Text(ChatCountdown.text(e.timeIntervalSince(ctx.date))).font(.lkMono(13, .bold)).foregroundStyle(theme.accent)
            }.frame(minHeight: 48)
        }
    }
    private var div: some View { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    private func row(_ icon: String, _ k: String, _ v: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.lkText2).frame(width: 22)
            Text(k).font(.lk(14, .semibold)); Spacer(minLength: 8)
            Text(v).font(.lk(13, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.trailing)
        }.frame(minHeight: 48)
    }
    private func encRow(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.lk(13, .semibold)); Spacer(); Text(v).font(.lkMono(12, .medium)).foregroundStyle(Color.lkText2) }
    }
}

// MARK: - Тема чата

private struct ChatThemeSheet: View {
    let current: String
    let onPick: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String

    init(current: String, onPick: @escaping (String?) -> Void) { self.current = current; self.onPick = onPick; _selected = State(initialValue: current) }

    var body: some View {
        let t = ChatTheme.by(selected)
        VStack(spacing: 16) {
            HStack {
                Text("Тема чата").font(.lk(20, .heavy)); Spacer()
                Button("Готово") { dismiss() }.font(.lk(16, .bold)).foregroundStyle(Color.lkAccent).frame(minHeight: 44)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(t.wallpaperGradient)
                VStack(spacing: 8) {
                    HStack { Text("Как тебе эта тема?").font(.lk(14, .medium)).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color.lkCard, in: Capsule()); Spacer() }
                    HStack { Spacer(); Text("Выглядит отлично ✨").font(.lk(14, .medium)).foregroundStyle(t.onMine).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(t.mineGradient, in: Capsule()) }
                }.padding(16)
            }
            .frame(height: 120).overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.lkBorder, lineWidth: 1))
            .animation(.easeInOut(duration: 0.3), value: selected)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                ForEach(ChatTheme.all) { th in
                    Button { selected = th.id; onPick(th.id); Haptics.soft() } label: {
                        VStack(spacing: 6) {
                            Circle().fill(th.mineGradient).frame(width: 52, height: 52)
                                .overlay(Circle().stroke(Color.white, lineWidth: selected == th.id ? 3 : 0).padding(-4))
                                .overlay { if selected == th.id { Image(systemName: "checkmark").font(.system(size: 16, weight: .heavy)).foregroundStyle(th.onMine) } }
                            Text(th.name).font(.lk(11, .semibold)).foregroundStyle(selected == th.id ? Color.lkText : Color.lkMuted)
                        }
                    }
                    .buttonStyle(LKPressStyle(scale: 0.9))
                }
            }
            Text("Тема меняется у вас и у собеседника: выбор передаётся внутри зашифрованного сообщения.")
                .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
    }
}

// MARK: - Смайлики и стикеры

private struct EmojiPanel: View {
    let mode: ChatView.Panel
    let accent: Color
    let onModeChange: (ChatView.Panel) -> Void
    let onEmoji: (String) -> Void
    let onBackspace: () -> Void
    let onSticker: (String) -> Void
    @State private var category = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                tab("Смайлики", .emoji); tab("Стикеры", .stickers)
                Spacer()
                if mode == .emoji {
                    Button { onBackspace() } label: { Image(systemName: "delete.left").frame(width: 44, height: 36).foregroundStyle(Color.lkText2) }
                        .accessibilityLabel("Стереть")
                }
            }
            .padding(.horizontal, 14).padding(.top, 8)
            if mode == .emoji {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(EmojiSet.categories.enumerated()), id: \.offset) { i, c in
                            Button { withAnimation(LKMotion.snappy) { category = i } } label: {
                                Image(systemName: c.1).font(.system(size: 15, weight: .semibold)).foregroundStyle(category == i ? accent : Color.lkMuted)
                                    .frame(width: 40, height: 34).background(category == i ? accent.opacity(0.14) : .clear, in: Capsule())
                            }
                            .accessibilityLabel(tr(c.0))
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 6)
                }.scrollIndicators(.hidden)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 8), spacing: 6) {
                        ForEach(Array(EmojiSet.categories[category].2.enumerated()), id: \.offset) { _, e in
                            Button { onEmoji(e) } label: { Text(e).font(.system(size: 30)).frame(maxWidth: .infinity, minHeight: 42) }
                                .buttonStyle(LKPressStyle(scale: 1.3))
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 12)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(ChatSticker.all) { s in
                            Button { onSticker(s.id) } label: { StickerView(sticker: s, size: 104, animated: false) }
                                .buttonStyle(LKPressStyle(scale: 0.92))
                        }
                    }.padding(14)
                }
            }
        }
    }

    private func tab(_ t: String, _ m: ChatView.Panel) -> some View {
        Button { onModeChange(m); Haptics.soft() } label: {
            Text(t).font(.lk(13, .bold)).foregroundStyle(mode == m ? Color.lkBg : Color.lkText2)
                .padding(.horizontal, 14).frame(height: 32).background(mode == m ? accent : Color.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(LKPressStyle(scale: 0.94))
    }
}

/// «Из кейса»: выбор открытого кейса, затем файла. Файл расшифровывается только в памяти и сразу уходит зашифрованным в чат.
/// Опции: таймер самоуничтожения и «Запретить пересылку» (вежливая клиентская пометка, не защита от модифицированного клиента и скриншотов).
private struct ChatAttachSheet: View {
    let defaultTTL: TimeInterval?
    let onSend: @MainActor (ChatAttachment, ChatSendOptions) async throws -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Phase: Equatable { case idle, decrypting(String), sending(String), failed(String), done }
    @State private var selected: String?
    @State private var files: [VaultFile] = []
    @State private var loading = true
    @State private var phase: Phase = .idle
    @State private var lastFile: VaultFile?
    @State private var useTTL = false
    @State private var ttl: TimeInterval?
    @State private var noForward = false

    private var busy: Bool { if case .decrypting = phase { return true }; if case .sending = phase { return true }; return false }
    private var options: ChatSendOptions { useTTL ? .ttl(ttl, noForward: noForward) : ChatSendOptions(noForward: noForward) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Из кейса").font(.lk(20, .heavy))
                Spacer()
                Button("Отмена") { dismiss() }.font(.lk(16, .bold)).foregroundStyle(Color.lkAccent).frame(minHeight: 44).disabled(busy)
            }.padding(.horizontal, 20).padding(.top, 16)
            if store.unlockedCases.isEmpty {
                Spacer()
                Text("Нет открытых кейсов. Откройте кейс, чтобы отправить файл из него.")
                    .font(.lk(14, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center).padding(32)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        options_
                        casePicker
                        statusBanner
                        fileList
                    }
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
                }
            }
        }
        .lkScreen()
        .interactiveDismissDisabled(busy)
        .task { if selected == nil { selected = store.unlockedCases.first?.id }; await loadFiles() }
        .onChange(of: selected) { _, _ in Task { await loadFiles() } }
    }

    private var options_: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Максимум 5 МБ. Файл остаётся в кейсе, копия уходит собеседнику в зашифрованном виде.")
                .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted)
            HStack {
                Label("Самоуничтожение", systemImage: "timer").font(.lk(14, .bold))
                Spacer()
                Menu {
                    Button { useTTL = false } label: { Label("Как в чате", systemImage: "arrow.uturn.backward") }
                    ForEach(ChatDisappearPreset.all, id: \.title) { p in
                        Button { useTTL = true; ttl = p.seconds } label: { Text(LocalizedStringKey(p.title)) }
                    }
                } label: {
                    Text(LocalizedStringKey(useTTL ? ChatDisappearPreset.title(for: ttl) : (defaultTTL == nil ? "Как в чате" : ChatDisappearPreset.title(for: defaultTTL))))
                        .font(.lk(13, .bold)).foregroundStyle(Color.lkAccent).padding(.horizontal, 12).frame(minHeight: 44)
                }
                .accessibilityLabel("Таймер самоуничтожения")
            }
            Toggle(isOn: $noForward) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Запретить пересылку", systemImage: "lock.fill").font(.lk(14, .bold))
                    Text("Приложение собеседника скроет «Копировать» и пересылку. Это вежливая пометка: она не остановит изменённое приложение или скриншот.")
                        .font(.lk(11, .medium)).foregroundStyle(Color.lkMuted)
                }
            }
            .tint(Color.lkAccent).frame(minHeight: 44)
        }
        .padding(14).background(Color.lkRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var casePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(store.unlockedCases) { c in
                    Button { selected = c.id; Haptics.soft() } label: {
                        Text(c.name).font(.lk(13, .bold)).foregroundStyle(selected == c.id ? Color.lkBg : Color.lkText2)
                            .padding(.horizontal, 14).frame(height: 36).background(selected == c.id ? Color.lkAccent : Color.white.opacity(0.07), in: Capsule())
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(LKPressStyle(scale: 0.95)).disabled(busy)
                    .accessibilityLabel(trf("Кейс %@", c.name)).accessibilityAddTraits(selected == c.id ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var statusBanner: some View {
        switch phase {
        case .idle: EmptyView()
        case .decrypting(let n), .sending(let n):
            HStack(spacing: 10) {
                ProgressView().tint(Color.lkAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isDecrypting ? "Расшифровка в памяти…" : "Шифрование и отправка…").font(.lk(13, .bold))
                    Text(n).font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).lineLimit(1)
                }
                Spacer()
            }
            .padding(12).background(Color.lkAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous)).transition(.opacity)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Label(tr(msg), systemImage: "exclamationmark.triangle.fill").font(.lk(13, .bold)).foregroundStyle(Color.lkDanger)
                if let f = lastFile {
                    Button { Task { await pick(f) } } label: { Label("Повторить", systemImage: "arrow.clockwise").font(.lk(13, .bold)).frame(minHeight: 44) }
                        .foregroundStyle(Color.lkAccent)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.lkDanger.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous)).transition(.opacity)
        case .done:
            Label("Отправлено", systemImage: "checkmark.circle.fill").font(.lk(14, .heavy)).foregroundStyle(Color.lkAccent)
                .frame(maxWidth: .infinity, minHeight: 44).transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
        }
    }

    private var isDecrypting: Bool { if case .decrypting = phase { return true }; return false }

    @ViewBuilder private var fileList: some View {
        if loading { LKSkeletonRows(count: 3) }
        else if files.isEmpty {
            Text("В этом кейсе нет файлов.").font(.lk(14, .medium)).foregroundStyle(Color.lkMuted).frame(maxWidth: .infinity).padding(.top, 20)
        } else {
            VStack(spacing: 6) {
                ForEach(files) { f in
                    Button { Task { await pick(f) } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: f.kind.systemName).foregroundStyle(f.kind.tint).frame(width: 36, height: 36)
                                .background(f.kind.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.lk(15, .bold)).lineLimit(1)
                                Text(f.bytes > 5_000_000 ? "Больше 5 МБ" : LKFormat.bytes(f.bytes)).font(.lk(12, .medium)).foregroundStyle(Color.lkMuted)
                            }
                            Spacer()
                        }
                        .padding(12).frame(minHeight: 56).background(Color.lkRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LKPressStyle(scale: 0.97)).disabled(busy || f.bytes > 5_000_000)
                    .opacity(f.bytes > 5_000_000 ? 0.4 : 1)
                }
            }
        }
    }

    private func loadFiles() async {
        guard let id = selected else { loading = false; return }
        loading = true
        files = (try? await store.repo.listFiles(caseID: id)) ?? []
        loading = false
    }

    private func pick(_ f: VaultFile) async {
        lastFile = f
        withAnimation(LKMotion.snappy) { phase = .decrypting(f.name) }
        do {
            let data = try await store.repo.openFile(id: f.id)
            store.noteActivity()
            withAnimation(LKMotion.snappy) { phase = .sending(f.name) }
            try await onSend(ChatAttachment(name: f.name, bytes: data.count, data: data), options)
            withAnimation(LKMotion.snappy) { phase = .done }
            Haptics.success()
            try? await Task.sleep(for: .milliseconds(650))
            dismiss()
        } catch {
            Haptics.error()
            let msg = (error as? ChatError)?.errorDescription ?? (error as? VaultError)?.message ?? "Не удалось отправить файл"
            withAnimation(LKMotion.snappy) { phase = .failed(msg) }
        }
    }
}

// MARK: - Таймер исчезновения

enum ChatCountdown {
    static func text(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded(.up)))
        if t < 60 { return trf("%lld с", t) }
        if t < 3600 { return trf("%lld мин %lld с", t / 60, t % 60) }
        if t < 86400 { return trf("%lld ч %lld мин", t / 3600, t % 3600 / 60) }
        return trf("%lld дн %lld ч", t / 86400, t % 86400 / 3600)
    }
}

/// Кольцо обратного отсчёта на сообщении. Пока таймер не стартовал (входящее ещё не показано), кольцо полное.
/// При «Уменьшении движения» анимация убывания отключена: кольцо просто обновляется раз в секунду.
private struct CountdownRing: View {
    let total: TimeInterval
    let expires: Date?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = expires.map { max(0, $0.timeIntervalSince(ctx.date)) }
            let frac = left.map { total > 0 ? min(1, $0 / total) : 0 } ?? 1
            ZStack {
                Circle().stroke(tint.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: frac).stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                    .animation(reduce ? nil : Animation.linear(duration: 1), value: frac)
            }
            .frame(width: 14, height: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(left.map { trf("Исчезнет через %@", ChatCountdown.text($0)) } ?? tr("Исчезнет после показа"))
        }
    }
}
