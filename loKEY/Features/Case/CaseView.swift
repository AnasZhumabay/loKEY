import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct CaseView: View {
    let caseID: String

    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Extra: String, CaseIterable { case all = "Все", fav = "Избранное", offline = "Офлайн" }

    @State private var files: [VaultFile] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var search = ""
    @State private var filter: Extra = .all
    @State private var category: CaseCategory = .all
    @State private var showScanner = false
    @State private var rev: Double = 1
    @State private var revealStarted = false
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var confirmTrash = false
    @State private var showMove = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var exportDoc: KeyFileDocument?
    @State private var exportName = "key"
    @State private var showExporter = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showNote = false
    @State private var showSecret = false
    @State private var showUploadChoices = false
    @State private var upload: UploadModel?
    @State private var showShareCase = false
    @State private var sharedMembers = 0
    @FocusState private var searchFocused: Bool
    @State private var heroPulse = false
    @State private var highlighted = Set<String>()
    @State private var integrityPop = false

    private var vaultCase: VaultCase? { store.vaultCase(caseID) }

    private var shown: [VaultFile] {
        files.filter { f in
            if category != .all, CaseCategory.of(f.kind) != category { return false }
            switch filter {
            case .all: break
            case .fav: if !f.favorite { return false }
            case .offline: if !f.offline { return false }
            }
            let q = search.trimmingCharacters(in: .whitespaces)
            return q.isEmpty || f.name.localizedCaseInsensitiveContains(q) || (f.note ?? "").localizedCaseInsensitiveContains(q)
                || (f.ocr ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private var counts: [CaseCategory: Int] {
        var c: [CaseCategory: Int] = [.all: files.count]
        for f in files { c[CaseCategory.of(f.kind), default: 0] += 1 }
        return c
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        hero
                        if !files.isEmpty {
                            LKHintBanner(id: "case-longpress", icon: "hand.tap", text: "Зажмите файл, чтобы открыть меню: избранное, выбор, корзина.")
                        }
                        LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                            Section {
                                content
                            } header: {
                                stickyBar.padding(.horizontal, -20)
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 130)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            Group { if selecting { selectBar } else { floating } }
                .animation(LKMotion.spring, value: selecting)
        }
        .lkScreen()
        .task {
            await reload()
            startReveal()
            consumeIntent()
        }
        .onChange(of: vaultCase?.isUnlocked) { _, v in if v == false { router.popToRoot() } }
        .onChange(of: photoItems) { _, items in if !items.isEmpty { loadPhotos(items) } }
        .alert("Переименовать кейс", isPresented: $renaming) {
            TextField("Название", text: $newName)
            Button("Сохранить") { rename() }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Переместить в корзину?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button(trf("В корзину (%lld)", selected.count), role: .destructive) { trashSelected() }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Файлы можно восстановить в течение 30 дней.") }
        .confirmationDialog("Загрузить", isPresented: $showUploadChoices) { uploadButtons }
        .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: .data, defaultFilename: exportName) { r in
            exportDoc = nil
            if case .failure(let e) = r { store.showError(e) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in importFiles(r) }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { d in
                startUpload([UploadItem(name: "Снимок \(Self.stamp()).jpg", kind: .jpg, data: d, size: Int64(d.count))])
            }.ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showScanner) {
            ScannerFlow(caseID: caseID, caseName: vaultCase?.name ?? "Кейс") { Task { await reload(); await store.refreshCases() } }
        }
        .sheet(isPresented: $showNote) {
            NoteSheet { name, text in
                let d = Data(text.utf8)
                startUpload([UploadItem(name: name, kind: .note, data: d, size: Int64(d.count))])
            }
        }
        .sheet(isPresented: $showSecret) {
            SecretSheet { kind, name, body in
                let d = Data(body.utf8)
                startUpload([UploadItem(name: name, kind: kind, data: d, size: Int64(d.count))])
            }
        }
        .sheet(isPresented: $showMove) {
            MoveSheet(currentCaseID: caseID, fileIDs: Array(selected)) {
                selected = []; selecting = false; await reload()
            }
        }
        .sheet(isPresented: $showShareCase, onDismiss: { Task { sharedMembers = ((try? await store.sharedCases.members(caseId: caseID)) ?? []).filter { $0.status != .revoked }.count } }) {
            ShareCaseSheet(caseId: caseID).environment(store)
        }
        .task { sharedMembers = ((try? await store.sharedCases.members(caseId: caseID)) ?? []).filter { $0.status != .revoked }.count }
        .sheet(item: $upload) { m in
            UploadSheet(model: m) { upload = nil; Task { await reload() } }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            LKIconButton(systemName: "chevron.left", label: "Назад") { router.pop() }
            Spacer()
            if selecting {
                Button("Готово") { selecting = false; selected = [] }
                    .font(.lk(15, .bold)).foregroundStyle(Color.lkAccent).frame(minHeight: 44)
            } else {
                Button { Task { await store.lock(caseID: caseID); router.popToRoot() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.system(size: 12))
                        Text(verbatim: trf("Закрыть · %@", store.secondsUntilAutoLock.map(LKFormat.clock) ?? "—")).font(.lkMono(13, .semibold)).contentTransition(.numericText(countsDown: true))
                    }
                    .foregroundStyle((store.secondsUntilAutoLock ?? 99) <= 30 ? Color.lkWarn : Color.lkAccent)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(Color.lkCard, in: Capsule()).overlay(Capsule().stroke(Color.lkBorder, lineWidth: 1))
                }
                .buttonStyle(LKPressStyle(scale: 0.94))
                .accessibilityLabel("Закрыть кейс")
                Menu {
                    Button { newName = vaultCase?.name ?? ""; renaming = true } label: { Label("Переименовать", systemImage: "pencil") }
                    Button { copyKey() } label: { Label("Скопировать ключ", systemImage: "doc.on.doc") }
                    Button { saveKey() } label: { Label("Сохранить .key", systemImage: "square.and.arrow.down") }
                    Button { toggleFavCase() } label: {
                        Label(tr(vaultCase?.favorite == true ? "Убрать из избранного" : "В избранное"), systemImage: "star")
                    }
                    Button { showShareCase = true } label: { Label("Поделиться кейсом", systemImage: "person.2") }
                    Button { selecting = true } label: { Label("Выбрать", systemImage: "checkmark.circle") }
                    Button { router.push(.trash) } label: { Label("Корзина", systemImage: "trash") }
                    Button(role: .destructive) { router.sheet = .deleteCase(caseID: caseID) } label: { Label("Удалить кейс", systemImage: "trash.slash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44).background(Color.lkCard, in: Circle())
                        .overlay(Circle().stroke(Color.lkBorder, lineWidth: 1))
                }
                .accessibilityLabel("Меню кейса")
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)
    }

    private var hero: some View {
        let tint = vaultCase?.level.tint ?? Color.lkAccent
        let left = store.secondsUntilAutoLock
        let total = max(store.autoLockMinutes, 1) * 60
        let warn = (left ?? 99) <= 30
        let barColor: Color = warn ? .lkWarn : tint
        let fraction = left.map { max(0, min(1, Double($0) / Double(total))) } ?? 0
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(tint.opacity(0.35), lineWidth: 1.5).frame(width: 66, height: 66)
                        .scaleEffect(heroPulse ? 1.35 : 1).opacity(heroPulse ? 0 : 0.9)
                    Image(systemName: vaultCase?.icon.systemName ?? "key").font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(tint).symbolEffect(.bounce, value: heroPulse)
                        .frame(width: 66, height: 66)
                        .background(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(tint.opacity(0.4), lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        if let l = vaultCase?.level { LevelTag(level: l) }
                        if sharedMembers > 1 {
                            Label("\(sharedMembers) участника", systemImage: "person.2.fill").font(.lk(11, .bold)).foregroundStyle(Color.lkAccent)
                                .padding(.horizontal, 8).padding(.vertical, 4).background(Color.lkAccent.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(vaultCase?.name ?? "Кейс").font(.lk(28, .heavy)).tracking(-0.7).lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                statTile("\(files.count)", Self.plural(files.count), "doc.on.doc", tint)
                statTile(LKFormat.bytes(vaultCase?.bytes ?? 0), "в шифртексте", "externaldrive", tint)
                statTile("OK", "целостность", "checkmark.shield.fill", .lkAccent, pop: integrityPop)
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 7) {
                HStack {
                    Label("Автоблокировка", systemImage: "timer").font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted)
                    Spacer()
                    Text(left.map(LKFormat.clock) ?? "—").font(.lkMono(13, .bold)).foregroundStyle(barColor)
                        .contentTransition(.numericText(countsDown: true))
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(LinearGradient(colors: [barColor.opacity(0.6), barColor], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, g.size.width * fraction))
                            .shadow(color: barColor.opacity(0.6), radius: warn ? 6 : 3)
                    }
                }
                .frame(height: 6)
                .animation(.linear(duration: 1), value: left)
                .animation(.easeOut(duration: 0.3), value: warn)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.16), Color.lkCard, Color.lkCard], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(tint.opacity(0.22), lineWidth: 1))
        .visualEffect { c, proxy in
            let y = proxy.frame(in: .scrollView).minY
            return c.offset(y: y < 0 ? -y * 0.25 : 0).scaleEffect(y < 0 ? max(0.94, 1 + y / 1200) : 1, anchor: .top)
                .opacity(y < 0 ? max(0.3, 1 + y / 400) : 1)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { heroPulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { integrityPop = true }
        }
    }

    private func statTile(_ value: String, _ label: String, _ icon: String, _ tint: Color, pop: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .symbolEffect(.bounce, value: pop)
            Text(value).font(.lk(18, .heavy)).tracking(-0.3).lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label).font(.lk(11, .semibold)).foregroundStyle(Color.lkMuted).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.05), lineWidth: 1))
        .animation(LKMotion.spring, value: value)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(searchFocused ? Color.lkAccent : Color.lkMuted)
                .scaleEffect(searchFocused ? 1.12 : 1)
            TextField("Поиск в кейсе", text: $search).font(.lk(16, .medium)).autocorrectionDisabled().focused($searchFocused)
                .onChange(of: search) { _, _ in store.noteActivity() }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.lkMuted).frame(width: 44, height: 44) }
                    .accessibilityLabel("Очистить")
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 48)
        .background(Color.lkCard, in: Capsule())
        .overlay(Capsule().stroke(searchFocused ? Color.lkAccent.opacity(0.7) : Color.white.opacity(0.1), lineWidth: searchFocused ? 1.5 : 1))
        .shadow(color: Color.lkAccent.opacity(searchFocused ? 0.25 : 0), radius: 10)
        .animation(LKMotion.snappy, value: searchFocused)
    }

    // MARK: Закреплённая панель: поиск, фильтр, разделы

    private var stickyBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                searchField
                Menu {
                    Picker("Показывать", selection: $filter) {
                        ForEach(Extra.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(filter == .all ? Color.lkText2 : Color.lkAccent)
                        .frame(width: 48, height: 48).background(Color.lkCard, in: Circle()).overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
                }
                .accessibilityLabel("Фильтр")
            }
            .padding(.horizontal, 20)
            CategoryBar(counts: counts, selection: $category)
        }
        .padding(.vertical, 8)
        .background(Color.lkBg.opacity(0.94))
    }

    // MARK: Содержимое

    @ViewBuilder private var content: some View {
        if loading && files.isEmpty {
            LKSkeletonRows(count: 4, height: 72).padding(.horizontal, -16)
        } else if let loadError, files.isEmpty {
            VStack(spacing: 12) {
                Text(loadError).font(.lk(15, .medium)).foregroundStyle(Color.lkText2).multilineTextAlignment(.center)
                Button("Повторить") { Task { await reload() } }.buttonStyle(.lkSecondary).frame(maxWidth: 200)
            }.frame(maxWidth: .infinity).padding(.top, 30)
        } else if shown.isEmpty {
            emptyState
        } else if category == .all {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Array(CaseCategory.allCases.filter { $0 != .all }.enumerated()), id: \.element.id) { i, cat in
                    let items = shown.filter { CaseCategory.of($0.kind) == cat }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Button { withAnimation(LKMotion.snappy) { category = cat }; Haptics.soft() } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: cat.icon).font(.system(size: 13, weight: .bold)).foregroundStyle(cat.tint)
                                    Text(cat.rawValue).font(.lk(17, .heavy)).tracking(-0.3).foregroundStyle(Color.lkText)
                                    Text("\(items.count)").font(.lkMono(12, .bold)).foregroundStyle(Color.lkMuted)
                                    Spacer()
                                    if items.count > limit(cat) { Text("Все").font(.lk(13, .bold)).foregroundStyle(cat.tint); Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(cat.tint) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            block(cat, Array(items.prefix(limit(cat))))
                        }
                        .lkAppear(i)
                    }
                }
            }
        } else {
            block(category, shown)
        }
    }

    private func limit(_ c: CaseCategory) -> Int {
        switch c { case .photos: return 6; case .videos: return 2; case .notes: return 2; default: return 3 }
    }

    @ViewBuilder private func block(_ cat: CaseCategory, _ items: [VaultFile]) -> some View {
        switch cat {
        case .photos:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(items) { f in tappable(f) { PhotoThumb(file: f) } }
            }
        case .videos:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                ForEach(items) { f in tappable(f) { VideoCard(file: f) } }
            }
        case .notes:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 2), spacing: 10) {
                ForEach(items) { f in tappable(f) { NoteCard(file: f) } }
            }
        case .files, .secrets, .all:
            VStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, f in row(f).lkAppear(i) }
            }
        }
    }

    /// Ячейка с общим поведением: нажатие / выбор / меню.
    private func tappable<C: View>(_ f: VaultFile, @ViewBuilder _ content: () -> C) -> some View {
        let isSel = selected.contains(f.id)
        return Button { activate(f) } label: {
            content().overlay(alignment: .topLeading) {
                if selecting {
                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle").font(.system(size: 22))
                        .foregroundStyle(isSel ? Color.lkAccent : Color.white.opacity(0.9)).shadow(radius: 3).padding(8)
                        .symbolEffect(.bounce, value: isSel)
                }
            }
            .overlay { if isSel { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.lkAccent, lineWidth: 3) } }
        }
        .buttonStyle(LKPressStyle(scale: 0.96))
        .contextMenu {
            Button { toggleFav(f) } label: { Label(tr(f.favorite ? "Убрать из избранного" : "В избранное"), systemImage: "star") }
            Button { withAnimation(LKMotion.snappy) { selecting = true; selected = [f.id] }; Haptics.soft() } label: { Label("Выбрать", systemImage: "checkmark.circle") }
            Button(role: .destructive) { trashOne(f) } label: { Label("В корзину", systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
    }

    private func activate(_ f: VaultFile) {
        store.noteActivity()
        if selecting {
            withAnimation(LKMotion.snappy) { if selected.contains(f.id) { selected.remove(f.id) } else { selected.insert(f.id) } }
            Haptics.soft()
        } else { router.push(.file(fileID: f.id, caseID: caseID)) }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.lkAccent.opacity(0.08)).frame(width: 110, height: 110)
                Image(systemName: files.isEmpty ? "tray.and.arrow.down" : "magnifyingglass")
                    .font(.system(size: 38, weight: .light)).foregroundStyle(Color.lkAccent)
                    .phaseAnimator(reduceMotion ? [0.0] : [0.0, -6.0]) { v, y in v.offset(y: y) } animation: { _ in .easeInOut(duration: 1.4) }
            }
            Text(files.isEmpty ? "В кейсе пока нет файлов" : (search.isEmpty && filter == .all ? category.emptyTitle : "Ничего не найдено")).font(.lk(18, .heavy))
            Text(files.isEmpty ? "Снимите документ или загрузите файл: он сразу зашифруется на телефоне." : "Попробуйте другой запрос или фильтр.")
                .font(.lk(14, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center).padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity).padding(.top, 36)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private func row(_ f: VaultFile) -> some View {
        let isSel = selected.contains(f.id)
        let hot = highlighted.contains(f.id)
        let tint = f.kind.tint
        return Button {
            store.noteActivity()
            if selecting { withAnimation(LKMotion.snappy) { if isSel { selected.remove(f.id) } else { selected.insert(f.id) } }; Haptics.soft() }
            else { router.push(.file(fileID: f.id, caseID: caseID)) }
        } label: {
            HStack(spacing: 12) {
                if selecting {
                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle").font(.system(size: 22))
                        .foregroundStyle(isSel ? Color.lkAccent : Color.lkMuted)
                        .symbolEffect(.bounce, value: isSel)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 2) {
                    Image(systemName: f.kind.systemName).font(.system(size: 18, weight: .semibold))
                    Text(f.kind.label).font(.lkMono(9, .bold))
                }
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.07)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(tint.opacity(0.25), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(scramble(f.name))
                        .font(rev < 1 ? .lkMono(15, .semibold) : .lk(16, .bold))
                        .foregroundStyle(rev < 1 ? Color.lkAccent : Color.lkText).lineLimit(1)
                    Text(meta(f)).font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).lineLimit(1)
                    if let n = f.note, !n.isEmpty {
                        Text(n).font(.lk(12, .medium)).italic().foregroundStyle(Color.lkText2.opacity(0.8)).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if f.offline { Image(systemName: "arrow.down.circle.fill").font(.system(size: 14)).foregroundStyle(Color.lkAccentDim) }
                if !selecting {
                    Button { toggleFav(f) } label: {
                        Image(systemName: f.favorite ? "star.fill" : "star").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(f.favorite ? Color.lkAccent : Color.lkMuted.opacity(0.6))
                            .symbolEffect(.bounce, value: f.favorite)
                            .frame(width: 40, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(LKPressStyle(scale: 0.8))
                    .accessibilityLabel(tr(f.favorite ? "Убрать из избранного" : "В избранное"))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 76)
            .background(isSel ? Color.lkAccent.opacity(0.1) : Color.lkCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(hot ? Color.lkAccent : (isSel ? Color.lkAccent.opacity(0.6) : Color.lkBorderSoft), lineWidth: hot || isSel ? 1.5 : 1))
            .shadow(color: Color.lkAccent.opacity(hot ? 0.45 : 0), radius: hot ? 14 : 0)
            .animation(.easeOut(duration: 0.6), value: hot)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(LKPressStyle(scale: 0.975))
        .animation(LKMotion.snappy, value: selecting)
        .contextMenu {
            Button { toggleFav(f) } label: { Label(tr(f.favorite ? "Убрать из избранного" : "В избранное"), systemImage: "star") }
            Button { withAnimation(LKMotion.snappy) { selecting = true; selected = [f.id] }; Haptics.soft() } label: { Label("Выбрать", systemImage: "checkmark.circle") }
            Button(role: .destructive) { trashOne(f) } label: { Label("В корзину", systemImage: "trash") }
        }
        .accessibilityLabel("\(f.name), \(f.kind.label)")
    }

    private func toggleFav(_ f: VaultFile) {
        store.noteActivity()
        Task {
            do {
                _ = try await store.repo.updateFile(id: f.id, name: nil, note: nil, favorite: !f.favorite, offline: nil)
                Haptics.soft()
                if let i = files.firstIndex(where: { $0.id == f.id }) { files[i].favorite.toggle() }
            } catch { store.showError(error) }
        }
    }

    private func trashOne(_ f: VaultFile) {
        store.noteActivity()
        Task {
            do {
                try await store.repo.trashFiles(ids: [f.id])
                Haptics.warning()
                withAnimation(LKMotion.spring) { files.removeAll { $0.id == f.id } }
                await store.refreshCases()
                store.showToast("Файл в корзине")
            } catch { store.showError(error) }
        }
    }

    private func meta(_ f: VaultFile) -> String {
        if let n = f.note, !n.isEmpty { return "\(n) · \(LKFormat.bytes(f.bytes))" }
        let d = DateFormatter(); d.locale = LKBundle.uiLocale; d.dateFormat = "d MMM"
        return "\(LKFormat.bytes(f.bytes)) · \(d.string(from: f.createdAt))"
    }

    private func scramble(_ s: String) -> String {
        if rev >= 1 { return s }
        let glyphs = Array("ABCDEF0123456789#%&@")
        let k = Int(rev * Double(s.count))
        return String(s.enumerated().map { i, c in (c == " " || i < k) ? c : glyphs.randomElement() ?? c })
    }

    private func startReveal() {
        guard !revealStarted else { return }
        revealStarted = true
        guard !reduceMotion, !files.isEmpty else { rev = 1; return }
        rev = 0
        Task {
            while rev < 1 {
                try? await Task.sleep(for: .milliseconds(45))
                rev = min(1, rev + 0.05)
            }
        }
    }

    // MARK: Bottom

    private var floating: some View {
        HStack(spacing: 12) {
            Button { openCamera() } label: { Label("Снять", systemImage: "camera") }
                .buttonStyle(LKSecondaryButtonStyle()).background(Color.lkCard, in: Capsule())
            Menu { uploadButtons } label: {
                Label("Загрузить", systemImage: "arrow.up.doc")
                    .font(.lk(17, .heavy)).foregroundStyle(Color.lkBg)
                    .frame(maxWidth: .infinity, minHeight: 56).background(Color.lkAccent, in: Capsule())
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 12).padding(.top, 28)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, Color.lkBg.opacity(0.9), Color.lkBg], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder private var uploadButtons: some View {
        Button { showScanner = true } label: { Label("Сканировать документ", systemImage: "doc.viewfinder") }
        Button { showFileImporter = true } label: { Label("Файлы", systemImage: "folder") }
        Button { showPhotoPicker = true } label: { Label("Фото", systemImage: "photo") }
        Button { showNote = true } label: { Label("Заметка", systemImage: "note.text") }
        Button { showSecret = true } label: { Label("Пароль / карта", systemImage: "key") }
    }

    private var selectBar: some View {
        VStack(spacing: 10) {
            Text(verbatim: trf("Выбрано: %lld", selected.count)).font(.lk(13, .bold)).foregroundStyle(Color.lkAccent)
                .contentTransition(.numericText()).animation(LKMotion.snappy, value: selected.count)
            HStack(spacing: 12) {
                Button { showMove = true } label: { Label("Переместить", systemImage: "folder") }
                    .buttonStyle(LKSecondaryButtonStyle()).disabled(selected.isEmpty)
                Button { confirmTrash = true } label: { Label("В корзину", systemImage: "trash") }
                    .buttonStyle(LKSecondaryButtonStyle(tint: .lkDanger)).disabled(selected.isEmpty)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.ultraThinMaterial).background(Color.lkBg.opacity(0.7))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Actions

    private func reload() async {
        do {
            let new = try await store.repo.listFiles(caseID: caseID).sorted { $0.createdAt > $1.createdAt }
            let old = Set(files.map(\.id))
            let added = old.isEmpty ? [] : Set(new.map(\.id)).subtracting(old)
            files = new
            loadError = nil
            if !added.isEmpty {
                highlighted = added; Haptics.success()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { highlighted = [] }
            }
        } catch let e as VaultError {
            if case .notUnlocked = e { router.popToRoot() } else { loadError = e.message }
        } catch { loadError = "Не удалось загрузить файлы" }
        loading = false
    }

    private func consumeIntent() {
        guard let i = router.pendingIntent else { return }
        router.pendingIntent = nil
        switch i { case .camera: openCamera(); case .upload: showUploadChoices = true }
    }

    private func openCamera() {
        store.noteActivity()
        if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true } else { showPhotoPicker = true }
    }

    private func startUpload(_ items: [UploadItem]) {
        guard !items.isEmpty else { return }
        store.noteActivity()
        upload = UploadModel(caseID: caseID, caseName: vaultCase?.name ?? "Кейс", items: items)
    }

    private func importFiles(_ r: Result<[URL], Error>) {
        switch r {
        case .failure(let e): store.showError(e)
        case .success(let urls):
            var items: [UploadItem] = []
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                guard let d = try? Data(contentsOf: u) else { store.showToast(trf("Не удалось прочитать «%@»", u.lastPathComponent), isError: true); continue }
                items.append(UploadItem(name: u.lastPathComponent, kind: Self.kind(ext: u.pathExtension), data: d, size: Int64(d.count)))
            }
            startUpload(items)
        }
    }

    private func loadPhotos(_ picks: [PhotosPickerItem]) {
        photoItems = []
        Task {
            var items: [UploadItem] = []
            for (i, p) in picks.enumerated() {
                guard let d = try? await p.loadTransferable(type: Data.self) else { continue }
                let t = p.supportedContentTypes
                let (kind, ext): (FileKind, String) = t.contains(where: { $0.conforms(to: .png) }) ? (.png, "png")
                    : (t.contains(where: { $0.conforms(to: .heic) }) ? (.heic, "heic") : (.jpg, "jpg"))
                items.append(UploadItem(name: "Фото \(Self.stamp())-\(i + 1).\(ext)", kind: kind, data: d, size: Int64(d.count)))
            }
            startUpload(items)
        }
    }

    private func rename() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task {
            do { _ = try await store.repo.updateCase(id: caseID, name: n, icon: nil, level: nil, favorite: nil); await store.refreshCases() }
            catch { store.showError(error) }
        }
    }

    private func toggleFavCase() {
        let fav = !(vaultCase?.favorite ?? false)
        Task {
            do { _ = try await store.repo.updateCase(id: caseID, name: nil, icon: nil, level: nil, favorite: fav); await store.refreshCases() }
            catch { store.showError(error) }
        }
    }

    private func copyKey() {
        Task {
            do {
                let k = try await store.repo.exportKey(caseID: caseID)
                UIPasteboard.general.setItems([[UTType.plainText.identifier: k.keyString]],
                                              options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
                store.showToast("Ключ скопирован на 60 секунд")
            } catch { store.showError(error) }
        }
    }

    private func saveKey() {
        Task {
            do {
                let k = try await store.repo.exportKey(caseID: caseID)
                exportDoc = KeyFileDocument(data: k.fileData); exportName = k.fileName; showExporter = true
            } catch { store.showError(error) }
        }
    }

    private func trashSelected() {
        let ids = Array(selected)
        Task {
            do {
                try await store.repo.trashFiles(ids: ids)
                await store.refreshCases()
                selected = []; selecting = false
                await reload()
                store.showToast("Перемещено в корзину")
            } catch { store.showError(error) }
        }
    }

    private static func kind(ext: String) -> FileKind {
        switch ext.lowercased() {
        case "pdf": return .pdf
        case "jpg", "jpeg": return .jpg
        case "png": return .png
        case "heic", "heif": return .heic
        case "mov", "mp4", "m4v": return .video
        case "txt", "md": return .note
        default: return .other
        }
    }

    private static func stamp() -> String {
        let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd HH.mm.ss"; return d.string(from: Date())
    }

    private static func plural(_ n: Int) -> String {
        let a = n % 10, b = n % 100
        if a == 1 && b != 11 { return "файл" }
        if (2...4).contains(a) && !(12...14).contains(b) { return "файла" }
        return "файлов"
    }
}
