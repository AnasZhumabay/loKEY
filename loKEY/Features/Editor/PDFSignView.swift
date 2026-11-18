import SwiftUI

/// Подпись PDF: просмотр страниц, оверлеи подписей, сведение в новый PDF и сохранение в хранилище.
struct PDFSignView: View {
    let fileID: String
    let caseID: String
    let fileName: String
    let pdfData: Data
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var renderer: PDFPageRenderer?
    @State private var loadFailed = false
    @State private var images: [Int: UIImage] = [:]
    @State private var thumbs: [Int: UIImage] = [:]
    @State private var current = 0
    @State private var signatures: [PDFPlacedSignature] = []
    @State private var selectedID: UUID?
    @State private var showPicker = false
    @State private var showSave = false
    @State private var confirmDiscard = false
    @State private var confirmCopy = false

    private var pageCount: Int { renderer?.sizes.count ?? 0 }
    private var selectedIndex: Int? { signatures.firstIndex { $0.id == selectedID } }
    private var anim: Animation? { reduceMotion ? nil : LKMotion.spring }

    var body: some View {
        VStack(spacing: 0) {
            topBar.padding(.horizontal, 16).padding(.top, 6)
            if loadFailed {
                failed
            } else if renderer == nil {
                Spacer(); ProgressView().tint(Color.lkAccent); Spacer()
            } else {
                pager
                if selectedIndex != nil { contextBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
                if pageCount > 1 { thumbStrip }
                signButton
            }
        }
        .lkScreen()
        .task { await load() }
        .sheet(isPresented: $showPicker) {
            SignatureSheet { img in
                showPicker = false
                addSignature(img)
            }
        }
        .sheet(isPresented: $showSave) {
            PDFSaveSheet(perform: { mode, progress in try await save(mode, progress: progress) },
                         onFinished: { showSave = false; onSaved(); dismiss() })
        }
        .confirmationDialog("Отменить изменения?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Выйти без сохранения", role: .destructive) { dismiss() }
            Button("Продолжить редактирование", role: .cancel) {}
        } message: { Text("Поставленные подписи не будут сохранены.") }
        .confirmationDialog("Копировать подпись", isPresented: $confirmCopy, titleVisibility: .visible) {
            Button("На все страницы") { copySelected(allPages: true) }
            Button("На следующие страницы") { copySelected(allPages: false) }
            Button("Отмена", role: .cancel) {}
        }
        .onChange(of: current) { _, new in
            store.noteActivity()
            // освобождаем память от далёких страниц
            images = images.filter { abs($0.key - new) <= 2 }
            if selectedIndex.map({ signatures[$0].page }) != new { selectedID = nil }
        }
    }

    // MARK: Верх

    private var topBar: some View {
        HStack(spacing: 10) {
            LKIconButton(systemName: "xmark", label: "Закрыть") {
                if signatures.isEmpty { dismiss() } else { Haptics.warning(); confirmDiscard = true }
            }
            Spacer()
            VStack(spacing: 1) {
                Text("Подпись документа").font(.lk(16, .heavy))
                if pageCount > 0 {
                    Text(verbatim: trf("Стр. %lld из %lld", current + 1, pageCount))
                        .font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted)
                        .contentTransition(.numericText())
                        .animation(anim, value: current)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button {
                selectedID = nil
                showSave = true
            } label: {
                Text("Готово").font(.lk(15, .heavy))
                    .foregroundStyle(signatures.isEmpty ? Color.lkMuted : Color.lkBg)
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .background(signatures.isEmpty ? Color.lkRaised : Color.lkAccent, in: Capsule())
            }
            .buttonStyle(LKPressStyle(scale: 0.92))
            .disabled(signatures.isEmpty)
            .accessibilityHint(tr(signatures.isEmpty ? "Сначала поставьте подпись" : ""))
        }
        .frame(height: 48)
    }

    private var failed: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.badge.ellipsis").font(.system(size: 44)).foregroundStyle(Color.lkWarn)
            Text("Не удалось открыть PDF").font(.lk(18, .heavy))
            Text("Файл повреждён или защищён паролем").font(.lk(14)).foregroundStyle(Color.lkMuted)
            Spacer()
        }
    }

    // MARK: Страницы

    private var pager: some View {
        TabView(selection: $current) {
            ForEach(0..<pageCount, id: \.self) { i in
                let s = renderer?.sizes[i] ?? CGSize(width: 612, height: 792)
                PDFPageCanvas(pageIndex: i, image: images[i], aspect: s.height / max(s.width, 1),
                              signatures: $signatures, selectedID: $selectedID)
                    .tag(i)
                    .task(id: i) { await ensureImage(i) }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxHeight: .infinity)
    }

    private var thumbStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        thumb(i).id(i)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .frame(height: 92)
            .onChange(of: current) { _, n in
                withAnimation(anim) { proxy.scrollTo(n, anchor: .center) }
            }
        }
    }

    private func thumb(_ i: Int) -> some View {
        let sel = i == current
        let signed = signatures.contains { $0.page == i }
        let s = renderer?.sizes[i] ?? CGSize(width: 612, height: 792)
        let h: CGFloat = 64
        let w = max(h * s.width / max(s.height, 1), 28)
        return Button {
            Haptics.soft()
            withAnimation(anim) { current = i }
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let t = thumbs[i] { Image(uiImage: t).resizable().scaledToFill() } else { Color.white.opacity(0.9) }
                }
                .frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(sel ? Color.lkAccent : Color.lkBorder, lineWidth: sel ? 2.5 : 1))
                if signed {
                    Image(systemName: "signature").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.lkBg).padding(4)
                        .background(Color.lkAccent, in: Circle()).offset(x: 5, y: -5)
                }
            }
            .padding(6)
            .frame(minWidth: 44, minHeight: 44)
            .scaleEffect(sel ? 1.06 : 1)
        }
        .buttonStyle(LKPressStyle(scale: 0.92))
        .accessibilityLabel(signed ? trf("Страница %lld, с подписью", i + 1) : trf("Страница %lld", i + 1))
        .accessibilityAddTraits(sel ? .isSelected : [])
        .task(id: i) { await ensureThumb(i) }
    }

    // MARK: Панель выбранной подписи

    private var contextBar: some View {
        HStack(spacing: 8) {
            ForEach(PDFInkTint.allCases) { t in
                let on = selectedIndex.map { signatures[$0].tint == t } ?? false
                Button {
                    guard let i = selectedIndex else { return }
                    Haptics.soft()
                    withAnimation(anim) { signatures[i].setTint(t) }
                } label: {
                    Circle().fill(t.color).frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: on ? 2.5 : 0).padding(-4))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(LKPressStyle(scale: 0.88))
                .accessibilityLabel(trf("Цвет: %@", tr(t.title)))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Divider().frame(height: 24).overlay(Color.lkBorder)
            let dateOn = selectedIndex.map { signatures[$0].withDate } ?? false
            ctxButton("calendar", label: dateOn ? "Убрать дату" : "Добавить дату", active: dateOn) {
                guard let i = selectedIndex else { return }
                withAnimation(anim) { signatures[i].withDate.toggle() }
            }
            ctxButton("doc.on.doc", label: "Копировать на другие страницы", active: false) {
                if pageCount > 1 { confirmCopy = true } else { store.showToast("В документе одна страница") }
            }
            Spacer(minLength: 0)
            ctxButton("trash", label: "Удалить подпись", active: false, tint: .lkDanger) {
                guard let i = selectedIndex else { return }
                Haptics.warning()
                withAnimation(anim) { signatures.remove(at: i); selectedID = nil }
            }
        }
        .padding(.horizontal, 10)
        .lkCard(radius: 22)
        .padding(.horizontal, 16).padding(.bottom, 6)
    }

    private func ctxButton(_ icon: String, label: String, active: Bool, tint: Color = .lkText, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? Color.lkAccent : tint)
                .frame(width: 44, height: 44)
                .background(active ? Color.lkAccent.opacity(0.15) : .clear, in: Circle())
        }
        .buttonStyle(LKPressStyle(scale: 0.88))
        .accessibilityLabel(tr(label))
    }

    private var signButton: some View {
        Button {
            Haptics.soft()
            showPicker = true
        } label: {
            Label(tr(signatures.isEmpty ? "Поставить подпись" : "Ещё подпись"), systemImage: "signature")
        }
        .buttonStyle(.lkPrimary)
        .padding(.horizontal, 20).padding(.bottom, 10).padding(.top, 4)
    }

    // MARK: Логика

    private func load() async {
        guard renderer == nil else { return }
        let data = pdfData
        let r = await Task.detached(priority: .userInitiated) { PDFPageRenderer(data: data) }.value
        if let r { renderer = r } else { loadFailed = true }
    }

    private func ensureImage(_ i: Int) async {
        guard let renderer, images[i] == nil else { return }
        let img = await renderer.render(page: i, width: 1400)
        if let img, abs(i - current) <= 2 { images[i] = img }
    }

    private func ensureThumb(_ i: Int) async {
        guard let renderer, thumbs[i] == nil else { return }
        if let img = await renderer.render(page: i, width: 180) { thumbs[i] = img }
    }

    private func addSignature(_ img: UIImage) {
        var s = PDFPlacedSignature(page: current, original: img)
        let n = signatures.filter { $0.page == current }.count
        s.center = CGPoint(x: min(0.5 + 0.05 * CGFloat(n), 0.8), y: min(0.72 - 0.05 * CGFloat(n), 0.9))
        Haptics.success()
        withAnimation(anim) {
            signatures.append(s)
            selectedID = s.id
        }
    }

    private func copySelected(allPages: Bool) {
        guard let i = selectedIndex else { return }
        let src = signatures[i]
        var copies: [PDFPlacedSignature] = []
        for p in 0..<pageCount where p != src.page && (allPages || p > src.page) {
            var c = PDFPlacedSignature(page: p, original: src.original, tint: src.tint)
            c.center = src.center; c.width = src.width; c.rotation = src.rotation; c.withDate = src.withDate
            copies.append(c)
        }
        guard !copies.isEmpty else { store.showToast("Нет страниц для копирования"); return }
        Haptics.success()
        withAnimation(anim) { signatures.append(contentsOf: copies) }
        store.showToast(trf("Подпись скопирована: %lld", copies.count))
    }

    private func save(_ mode: PDFSaveMode, progress: @escaping @Sendable (UploadProgress) -> Void) async throws {
        store.noteActivity()
        let data = pdfData
        let sigs = signatures
        let out = await Task.detached(priority: .userInitiated) { () -> Data? in
            // PDFKit сохраняет аннотации/ссылки/формы; flatten — только если PDFKit не разобрал файл
            if let first = sigs.first,
               let signed = PDFSigner.sign(pdfData: data, signature: first.image, placements: PDFSigner.placements(from: sigs)) {
                return signed
            }
            return PDFFlattener.flatten(data: data, signatures: sigs)
        }.value
        guard let out, !out.isEmpty else { throw PDFSignFailure() }
        switch mode {
        case .newVersion:
            _ = try await store.repo.replaceFileContent(fileID: fileID, data: out, progress: progress)
        case .copy:
            let base = (fileName as NSString).deletingPathExtension
            _ = try await store.repo.addFile(caseID: caseID, name: "\(base) (подписан).pdf", kind: .pdf, data: out, note: nil, progress: progress)
        }
    }
}

private struct PDFSignFailure: Error {}
