import SwiftUI
import PencilKit

/// Редактор фото: обрезка, фильтры, коррекция, рисунок, текст, подпись.
struct PhotoEditorView: View {
    let fileID: String
    let caseID: String
    let fileName: String
    let imageData: Data
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model: EditorModel
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var showSave = false
    @State private var showDiscard = false
    @State private var showSignature = false
    @State private var showTextAlert = false
    @State private var editingText = false
    @State private var textDraft = ""

    init(fileID: String, caseID: String, fileName: String, imageData: Data, onSaved: @escaping () -> Void) {
        self.fileID = fileID
        self.caseID = caseID
        self.fileName = fileName
        self.imageData = imageData
        self.onSaved = onSaved
        _model = State(initialValue: EditorModel(data: imageData))
    }

    private var anim: Animation? { reduceMotion ? nil : LKMotion.spring }
    private var zoomEnabled: Bool { model.tool == .filters || model.tool == .adjust }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            canvasArea
            bottomArea
        }
        .lkScreen(strength: 0.08)
        .task { await model.load() }
        .onChange(of: model.renderKey) { model.scheduleRender() }
        .sheet(isPresented: $showSignature) {
            SignatureSheet { img in
                Haptics.success()
                withAnimation(anim) { model.addSignature(img) }
            }
        }
        .sheet(isPresented: $showSave) {
            SaveSheet(model: model, fileName: fileName) {
                Task {
                    let ok = await model.save(store: store, fileID: fileID, caseID: caseID, fileName: fileName)
                    if ok {
                        try? await Task.sleep(for: .milliseconds(1100))
                        showSave = false
                        onSaved()
                        dismiss()
                    }
                }
            }
        }
        .alert(tr(editingText ? "Изменить текст" : "Новый текст"), isPresented: $showTextAlert) {
            TextField("Текст", text: $textDraft)
            Button("Готово") {
                let t = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                if editingText {
                    model.updateSelected { $0.kind = .text(t) }
                } else {
                    withAnimation(anim) { model.addText(t) }
                }
            }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Отменить изменения?", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("Отменить правки", role: .destructive) { dismiss() }
            Button("Продолжить редактирование", role: .cancel) {}
        } message: {
            Text("Несохранённые правки будут потеряны.")
        }
    }

    // MARK: Верхняя панель

    private var topBar: some View {
        HStack {
            Button {
                if model.hasChanges { Haptics.warning(); showDiscard = true } else { dismiss() }
            } label: {
                Text("Отмена").font(.lk(16, .semibold)).foregroundStyle(Color.lkText2)
                    .frame(minWidth: 72, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                Haptics.rigid()
                withAnimation(anim) { model.resetAll() }
            } label: {
                Label("Сбросить", systemImage: "arrow.counterclockwise")
                    .font(.lk(15, .semibold))
                    .foregroundStyle(model.hasChanges ? Color.lkText : Color.lkMuted)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.hasChanges)
            Spacer()
            Button {
                Haptics.soft()
                model.selectedID = nil
                model.saveState = .idle
                showSave = true
            } label: {
                Text("Готово").font(.lk(15, .heavy)).foregroundStyle(Color.lkBg)
                    .padding(.horizontal, 18).frame(minWidth: 72, minHeight: 44)
                    .background(model.hasChanges ? Color.lkAccent : Color.lkRaised, in: Capsule())
                    .opacity(model.hasChanges ? 1 : 0.5)
            }
            .buttonStyle(LKPressStyle(scale: 0.94))
            .disabled(!model.hasChanges)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    // MARK: Холст

    private func fit(_ s: CGSize, in area: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let k = min(area.width / s.width, area.height / s.height)
        return CGSize(width: (s.width * k).rounded(.down), height: (s.height * k).rounded(.down))
    }

    private var canvasArea: some View {
        GeometryReader { geo in
            let area = CGSize(width: max(geo.size.width - 32, 0), height: max(geo.size.height - 16, 0))
            ZStack {
                if let img = model.preview {
                    let size = fit(img.size, in: area)
                    ZStack {
                        Image(uiImage: img).resizable().frame(width: size.width, height: size.height)
                            .accessibilityLabel("Редактируемое фото")
                        if model.tool == .crop {
                            if !model.previewHasCrop {
                                CropView(rect: $model.params.cropRect, aspect: model.params.aspect, size: size)
                                    .transition(.opacity)
                            }
                        }
                        AnnotationLayer(model: model, size: size)
                            .opacity(model.tool == .crop ? 0 : 1)
                            .allowsHitTesting(model.tool != .crop)
                    }
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(zoom)
                    .offset(pan)
                    .gesture(zoomGesture, including: zoomEnabled ? .all : .none)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { resetZoom() }, including: zoomEnabled ? .all : .none)
                    .onChange(of: size, initial: true) { _, new in
                        if model.tool != .crop || !model.previewHasCrop { model.canvasSize = new }
                        model.reconcileInk(viewSize: new)
                    }
                    .onChange(of: model.previewGeo) { _, _ in model.reconcileInk(viewSize: size) }
                } else if model.loadFailed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 28))
                        Text("Не удалось открыть изображение").font(.lk(15, .semibold))
                    }.foregroundStyle(Color.lkWarn)
                } else {
                    ProgressView().tint(Color.lkAccent)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in zoom = min(max(zoomBase * v.magnification, 1), 5) }
            .onEnded { _ in
                zoomBase = zoom
                if zoom < 1.02 { resetZoom() }
            }
            .simultaneously(with: DragGesture()
                .onChanged { v in
                    guard zoom > 1.02 else { return }
                    pan = CGSize(width: panBase.width + v.translation.width, height: panBase.height + v.translation.height)
                }
                .onEnded { _ in panBase = pan })
    }

    private func resetZoom() {
        withAnimation(anim) { zoom = 1; zoomBase = 1; pan = .zero; panBase = .zero }
    }

    // MARK: Нижняя область

    private var bottomArea: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                switch model.tool {
                case .crop: CropPanel(model: model).transition(panelTransition)
                case .filters: FilterPanel(model: model).transition(panelTransition)
                case .adjust: AdjustPanel(model: model).transition(panelTransition)
                case .draw: DrawPanel(model: model).transition(panelTransition)
                case .text: TextPanel(model: model, onAdd: addTextTapped, onEdit: editTextTapped).transition(panelTransition)
                case .sign: SignPanel(model: model) { showSignature = true }.transition(panelTransition)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 176, maxHeight: 176, alignment: .top)
            .clipped()
            tabBar
        }
        .padding(.top, 8)
        .background(Color.lkCard.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Color.lkBorderSoft).frame(height: 1) }
    }

    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(EditorTool.allCases) { t in
                let on = model.tool == t
                Button { select(t) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 19, weight: .semibold))
                        Text(t.title).font(.lk(10, on ? .bold : .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(on ? Color.lkAccent : Color.lkMuted)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.lkAccent.opacity(0.14))
                                .padding(.horizontal, 3)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr(t.title))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    // MARK: Действия

    private func select(_ t: EditorTool) {
        if t == model.tool {
            if t == .sign { showSignature = true }
            return
        }
        Haptics.soft()
        withAnimation(anim) {
            model.tool = t
            if !(t == .filters || t == .adjust) { zoom = 1; zoomBase = 1; pan = .zero; panBase = .zero }
            if let s = model.selected, (t == .text && !s.isText) || (t == .sign && s.isText) || t == .draw { model.selectedID = nil }
        }
        if t == .filters { model.refreshThumbs() }
        if t == .sign, !model.overlays.contains(where: { !$0.isText }) { showSignature = true }
    }

    private func addTextTapped() {
        editingText = false
        textDraft = ""
        showTextAlert = true
    }

    private func editTextTapped() {
        guard let s = model.selected, s.isText else { return }
        editingText = true
        textDraft = s.text
        showTextAlert = true
    }
}

// MARK: - Слой аннотаций (рисунок + наложения)

private struct AnnotationLayer: View {
    @Bindable var model: EditorModel
    let size: CGSize

    var body: some View {
        ZStack {
            InkCanvas(model: model, tool: model.pkTool, active: model.tool == .draw)
                .frame(width: size.width, height: size.height)
            if model.tool == .text || model.tool == .sign {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { model.selectedID = nil }
            }
            ForEach($model.overlays) { $item in
                let interactive = (model.tool == .text && item.isText) || (model.tool == .sign && !item.isText)
                OverlayView(item: $item, canvas: size, selected: model.selectedID == item.id && interactive,
                            interactive: interactive) { model.selectedID = item.id }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .coordinateSpace(name: "lkAnnot")
    }
}

private struct OverlayView: View {
    @Binding var item: EditorOverlay
    let canvas: CGSize
    let selected: Bool
    let interactive: Bool
    let onSelect: () -> Void

    @State private var dragStart: CGPoint?
    @State private var sizeStart: CGFloat?
    @State private var angleStart: CGFloat?

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .signature:
            if let img = item.display {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(width: item.size * canvas.width)
                    .accessibilityLabel("Подпись")
            }
        case .text(let s):
            Text(s)
                .font(.system(size: item.size * canvas.width, weight: .bold))
                .foregroundStyle(Color(uiColor: item.color ?? .white))
                .shadow(color: .black.opacity(0.35), radius: item.size * canvas.width * 0.08)
                .multilineTextAlignment(.center)
                .fixedSize()
        }
    }

    var body: some View {
        content
            .padding(8)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.lkAccent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
            .rotationEffect(.radians(item.angle))
            .contentShape(Rectangle())
            .allowsHitTesting(interactive)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("lkAnnot"))
                    .onChanged { v in
                        if dragStart == nil { dragStart = item.center; onSelect() }
                        guard let s = dragStart, canvas.width > 0, canvas.height > 0 else { return }
                        item.center = CGPoint(x: min(max(s.x + v.translation.width / canvas.width, 0), 1),
                                              y: min(max(s.y + v.translation.height / canvas.height, 0), 1))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        if sizeStart == nil { sizeStart = item.size; onSelect() }
                        let base = sizeStart ?? item.size
                        item.size = item.isText ? min(max(base * v.magnification, 0.03), 0.3) : min(max(base * v.magnification, 0.1), 1.2)
                    }
                    .onEnded { _ in sizeStart = nil }
            )
            .simultaneousGesture(
                RotateGesture()
                    .onChanged { v in
                        if angleStart == nil { angleStart = item.angle; onSelect() }
                        item.angle = (angleStart ?? item.angle) + CGFloat(v.rotation.radians)
                    }
                    .onEnded { _ in angleStart = nil }
            )
            .position(x: item.center.x * canvas.width, y: item.center.y * canvas.height)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Лист сохранения

private struct SaveSheet: View {
    @Bindable var model: EditorModel
    let fileName: String
    let onSave: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var busy: Bool { if case .working = model.saveState { return true } else { return false } }
    private var done: Bool { model.saveState == .done }

    var body: some View {
        VStack(spacing: 16) {
            Text("Сохранить правки").font(.lk(20, .heavy)).padding(.top, 22)
            if done {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64)).foregroundStyle(Color.lkAccent)
                        .symbolEffect(.bounce, options: reduceMotion ? .nonRepeating.speed(100) : .nonRepeating, value: done)
                    Text("Сохранено").font(.lk(17, .bold))
                }
                .frame(maxWidth: .infinity, minHeight: 190)
                .transition(.scale.combined(with: .opacity))
            } else {
                VStack(spacing: 10) {
                    option(.newVersion, title: "Сохранить как новую версию",
                           sub: "Старая версия останется в истории файла")
                    option(.copy, title: "Сохранить как копию", sub: EditorModel.copyName(fileName))
                }
                .disabled(busy)
                if case .working(let title, let f) = model.saveState {
                    VStack(spacing: 6) {
                        ProgressView(value: f).tint(Color.lkAccent)
                        Text(title).font(.lk(13, .semibold)).foregroundStyle(Color.lkMuted)
                    }
                    .transition(.opacity)
                } else {
                    Button(action: onSave) { Text("Сохранить") }
                        .buttonStyle(.lkPrimary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .animation(reduceMotion ? nil : LKMotion.spring, value: model.saveState)
        .background(Color.lkBg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .foregroundStyle(Color.lkText)
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(busy || done)
    }

    private func option(_ mode: EditorModel.SaveMode, title: String, sub: String) -> some View {
        let on = model.saveMode == mode
        return Button {
            Haptics.soft()
            model.saveMode = mode
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(on ? Color.lkAccent : Color.lkMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.lk(16, .bold))
                    Text(sub).font(.lk(13)).foregroundStyle(Color.lkMuted).lineLimit(1)
                }
                Spacer()
            }
            .padding(14)
            .frame(minHeight: 64)
            .lkCard(radius: 18, fill: on ? Color.lkAccent.opacity(0.1) : Color.lkCard,
                    stroke: on ? Color.lkAccent.opacity(0.6) : Color.lkBorderSoft)
            .contentShape(Rectangle())
        }
        .buttonStyle(LKPressStyle(scale: 0.98))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
