import SwiftUI
import PhotosUI
import VisionKit

// MARK: - Состояние страниц (только память)

@Observable @MainActor
final class ScanModel {
    var pages: [ScanPage] = []
    var previews: [UUID: UIImage] = [:]
    var filter: ScanFilter = .document
    var current = 0
    var loading = false

    func add(_ images: [UIImage]) async {
        guard !images.isEmpty else { return }
        loading = true
        for img in images {
            let box = ScanBox(image: img)
            let prepared: (ScanBox, ScanBox) = await Task.detached(priority: .userInitiated) {
                let p = ScanEngine.prepare(box.image)
                return (ScanBox(image: p.full), ScanBox(image: p.small))
            }.value
            let page = ScanPage(full: prepared.0.image, small: prepared.1.image)
            withAnimation(LKMotion.spring) { pages.append(page) }
            current = pages.count - 1
            refresh(page.id)
        }
        loading = false
    }

    func refresh(_ id: UUID) {
        guard let page = pages.first(where: { $0.id == id }) else { return }
        let box = ScanBox(image: page.small)
        let turns = page.turns, filter = filter
        Task {
            let out: ScanBox? = await Task.detached(priority: .userInitiated) {
                ScanEngine.render(box.image, turns: turns, filter: filter, maxSide: 1400).map { ScanBox(image: $0) }
            }.value
            guard let out, let now = pages.first(where: { $0.id == id }),
                  now.turns == turns, self.filter == filter else { return }
            withAnimation(.easeInOut(duration: 0.22)) { previews[id] = out.image }
        }
    }

    func refreshAll() { pages.forEach { refresh($0.id) } }

    func rotate(at index: Int) {
        guard pages.indices.contains(index) else { return }
        pages[index].turns = (pages[index].turns + 1) % 4
        refresh(pages[index].id)
    }

    func delete(at index: Int) {
        guard pages.indices.contains(index) else { return }
        let id = pages[index].id
        withAnimation(LKMotion.spring) {
            pages.remove(at: index)
            previews[id] = nil
            current = min(current, max(pages.count - 1, 0))
        }
    }

    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = pages.firstIndex(where: { $0.id == id }),
              let to = pages.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(LKMotion.spring) {
            let p = pages.remove(at: from)
            pages.insert(p, at: to)
            current = to
        }
    }

    func shift(at index: Int, by delta: Int) {
        let to = index + delta
        guard pages.indices.contains(index), pages.indices.contains(to) else { return }
        withAnimation(LKMotion.spring) {
            pages.swapAt(index, to)
            current = to
        }
    }
}

@Observable @MainActor
final class SaveState {
    var active = false
    var done = false
    var fraction = 0.0
    var text = ""
}

// MARK: - Поток

struct ScannerFlow: View {
    let caseID: String
    let caseName: String
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(AppStore.self) private var store

    @State private var model = ScanModel()
    @State private var save = SaveState()
    @State private var name = ScanEngine.defaultName()
    @State private var mode: ScanMode = .pdf
    @State private var ocrOn = true
    @State private var showCamera = false
    @State private var showPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var askAdd = false
    @State private var askClose = false
    @State private var autoOpened = false
    @Namespace private var segNS
    @FocusState private var nameFocused: Bool

    private var cameraOK: Bool { VNDocumentCameraViewController.isSupported }

    var body: some View {
        ZStack {
            if model.pages.isEmpty { startScreen } else { reviewScreen }
            if save.active { saveOverlay }
        }
        .lkScreen()
        .interactiveDismissDisabled(save.active || !model.pages.isEmpty)
        .fullScreenCover(isPresented: $showCamera) {
            DocumentCameraView(
                onFinish: { images in
                    showCamera = false
                    Task { await model.add(images) }
                },
                onCancel: { showCamera = false },
                onError: { err in showCamera = false; store.showError(err) })
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await loadPicked(items) }
        }
        .onAppear {
            guard !autoOpened else { return }
            autoOpened = true
            if cameraOK && model.pages.isEmpty { showCamera = true }
        }
        .confirmationDialog("Добавить страницу", isPresented: $askAdd, titleVisibility: .visible) {
            Button("Сканировать камерой") { showCamera = true }
            Button("Выбрать из фото") { showPicker = true }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Закрыть без сохранения?", isPresented: $askClose, titleVisibility: .visible) {
            Button("Удалить скан", role: .destructive) { dismiss() }
            Button("Продолжить", role: .cancel) {}
        } message: { Text("Страницы хранятся только в памяти и будут потеряны.") }
    }

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                images.append(img)
            }
        }
        if images.isEmpty { store.showToast("Не удалось загрузить фото", isError: true) }
        await model.add(images)
    }

    private func anim<V: Equatable>(_ a: Animation, _ v: V) -> Animation? { reduce ? nil : a }

    // MARK: Старт

    private var startScreen: some View {
        VStack(spacing: 0) {
            HStack {
                LKIconButton(systemName: "xmark", label: "Закрыть") { dismiss() }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8)
            Spacer()
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Color.lkAccent.opacity(0.12)).frame(width: 112, height: 112)
                    Image(systemName: cameraOK ? "doc.viewfinder" : "photo.on.rectangle.angled")
                        .font(.system(size: 46, weight: .medium))
                        .foregroundStyle(Color.lkAccent)
                        .symbolEffect(.pulse, options: reduce ? .nonRepeating : .repeating)
                }
                .lkAppear(0)
                Text(cameraOK ? "Сканер документов" : "Камера недоступна")
                    .font(.lk(24, .heavy)).lkAppear(1)
                Text(cameraOK
                     ? trf("Наведите камеру на документ: края определятся и выровняются автоматически. Страницы попадут в «%@» уже зашифрованными.", caseName)
                     : trf("На этом устройстве нет сканера. Можно добавить страницы из фотографий, они сохранятся в «%@» так же, как скан.", caseName))
                    .font(.lk(15)).foregroundStyle(Color.lkMuted)
                    .multilineTextAlignment(.center).lkAppear(2)
            }
            .padding(.horizontal, 28)
            Spacer()
            VStack(spacing: 12) {
                if cameraOK {
                    Button { showCamera = true } label: { Label("Открыть камеру", systemImage: "camera.fill") }
                        .buttonStyle(.lkPrimary)
                    Button { showPicker = true } label: { Label("Выбрать из фото", systemImage: "photo.on.rectangle") }
                        .buttonStyle(.lkSecondary)
                } else {
                    Button { showPicker = true } label: { Label("Выбрать фото", systemImage: "photo.on.rectangle") }
                        .buttonStyle(.lkPrimary)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
            .lkAppear(3)
            .overlay(alignment: .top) {
                if model.loading { ProgressView().tint(.lkAccent).offset(y: -36) }
            }
        }
    }

    // MARK: Проверка

    private var reviewScreen: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 18) {
                    preview
                    pageActions
                    strip
                    filtersRow
                    optionsCard
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom) { saveBar }
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack {
            LKIconButton(systemName: "xmark", label: "Закрыть сканер") { askClose = true }
            Spacer()
            VStack(spacing: 1) {
                Text("Проверка").font(.lk(16, .heavy))
                Text(verbatim: trf("Страница %lld из %lld", model.current + 1, model.pages.count))
                    .font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted)
                    .contentTransition(.numericText())
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }

    private var preview: some View {
        TabView(selection: Binding(get: { model.current }, set: { model.current = $0; Haptics.soft() })) {
            ForEach(Array(model.pages.enumerated()), id: \.element.id) { idx, page in
                ZStack {
                    if let img = model.previews[page.id] {
                        Image(uiImage: img)
                            .resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                            .id(ObjectIdentifier(img))
                            .transition(.opacity)
                            .accessibilityLabel(trf("Страница %lld", idx + 1))
                    } else {
                        ProgressView().tint(.lkAccent)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 420)
        .lkCard(radius: 26)
        .animation(reduce ? nil : LKMotion.spring, value: model.pages.count)
    }

    private var pageActions: some View {
        HStack(spacing: 12) {
            actionButton("rotate.right", "Повернуть", tint: .lkText) {
                Haptics.soft()
                model.rotate(at: model.current)
            }
            actionButton("plus.viewfinder", "Добавить", tint: .lkAccent) {
                Haptics.soft()
                if cameraOK { askAdd = true } else { showPicker = true }
            }
            actionButton("trash", "Удалить", tint: .lkDanger) {
                Haptics.warning()
                model.delete(at: model.current)
            }
        }
    }

    private func actionButton(_ icon: String, _ title: String, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                Text(title).font(.lk(12, .bold))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 56)
            .lkCard(radius: 16)
        }
        .buttonStyle(LKPressStyle())
        .accessibilityLabel(tr(title))
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(model.pages.enumerated()), id: \.element.id) { idx, page in
                        thumb(page, idx)
                            .id(page.id)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    Button {
                        Haptics.soft()
                        if cameraOK { askAdd = true } else { showPicker = true }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color.lkAccent)
                            .frame(width: 56, height: 74)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.lkAccent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(LKPressStyle())
                    .accessibilityLabel("Добавить страницу")
                }
                .padding(.horizontal, 2).padding(.vertical, 4)
            }
            .onChange(of: model.current) { _, i in
                guard model.pages.indices.contains(i) else { return }
                withAnimation(LKMotion.snappy) { proxy.scrollTo(model.pages[i].id, anchor: .center) }
            }
        }
        .frame(height: 86)
    }

    private func thumb(_ page: ScanPage, _ idx: Int) -> some View {
        let selected = idx == model.current
        return Button {
            Haptics.soft()
            withAnimation(LKMotion.snappy) { model.current = idx }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let img = model.previews[page.id] {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Color.lkRaised
                    }
                }
                .frame(width: 56, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("\(idx + 1)").font(.lk(11, .heavy)).foregroundStyle(Color.lkBg)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(selected ? Color.lkAccent : Color.lkText2, in: Circle())
                    .offset(x: -3, y: -3)
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Color.lkAccent : Color.lkBorder, lineWidth: selected ? 2 : 1))
            .scaleEffect(selected ? 1.04 : 1)
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(LKPressStyle())
        .draggable(page.id.uuidString) {
            Group {
                if let img = model.previews[page.id] { Image(uiImage: img).resizable().scaledToFill() } else { Color.lkRaised }
            }
            .frame(width: 56, height: 74).clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
            Haptics.soft()
            model.move(id, before: page.id)
            return true
        }
        .accessibilityLabel(trf("Страница %lld", idx + 1))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Переместить влево") { model.shift(at: idx, by: -1) }
        .accessibilityAction(named: "Переместить вправо") { model.shift(at: idx, by: 1) }
    }

    private var filtersRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Фильтр").font(.lk(13, .bold)).foregroundStyle(Color.lkMuted)
            HStack(spacing: 8) {
                ForEach(ScanFilter.allCases) { f in
                    LKChip(title: f.title, selected: model.filter == f) {
                        guard model.filter != f else { return }
                        Haptics.soft()
                        model.filter = f
                        model.refreshAll()
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Название").font(.lk(13, .bold)).foregroundStyle(Color.lkMuted)
                HStack {
                    TextField("Название", text: $name)
                        .font(.lk(16, .semibold))
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { nameFocused = false }
                    if !name.isEmpty {
                        Button { name = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.lkMuted)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Очистить название")
                    }
                }
                .padding(.leading, 14)
                .frame(minHeight: 48)
                .background(Color.lkRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            segmented
            Toggle(isOn: $ocrOn) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Распознать текст на устройстве").font(.lk(15, .bold))
                    Text("Текст остаётся внутри зашифрованного файла и нужен для поиска.")
                        .font(.lk(12)).foregroundStyle(Color.lkMuted)
                }
            }
            .tint(.lkAccent)
            .frame(minHeight: 44)
        }
        .padding(16)
        .lkCard(radius: 22)
    }

    private var segmented: some View {
        HStack(spacing: 4) {
            ForEach([(ScanMode.pdf, "Один PDF"), (ScanMode.photos, "Отдельные фото")], id: \.0) { m, title in
                Button {
                    Haptics.soft()
                    withAnimation(reduce ? nil : LKMotion.snappy) { mode = m }
                } label: {
                    Text(title).font(.lk(14, .bold))
                        .foregroundStyle(mode == m ? Color.lkBg : Color.lkText2)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background {
                            if mode == m {
                                Capsule().fill(Color.lkAccent).matchedGeometryEffect(id: "seg", in: segNS)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == m ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.lkRaised, in: Capsule())
    }

    private var saveBar: some View {
        Button { startSave() } label: {
            Label(mode == .pdf ? tr("Сохранить PDF") : trf("Сохранить %lld фото", model.pages.count), systemImage: "lock.doc.fill")
        }
        .buttonStyle(.lkPrimary)
        .disabled(model.pages.isEmpty || save.active)
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        .background(.ultraThinMaterial.opacity(0.0))
        .background(LinearGradient(colors: [.clear, Color.lkBg.opacity(0.95)], startPoint: .top, endPoint: .center).ignoresSafeArea())
    }

    // MARK: Сохранение

    private var saveOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 22) {
                ZStack {
                    Circle().stroke(Color.lkTrack, lineWidth: 8)
                    Circle().trim(from: 0, to: save.done ? 1 : max(0.02, save.fraction))
                        .stroke(Color.lkAccent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduce ? nil : .easeOut(duration: 0.3), value: save.fraction)
                    if save.done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 44, weight: .bold)).foregroundStyle(Color.lkAccent)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    } else {
                        Text("\(Int(save.fraction * 100))%").font(.lkMono(22)).contentTransition(.numericText())
                    }
                }
                .frame(width: 112, height: 112)
                Text(verbatim: save.done ? trf("Сохранено в «%@»", caseName) : tr(save.text))
                    .font(.lk(16, .bold)).multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if !save.done {
                    Label("Шифруется на устройстве", systemImage: "lock.fill")
                        .font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted)
                }
            }
            .padding(32)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    private func startSave() {
        nameFocused = false
        guard !save.active else { return }
        Task { await performSave() }
    }

    @MainActor
    private func performSave() async {
        let pages = model.pages
        let filter = model.filter
        let wantOCR = ocrOn
        let asPDF = mode == .pdf
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if base.isEmpty { base = ScanEngine.defaultName().replacingOccurrences(of: ":", with: "-") }
        let n = pages.count
        let state = save
        let prepShare = 0.5
        let reduceMotion = reduce
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            state.active = true; state.done = false; state.fraction = 0; state.text = "Обработка страниц…"
        }
        var savedIDs: [UUID] = []
        do {
            var jpegs: [Data] = []
            var texts: [String] = []
            for (i, p) in pages.enumerated() {
                state.text = n > 1 ? trf("Обработка страницы %lld из %lld…", i + 1, n) : tr("Обработка страницы…")
                let box = ScanBox(image: p.full)
                let turns = p.turns
                let jpgQ = asPDF ? 0.8 : 0.9
                let rendered: (Data, ScanBox)? = await Task.detached(priority: .userInitiated) {
                    guard let img = ScanEngine.render(box.image, turns: turns, filter: filter, maxSide: 2600),
                          let d = img.jpegData(compressionQuality: jpgQ) else { return nil }
                    return (d, ScanBox(image: img))
                }.value
                guard let rendered else { throw ScanError.render }
                jpegs.append(rendered.0)
                state.fraction = (Double(i) + (wantOCR ? 0.4 : 1)) / Double(n) * prepShare
                if wantOCR {
                    state.text = n > 1 ? trf("Распознавание текста: %lld из %lld…", i + 1, n) : tr("Распознавание текста…")
                    let img = rendered.1
                    let t: String = await Task.detached(priority: .userInitiated) {
                        ScanEngine.recognizeText(in: img.image)
                    }.value
                    texts.append(t)
                    state.fraction = Double(i + 1) / Double(n) * prepShare
                }
            }

            struct Out { var name: String; var kind: FileKind; var data: Data; var ocr: String? }
            var outs: [Out] = []
            if asPDF {
                state.text = "Сборка PDF…"
                let list = jpegs
                let pdf = try await Task.detached(priority: .userInitiated) { try ScanEngine.makePDF(jpegs: list) }.value
                outs = [Out(name: base.lowercased().hasSuffix(".pdf") ? base : base + ".pdf", kind: .pdf, data: pdf,
                            ocr: wantOCR ? ScanEngine.joinAndCap(texts) : nil)]
            } else {
                let stem = base.replacingOccurrences(of: ".jpg", with: "")
                for (i, d) in jpegs.enumerated() {
                    outs.append(Out(name: n == 1 ? "\(stem).jpg" : "\(stem) \(i + 1).jpg", kind: .jpg, data: d,
                                    ocr: wantOCR && i < texts.count ? ScanEngine.joinAndCap([texts[i]]) : nil))
                }
            }

            for (i, o) in outs.enumerated() {
                let total = outs.count
                _ = try await store.repo.addFile(caseID: caseID, name: o.name, kind: o.kind, data: o.data, note: nil, ocrText: o.ocr) { p in
                    let stageIdx: Double
                    let text: String
                    switch p.stage {
                    case .encrypting: stageIdx = 0; text = "Шифрование…"
                    case .uploading: stageIdx = 1; text = "Загрузка…"
                    case .verifying: stageIdx = 2; text = "Проверка целостности…"
                    case .done: stageIdx = 3; text = "Готово"
                    }
                    let within = p.stage == .done ? 1 : (stageIdx + min(max(p.fraction, 0), 1)) / 3
                    let overall = prepShare + (1 - prepShare) * (Double(i) + within) / Double(total)
                    Task { @MainActor in
                        state.fraction = max(state.fraction, overall)
                        state.text = total > 1 ? "\(tr(text)) (\(trf("%lld из %lld", i + 1, total)))" : tr(text)
                    }
                }
                if !asPDF, i < pages.count { savedIDs.append(pages[i].id) }
            }

            withAnimation(reduceMotion ? nil : LKMotion.spring) { state.fraction = 1; state.done = true }
            Haptics.success()
            store.noteActivity()
            try? await Task.sleep(nanoseconds: 950_000_000)
            onSaved()
            dismiss()
        } catch {
            Haptics.error()
            state.active = false
            if !savedIDs.isEmpty {
                // Уже сохранённые страницы убираем, чтобы повтор не создал дубликаты.
                model.pages.removeAll { savedIDs.contains($0.id) }
                model.current = min(model.current, max(model.pages.count - 1, 0))
                onSaved()
            }
            store.showError(error)
        }
    }
}
