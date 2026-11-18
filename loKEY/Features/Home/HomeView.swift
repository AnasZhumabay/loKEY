import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum CaseFilter: String, CaseIterable { case all = "Все", open = "Открытые", locked = "Закрытые", favorites = "Избранное" }
    enum CaseSort: String, CaseIterable { case name = "По имени", date = "По дате", size = "По размеру", level = "По уровню защиты" }
    private enum Chooser { case camera, upload, unlock }

    @State private var filter: CaseFilter = .all
    @State private var sort: CaseSort = .date
    @State private var searching = false
    @State private var query = ""
    @State private var loaded = false
    @State private var chooser: Chooser?
    @State private var renameTarget: VaultCase?
    @State private var renameText = ""
    @FocusState private var searchFocused: Bool
    @State private var recents: [(file: VaultFile, caseName: String)] = []
    @State private var fileHits: [(file: VaultFile, caseName: String)] = []
    @State private var plateHidden = false
    @State private var chatThreads: [ChatThread] = []
    @State private var inboxCount = 0
    @State private var searchTask: Task<Void, Never>?

    private var cases: [VaultCase] { store.cases }

    private func count(_ f: CaseFilter) -> Int { cases.filter { matches($0, f) }.count }
    private func matches(_ c: VaultCase, _ f: CaseFilter) -> Bool {
        switch f {
        case .all: return true
        case .open: return c.isUnlocked
        case .locked: return !c.isUnlocked
        case .favorites: return c.favorite
        }
    }
    private var visible: [VaultCase] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = cases.filter { matches($0, filter) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
        switch sort {
        case .name: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .date: return list.sorted { $0.updatedAt > $1.updatedAt }
        case .size: return list.sorted { $0.bytes > $1.bytes }
        case .level:
            func rank(_ l: SecurityLevel) -> Int { l == .critical ? 0 : (l == .sensitive ? 1 : 2) }
            return list.sorted { rank($0.level) != rank($1.level) ? rank($0.level) < rank($1.level) : $0.name < $1.name }
        }
    }

    var body: some View {
        ZStack {
            if loaded && cases.isEmpty {
                emptyState
            } else {
                mainScroll
            }
        }
        .lkScreen()
        .task {
            await store.refreshCases()
            loaded = true
            await loadRecents()
            while !Task.isCancelled {
                let t = await store.chat.threads()
                if t != chatThreads { withAnimation(LKMotion.snappy) { chatThreads = t } }
                let n = InboxStore.pendingCount()
                if n != inboxCount { withAnimation(LKMotion.spring) { inboxCount = n } }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: store.unlockedCases.map(\.id)) { _, _ in Task { await loadRecents() } }
        .onChange(of: query) { _, q in scheduleSearch(q) }
        .confirmationDialog(tr(chooserTitle), isPresented: Binding(get: { chooser != nil }, set: { if !$0 { chooser = nil } }),
                            titleVisibility: .visible) {
            switch chooser {
            case .camera: ForEach(store.unlockedCases) { c in Button(c.name) { go(.camera, to: c) } }
            case .upload: ForEach(store.unlockedCases) { c in Button(c.name) { go(.upload, to: c) } }
            case .unlock: ForEach(store.cases.filter { !$0.isUnlocked }) { c in Button(c.name) { router.push(.unlock(caseID: c.id)) } }
            case nil: EmptyView()
            }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Переименовать кейс", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Название", text: $renameText)
            Button("Отмена", role: .cancel) {}
            Button("Сохранить") { commitRename() }
        }
    }

    private var chooserTitle: String {
        switch chooser {
        case .unlock: return "Какой кейс открыть?"
        default: return "В какой кейс?"
        }
    }

    // MARK: Основной экран

    private var mainScroll: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                greeting
                if searching { searchField }
                if searching && !query.isEmpty { fileResults }
                hero
                quickActions
                if !searching && inboxCount > 0 { inboxCard }
                if !searching { chatStrip }
                if !searching { securityPlate }
                if !searching && !recents.isEmpty { recentRibbon }
                if !store.unlockedCases.isEmpty {
                    LKHintBanner(id: "shake-lock", icon: "iphone.radiowaves.left.and.right", text: "Потрясите телефон, чтобы мгновенно закрыть все открытые кейсы.")
                }
                sectionHeader
                chips
                if !loaded && cases.isEmpty { skeleton }
                else if visible.isEmpty {
                    Text(query.isEmpty ? "Нет кейсов в этом фильтре" : "Ничего не найдено")
                        .font(.lk(14, .semibold)).foregroundStyle(Color.lkMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { i, c in caseCard(c).lkZoomSource(c.id).lkAppear(i) }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 124)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.refreshCases() }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                BrandMark().frame(width: 36)
                BrandWordmark(size: 22)
            }
            Spacer()
            HStack(spacing: 8) {
                LKIconButton(systemName: searching ? "xmark" : "magnifyingglass", label: searching ? "Закрыть поиск" : "Поиск") {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        searching.toggle()
                        if searching { searchFocused = true } else { query = ""; searchFocused = false }
                    }
                }
                Button { router.push(.chats) } label: {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.lkText)
                        .frame(width: 44, height: 44).background(Color.lkCard, in: Circle()).overlay(Circle().stroke(Color.lkBorder, lineWidth: 1))
                        .overlay(alignment: .topTrailing) {
                            if store.chatUnread > 0 {
                                Text("\(store.chatUnread)").font(.lk(10, .heavy)).foregroundStyle(Color.lkBg)
                                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18).background(Color.lkAccent, in: Capsule())
                                    .offset(x: 4, y: -4).transition(.scale.combined(with: .opacity))
                            }
                        }
                        .animation(LKMotion.spring, value: store.chatUnread)
                }
                .buttonStyle(LKPressStyle(scale: 0.9)).accessibilityLabel("Защищённый чат")
                LKIconButton(systemName: "person", label: "Аккаунт") { router.tab = .settings }
            }
        }
        .frame(height: 44)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.lkMuted)
            TextField("", text: $query, prompt: Text("Поиск по кейсам и файлам").foregroundColor(.lkMuted))
                .font(.lk(16, .medium)).focused($searchFocused).submitLabel(.search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.lkMuted) }
                    .accessibilityLabel("Очистить")
            }
        }
        .padding(.horizontal, 16).frame(height: 48)
        .lkCard(radius: 16, stroke: Color.white.opacity(0.1))
        .transition(.opacity)
    }

    // MARK: Приветствие, плашка защиты, недавние, поиск по файлам

    private var greeting: some View {
        let h = Calendar.current.component(.hour, from: Date())
        let g = h < 5 ? "Доброй ночи" : (h < 12 ? "Доброе утро" : (h < 18 ? "Добрый день" : "Добрый вечер"))
        return HStack(spacing: 6) {
            Text(g).font(.lk(14, .semibold)).foregroundStyle(Color.lkText2)
            if let n = store.account?.username { Text("@" + n).font(.lk(14, .bold)).foregroundStyle(Color.lkAccent) }
            Spacer()
        }
        .padding(.top, -4).padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }

    /// Файлы из «Поделиться в loKEY» ждут, пока их разложат по кейсам.
    private var inboxCard: some View {
        Button { router.push(.inbox) } label: {
            HStack(spacing: 14) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.lkAccent)
                    .frame(width: 46, height: 46).background(Color.lkAccent.opacity(0.14), in: Circle())
                    .symbolEffect(.bounce, value: inboxCount)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Входящие").font(.lk(16, .heavy)).tracking(-0.2)
                    Text(verbatim: trf("Ждут, пока вы выберете кейс: %lld", inboxCount)).font(.lk(13, .medium)).foregroundStyle(Color.lkText2).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.lkMuted)
            }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 66)
            .lkCard(radius: 22, stroke: Color.lkAccent.opacity(0.45))
        }
        .buttonStyle(LKPressStyle(scale: 0.98))
        .transition(.scale(scale: 0.95).combined(with: .opacity))
        .accessibilityLabel("Входящие")
    }

    /// Карточка «Сообщения» на главной: аватары собеседников, непрочитанные и последняя реплика.
    private var chatStrip: some View {
        Button { router.push(.chats) } label: {
            HStack(spacing: 14) {
                if chatThreads.isEmpty {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.lkAccent)
                        .frame(width: 46, height: 46).background(Color.lkAccent.opacity(0.14), in: Circle())
                } else {
                    ZStack(alignment: .leading) {
                        ForEach(Array(chatThreads.prefix(3).enumerated()), id: \.element.id) { i, t in
                            ChatAvatar(name: t.contact.name, size: 40).overlay(Circle().stroke(Color.lkCard, lineWidth: 2.5))
                                .offset(x: CGFloat(i) * 24).zIndex(Double(3 - i))
                        }
                    }
                    .frame(width: 40 + CGFloat(min(chatThreads.count, 3) - 1) * 24, height: 44, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Сообщения").font(.lk(16, .heavy)).tracking(-0.2)
                    Text(stripSubtitle).font(.lk(13, .medium)).foregroundStyle(store.chatUnread > 0 ? Color.lkText2 : Color.lkMuted).lineLimit(1)
                }
                Spacer(minLength: 4)
                if store.chatUnread > 0 {
                    Text("\(store.chatUnread)").font(.lk(12, .heavy)).foregroundStyle(Color.lkBg)
                        .padding(.horizontal, 8).frame(minWidth: 24, minHeight: 24).background(Color.lkAccent, in: Capsule())
                        .shadow(color: Color.lkAccent.opacity(0.5), radius: 5).transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.lkMuted)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 66)
            .lkCard(radius: 22, stroke: store.chatUnread > 0 ? Color.lkAccent.opacity(0.45) : .lkBorderSoft)
            .animation(LKMotion.spring, value: store.chatUnread)
        }
        .buttonStyle(LKPressStyle(scale: 0.98))
        .accessibilityLabel("Сообщения")
        .accessibilityIdentifier("chatStripButton")
    }

    private var stripSubtitle: String {
        if let t = chatThreads.first(where: { $0.unread > 0 }) ?? chatThreads.first, let l = t.last {
            let body = l.deleted ? "Сообщение удалено" : (l.sticker != nil ? "Стикер" : (l.attachment.map { "📎 " + $0.name } ?? l.text))
            return t.contact.name + ": " + body
        }
        return chatThreads.isEmpty ? "Защищённый чат. Добавьте первого собеседника" : "Защищённый чат"
    }

    @ViewBuilder private var securityPlate: some View {
        let score = store.securityScore
        if score < 1 && !plateHidden {
            let todo = store.securityItems.filter { !$0.done }.count
            Button { router.tab = .settings } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.1), lineWidth: 4)
                        Circle().trim(from: 0, to: score).stroke(Color.lkWarn, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                        Image(systemName: "shield.lefthalf.filled").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.lkWarn)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Усильте защиту").font(.lk(15, .heavy))
                        Text(verbatim: String(format: tr("Осталось шагов: %lld"), todo)).font(.lk(12, .medium)).foregroundStyle(Color.lkMuted)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.lkMuted)
                    Button { withAnimation(LKMotion.spring) { plateHidden = true } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.lkMuted).frame(width: 32, height: 44)
                    }
                    .accessibilityLabel("Скрыть")
                }
                .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 8)
                .background(Color.lkWarn.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.lkWarn.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(LKPressStyle(scale: 0.98))
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
    }

    private var recentRibbon: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Недавние файлы").font(.lk(17, .heavy)).tracking(-0.3)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(recents.enumerated()), id: \.element.file.id) { i, r in
                        Button { router.push(.file(fileID: r.file.id, caseID: r.file.caseID)) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: r.file.kind.systemName).font(.system(size: 16, weight: .semibold)).foregroundStyle(r.file.kind.tint)
                                    .frame(width: 38, height: 38)
                                    .background(r.file.kind.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Spacer(minLength: 0)
                                Text(r.file.name).font(.lk(13, .bold)).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(Color.lkText)
                                Text(r.caseName).font(.lk(11, .semibold)).foregroundStyle(Color.lkMuted).lineLimit(1)
                            }
                            .padding(12).frame(width: 150, height: 130, alignment: .leading)
                            .lkCard(radius: 20)
                        }
                        .buttonStyle(LKPressStyle(scale: 0.96))
                        .lkAppear(i)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var fileResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ФАЙЛЫ В ОТКРЫТЫХ КЕЙСАХ").font(.lk(11, .heavy)).tracking(1).foregroundStyle(Color.lkMuted)
            if fileHits.isEmpty {
                Text(store.unlockedCases.isEmpty ? "Откройте кейс, чтобы искать по его файлам." : "Файлов с таким названием нет.")
                    .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(fileHits.prefix(8).enumerated()), id: \.element.file.id) { i, r in
                        Button { router.push(.file(fileID: r.file.id, caseID: r.file.caseID)) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: r.file.kind.systemName).font(.system(size: 14, weight: .semibold)).foregroundStyle(r.file.kind.tint)
                                    .frame(width: 34, height: 34).background(r.file.kind.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.file.name).font(.lk(14, .bold)).foregroundStyle(Color.lkText).lineLimit(1)
                                    Text(r.caseName).font(.lk(12, .medium)).foregroundStyle(Color.lkMuted)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if i < min(fileHits.count, 8) - 1 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 46) }
                    }
                }
                .padding(.horizontal, 12).lkCard(radius: 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func loadRecents() async {
        var out: [(VaultFile, String)] = []
        for c in store.unlockedCases {
            if let fs = try? await store.repo.listFiles(caseID: c.id) { out += fs.map { ($0, c.name) } }
        }
        let top = out.sorted { $0.0.createdAt > $1.0.createdAt }.prefix(8)
        withAnimation(LKMotion.spring) { recents = top.map { (file: $0.0, caseName: $0.1) } }
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { fileHits = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            var out: [(VaultFile, String)] = []
            for c in store.unlockedCases {
                if let fs = try? await store.repo.listFiles(caseID: c.id) {
                    out += fs.filter { $0.name.localizedCaseInsensitiveContains(t) || ($0.note ?? "").localizedCaseInsensitiveContains(t) }.map { ($0, c.name) }
                }
            }
            guard !Task.isCancelled else { return }
            withAnimation(LKMotion.snappy) { fileHits = out.map { (file: $0.0, caseName: $0.1) } }
        }
    }

    // MARK: Hero

    private var hero: some View {
        let unlocked = store.unlockedCases.count
        let ink = Color.lkBg
        return ZStack(alignment: .bottomTrailing) {
            BrandMark(stem: ink, ring: ink).frame(width: 300).opacity(0.13).offset(x: 70, y: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label { Text("Защита активна · AES-256") } icon: { Image(systemName: "checkmark.shield").symbolEffect(.pulse, options: .repeating) }
                        .font(.lk(13, .bold)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    AutoLockPill(secondsLeft: store.secondsUntilAutoLock, total: max(store.autoLockMinutes, 1) * 60)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(unlocked)").font(.lk(68, .heavy)).tracking(-3.4)
                                .contentTransition(.numericText()).animation(LKMotion.spring, value: unlocked)
                            Text(verbatim: trf("из %lld открыто", cases.count)).font(.lk(18, .bold)).opacity(0.72)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        Text(heroSub).font(.lk(14, .semibold)).opacity(0.78)
                    }
                    Spacer(minLength: 0)
                    heroButton(unlocked: unlocked)
                }
                storageBar
            }
            .padding(18)
        }
        .foregroundStyle(ink)
        .background(Color.lkAccent, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var heroSub: String {
        let n = store.unlockedCases.count
        if cases.isEmpty { return "Создайте первый кейс" }
        if n == 0 { return "Все кейсы защищены" }
        return n == cases.count ? "Все кейсы открыты" : "Остальные защищены"
    }

    @ViewBuilder private func heroButton(unlocked: Int) -> some View {
        if unlocked > 0 {
            Button { Task { await store.lockAll() } } label: {
                Label("Закрыть все", systemImage: "lock").font(.lk(14, .bold))
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(Color.lkBg, in: Capsule()).foregroundStyle(Color.lkText)
            }
        } else if !cases.isEmpty {
            Button { chooseUnlock() } label: {
                Label("Face ID", systemImage: "faceid").font(.lk(14, .bold))
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(Color.lkBg, in: Capsule()).foregroundStyle(Color.lkText)
            }
            .accessibilityLabel("Открыть кейс")
        }
    }

    @State private var barIn = false

    private var storageBar: some View {
        let s = store.storage
        let limit = Double(max(s?.limitBytes ?? AppConfig.storageLimitBytes, 1))
        let opacities: [Double] = [1, 0.72, 0.55, 0.4, 0.3]
        return VStack(spacing: 8) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.lkBg.opacity(0.14))
                    HStack(spacing: 2) {
                        ForEach(Array((s?.perCase ?? []).filter { $0.bytes > 0 }.enumerated()), id: \.element.id) { i, seg in
                            Rectangle().fill(Color.lkBg.opacity(opacities[min(i, opacities.count - 1)]))
                                .frame(width: max(3, g.size.width * Double(seg.bytes) / limit))
                        }
                    }
                    .clipShape(Capsule())
                    .scaleEffect(x: barIn ? 1 : 0.001, anchor: .leading)
                }
            }
            .frame(height: 8)
            .onAppear { withAnimation(.easeOut(duration: 0.9).delay(0.3)) { barIn = true } }
            HStack {
                Text(verbatim: trf("%@ из %@", LKFormat.bytes(s?.usedBytes ?? 0), LKFormat.bytes(Int64(limit))))
                Spacer()
                Text(verbatim: trf("%@ свободно", LKFormat.bytes(s?.freeBytes ?? Int64(limit)))).opacity(0.78)
            }
            .font(.lkMono(12, .bold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trf("Занято %@ из %@", LKFormat.bytes(s?.usedBytes ?? 0), LKFormat.bytes(Int64(limit))))
    }

    // MARK: Быстрые действия

    private var quickActions: some View {
        HStack(spacing: 10) {
            quick("camera", "Камера") { quickTarget(.camera) }
            quick("square.and.arrow.up", "Загрузить") { quickTarget(.upload) }
            quick("folder.badge.plus", "Новый кейс") { router.cover = .newCase }
        }
    }

    private func quick(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 21, weight: .semibold)).foregroundStyle(Color.lkAccent)
                Text(title).font(.lk(13, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 76)
            .lkCard(radius: 20)
        }
        .buttonStyle(.plain)
    }

    private func quickTarget(_ kind: CaseIntent) {
        let open = store.unlockedCases
        switch open.count {
        case 0: store.showToast("Сначала откройте кейс", isError: true)
        case 1: go(kind, to: open[0])
        default: chooser = kind == .camera ? .camera : .upload
        }
    }

    private func go(_ kind: CaseIntent, to c: VaultCase) {
        router.pendingIntent = kind
        router.push(.vaultCase(caseID: c.id))
    }

    private func chooseUnlock() {
        let locked = cases.filter { !$0.isUnlocked }
        if locked.count == 1 { router.push(.unlock(caseID: locked[0].id)) }
        else if locked.count > 1 { chooser = .unlock }
    }

    // MARK: Список

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            (Text("Кейсы ") + Text("\(cases.count)").foregroundColor(.lkMuted))
                .font(.lk(22, .heavy)).tracking(-0.4)
            Spacer()
            Menu {
                Picker("Сортировка", selection: $sort) {
                    ForEach(CaseSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Text("Сортировка").font(.lk(14, .semibold)).foregroundStyle(Color.lkAccent).frame(minHeight: 44)
            }
            .accessibilityHint(trf("Сейчас: %@", tr(sort.rawValue)))
        }
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(CaseFilter.allCases, id: \.self) { f in
                    LKChip(title: f.rawValue, count: count(f), selected: filter == f) { filter = f }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -16)
    }

    private func caseCard(_ c: VaultCase) -> some View {
        let tint = c.level.tint
        return Button {
            c.isUnlocked ? router.push(.vaultCase(caseID: c.id)) : router.push(.unlock(caseID: c.id))
        } label: {
            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    Image(systemName: c.icon.systemName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(c.isUnlocked ? Color.lkAccent : Color.lkText2)
                        .frame(width: 42, height: 42)
                        .background((c.isUnlocked ? Color.lkAccent : Color.white).opacity(c.isUnlocked ? 0.14 : 0.06),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Spacer(minLength: 4)
                    if c.isUnlocked {
                        Label(tr(store.secondsUntilAutoLock.map(LKFormat.clock) ?? "открыт"), systemImage: "lock.open")
                            .font(.lkMono(12, .bold)).foregroundStyle(Color.lkAccent)
                            .padding(.horizontal, 9).frame(height: 26)
                            .background(Color.lkAccent.opacity(0.14), in: Capsule())
                    } else {
                        Image(systemName: "lock.fill").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.lkMuted)
                            .frame(width: 30, height: 30).background(Color.lkRaised, in: Circle())
                            .accessibilityLabel("Закрыт")
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    LevelTag(level: c.level)
                    Text(c.name).font(.lk(17, .bold)).lineLimit(1).foregroundStyle(Color.lkText)
                    Text(verbatim: c.isUnlocked ? "\(c.fileCount) \(tr(filesWord(c.fileCount))) · \(LKFormat.bytes(c.bytes))"
                         : trf("Закрыт · %@", LKFormat.bytes(c.bytes)))
                        .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 156, maxHeight: 156, alignment: .topLeading)
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
                    .fill(tint).frame(height: 3).padding(.horizontal, 14)
            }
            .lkCard(radius: 24, stroke: c.isUnlocked ? Color.lkAccent.opacity(0.3) : Color.lkBorderSoft)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(LKPressStyle())
        .contextMenu {
            Button { renameText = c.name; renameTarget = c } label: { Label("Переименовать", systemImage: "pencil") }
            Button { toggleFavorite(c) } label: {
                Label(tr(c.favorite ? "Убрать из избранного" : "В избранное"), systemImage: c.favorite ? "star.slash" : "star")
            }
            if c.isUnlocked {
                Button { Task { await store.lock(caseID: c.id) } } label: { Label("Закрыть", systemImage: "lock") }
            } else {
                Button { router.push(.unlock(caseID: c.id)) } label: { Label("Открыть", systemImage: "lock.open") }
            }
            Button(role: .destructive) { router.sheet = .deleteCase(caseID: c.id) } label: { Label("Удалить", systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(c.name), \(c.isUnlocked ? "открыт" : "закрыт"), \(c.level.title.lowercased())")
    }

    private func filesWord(_ n: Int) -> String {
        let a = n % 100, b = n % 10
        if a >= 11 && a <= 14 { return "файлов" }
        if b == 1 { return "файл" }
        if b >= 2 && b <= 4 { return "файла" }
        return "файлов"
    }

    private func toggleFavorite(_ c: VaultCase) {
        Task {
            do {
                _ = try await store.repo.updateCase(id: c.id, name: nil, icon: nil, level: nil, favorite: !c.favorite)
                await store.refreshCases()
            } catch { store.showError(error) }
        }
    }

    private func commitRename() {
        guard let c = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        renameTarget = nil
        guard !name.isEmpty, name != c.name else { return }
        Task {
            do {
                _ = try await store.repo.updateCase(id: c.id, name: name, icon: nil, level: nil, favorite: nil)
                await store.refreshCases()
            } catch { store.showError(error) }
        }
    }

    // MARK: Скелетон

    private var skeleton: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.lkCard)
                    .frame(height: 156)
                    .lkShimmer()
            }
        }
        .accessibilityLabel("Загрузка кейсов")
    }

    // MARK: Пустое состояние

    private var emptyState: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 10) { BrandMark().frame(width: 36); BrandWordmark(size: 22) }
                Spacer()
                LKIconButton(systemName: "person", label: "Аккаунт") { router.tab = .settings }
            }
            .frame(height: 44).padding(.horizontal, 16).padding(.top, 8)
            ScrollView {
                VStack(spacing: 0) {
                    ZStack {
                        Circle().strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4])).frame(width: 270, height: 270)
                        Circle().strokeBorder(Color.lkAccent.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4])).frame(width: 190, height: 190)
                        BrandMark().frame(width: 84)
                            .frame(width: 150, height: 150)
                            .lkCard(radius: 44, stroke: Color.lkBorder)
                        Circle().fill(Color.lkAccent).frame(width: 10, height: 10).offset(x: 70, y: -100)
                        Circle().fill(Color.lkPurple).frame(width: 6, height: 6).offset(x: -90, y: 90)
                        Circle().fill(Color.lkWarn).frame(width: 6, height: 6).offset(x: 110, y: 60)
                    }
                    .frame(height: 300).padding(.top, 24).accessibilityHidden(true)
                    VStack(spacing: 10) {
                        Text("Здесь пока пусто").font(.lk(30, .heavy)).tracking(-0.9).multilineTextAlignment(.center)
                        Text("Создайте первый кейс, и у него появится личный ключ. Всё остальное мы зашифруем сами.")
                            .font(.lk(16, .medium)).foregroundStyle(Color(hex: 0xA9B0B8)).lineSpacing(3)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 28)
                    VStack(spacing: 12) {
                        Button { router.cover = .newCase } label: {
                            Label("Создать первый кейс", systemImage: "plus")
                        }
                        .buttonStyle(.lkPrimary)
                        Button { router.cover = .newCase } label: {
                            Label("Импортировать файл .key", systemImage: "doc.badge.arrow.up")
                        }
                        .buttonStyle(.lkSecondary)
                    }
                    .padding(.horizontal, 16).padding(.top, 32).padding(.bottom, 124)
                }
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.refreshCases() }
        }
    }
}
