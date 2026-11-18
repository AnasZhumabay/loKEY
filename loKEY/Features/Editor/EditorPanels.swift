import SwiftUI
import PencilKit

// MARK: - Общие мелочи

private func lkAnim(_ reduce: Bool, _ a: Animation = LKMotion.snappy) -> Animation? { reduce ? nil : a }

private struct SmallIconButton: View {
    let icon: String
    let label: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color.lkRaised, in: Circle())
        }
        .buttonStyle(LKPressStyle(scale: 0.88))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(tr(label))
    }
}

private struct ColorSwatches: View {
    let colors: [UIColor]
    let names: [String]
    let selected: Int?
    let onSelect: (Int) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(colors.indices, id: \.self) { i in
                Button { Haptics.soft(); onSelect(i) } label: {
                    Circle().fill(Color(uiColor: colors[i]))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().stroke(selected == i ? Color.lkAccent : .clear, lineWidth: 2))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr(names[i]))
                .accessibilityAddTraits(selected == i ? .isSelected : [])
            }
        }
    }
}

// MARK: - Обрезка

struct CropPanel: View {
    @Bindable var model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CropAspect.allCases) { a in
                        LKChip(title: a.title, selected: model.params.aspect == a) {
                            Haptics.soft()
                            withAnimation(lkAnim(reduce)) { model.setAspect(a) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack(spacing: 10) {
                SmallIconButton(icon: "rotate.left", label: "Повернуть влево") {
                    Haptics.soft(); withAnimation(lkAnim(reduce)) { model.rotate(-1) }
                }
                SmallIconButton(icon: "rotate.right", label: "Повернуть вправо") {
                    Haptics.soft(); withAnimation(lkAnim(reduce)) { model.rotate(1) }
                }
                SmallIconButton(icon: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Отразить по горизонтали") {
                    Haptics.soft(); withAnimation(lkAnim(reduce)) { model.flip() }
                }
                Spacer()
                SmallIconButton(icon: "arrow.counterclockwise", label: "Сбросить обрезку",
                                enabled: model.params.rotation != 0 || model.params.flipH || model.params.straighten != 0 || !model.params.isFullCrop) {
                    Haptics.soft()
                    withAnimation(lkAnim(reduce)) {
                        model.params.rotation = 0; model.params.flipH = false; model.params.straighten = 0
                        model.params.aspect = .free; model.params.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                    }
                }
            }
            .padding(.horizontal, 16)
            HStack(spacing: 10) {
                Image(systemName: "level").foregroundStyle(Color.lkMuted).frame(width: 24)
                Slider(value: Binding(
                    get: { model.params.straighten },
                    set: { v in
                        let snapped = abs(v) < 0.8 ? 0 : v
                        if snapped == 0 && model.params.straighten != 0 { Haptics.soft() }
                        model.params.straighten = snapped
                    }), in: -45...45)
                    .tint(Color.lkAccent)
                    .accessibilityLabel("Выравнивание")
                    .accessibilityValue("\(Int(model.params.straighten)) градусов")
                Text("\(Int(model.params.straighten.rounded()))°")
                    .font(.lkMono(13)).foregroundStyle(Color.lkText2)
                    .frame(width: 44, alignment: .trailing)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Фильтры

struct FilterPanel: View {
    @Bindable var model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(FilterLook.allCases) { look in
                    let on = model.params.filter == look
                    Button {
                        Haptics.soft()
                        withAnimation(lkAnim(reduce)) { model.params.filter = look }
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.lkRaised)
                                if let t = model.thumbs[look] {
                                    Image(uiImage: t).resizable().scaledToFill()
                                        .frame(width: 76, height: 76)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .transition(.opacity)
                                }
                            }
                            .frame(width: 76, height: 76)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(on ? Color.lkAccent : .clear, lineWidth: 2.5))
                            .scaleEffect(on ? 1.04 : 1)
                            Text(look.title)
                                .font(.lk(12, on ? .bold : .semibold))
                                .foregroundStyle(on ? Color.lkText : Color.lkMuted)
                        }
                        .frame(minWidth: 76, minHeight: 44)
                    }
                    .buttonStyle(LKPressStyle(scale: 0.94))
                    .accessibilityLabel(tr(look.title))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
        .animation(lkAnim(reduce), value: model.thumbs.count)
    }
}

// MARK: - Коррекция

struct AdjustPanel: View {
    @Bindable var model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    private func isModified(_ k: AdjustKind) -> Bool { model.params[keyPath: k.keyPath] != k.neutral }

    var body: some View {
        let kind = model.adjust
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(AdjustKind.allCases) { k in
                    let on = k == kind
                    Button {
                        Haptics.soft()
                        withAnimation(lkAnim(reduce)) { model.adjust = k }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: k.icon).font(.system(size: 18, weight: .semibold))
                            Text(k.title).font(.lk(10, .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                        }
                        .foregroundStyle(on ? Color.lkBg : Color.lkText2)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(on ? Color.lkAccent : Color.lkRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if isModified(k) && !on {
                                Circle().fill(Color.lkAccent).frame(width: 7, height: 7).padding(6)
                            }
                        }
                    }
                    .buttonStyle(LKPressStyle(scale: 0.94))
                    .accessibilityLabel(tr(k.title))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            HStack(spacing: 12) {
                Slider(value: Binding(
                    get: { model.params[keyPath: kind.keyPath] },
                    set: { v in
                        var x = v
                        if abs(x - kind.neutral) < (kind.range.upperBound - kind.range.lowerBound) * 0.015 {
                            if model.params[keyPath: kind.keyPath] != kind.neutral { Haptics.soft() }
                            x = kind.neutral
                        }
                        model.params[keyPath: kind.keyPath] = x
                    }), in: kind.range)
                    .tint(Color.lkAccent)
                    .accessibilityLabel(tr(kind.title))
                    .accessibilityValue("\(kind.display(model.params[keyPath: kind.keyPath]))")
                Text("\(kind.display(model.params[keyPath: kind.keyPath]))")
                    .font(.lkMono(13)).foregroundStyle(Color.lkText2)
                    .frame(width: 40, alignment: .trailing)
                    .contentTransition(.numericText())
                SmallIconButton(icon: "arrow.counterclockwise", label: trf("Сбросить: %@", tr(kind.title)), enabled: isModified(kind)) {
                    Haptics.soft()
                    withAnimation(lkAnim(reduce)) { model.params[keyPath: kind.keyPath] = kind.neutral }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Рисунок

struct DrawPanel: View {
    @Bindable var model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ForEach(InkKind.allCases) { k in
                    let on = model.ink == k
                    Button {
                        Haptics.soft()
                        withAnimation(lkAnim(reduce)) { model.ink = k }
                    } label: {
                        Image(systemName: k.icon).font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(on ? Color.lkBg : Color.lkText2)
                            .frame(width: 48, height: 44)
                            .background(on ? Color.lkAccent : Color.lkRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(LKPressStyle(scale: 0.92))
                    .accessibilityLabel(tr(k.title))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer()
                SmallIconButton(icon: "arrow.uturn.backward", label: "Отменить", enabled: model.canUndo) { Haptics.soft(); model.undo() }
                SmallIconButton(icon: "arrow.uturn.forward", label: "Повторить", enabled: model.canRedo) { Haptics.soft(); model.redo() }
            }
            .padding(.horizontal, 16)
            if model.ink != .eraser {
                ColorSwatches(colors: EditorPalette.colors, names: EditorPalette.names, selected: model.inkColor) { model.inkColor = $0 }
                    .transition(.opacity)
            }
            HStack(spacing: 10) {
                Image(systemName: "lineweight").foregroundStyle(Color.lkMuted).frame(width: 24)
                Slider(value: $model.inkWidth, in: 2...24).tint(Color.lkAccent)
                    .accessibilityLabel("Толщина")
                Circle().fill(Color.lkText).frame(width: CGFloat(model.inkWidth) + 2, height: CGFloat(model.inkWidth) + 2)
                    .frame(width: 30, height: 30)
            }
            .frame(minHeight: 40)
            .padding(.horizontal, 16)
        }
        .animation(lkAnim(reduce), value: model.ink)
    }
}

// MARK: - Текст

struct TextPanel: View {
    @Bindable var model: EditorModel
    let onAdd: () -> Void
    let onEdit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let sel = model.selected.flatMap { $0.isText ? $0 : nil }
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onAdd) {
                    Label("Добавить текст", systemImage: "plus").font(.lk(15, .bold))
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(Color.lkAccent, in: Capsule()).foregroundStyle(Color.lkBg)
                }
                .buttonStyle(LKPressStyle(scale: 0.94))
                Spacer()
                if sel != nil {
                    SmallIconButton(icon: "pencil", label: "Изменить текст", action: onEdit)
                    SmallIconButton(icon: "trash", label: "Удалить текст") {
                        Haptics.warning()
                        withAnimation(lkAnim(reduce)) { model.deleteSelected() }
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            if let sel {
                ColorSwatches(colors: EditorPalette.colors, names: EditorPalette.names,
                              selected: EditorPalette.colors.firstIndex { $0 == sel.color }) { i in
                    model.updateSelected { $0.color = EditorPalette.colors[i] }
                }
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size").foregroundStyle(Color.lkMuted).frame(width: 24)
                    Slider(value: Binding(get: { Double(sel.size) },
                                          set: { v in model.updateSelected { $0.size = CGFloat(v) } }), in: 0.03...0.2)
                        .tint(Color.lkAccent)
                        .accessibilityLabel("Размер шрифта")
                }
                .frame(minHeight: 40)
                .padding(.horizontal, 16)
            } else {
                Text(model.overlays.contains { $0.isText }
                     ? "Нажмите на текст на фото, чтобы выбрать его"
                     : "Текст можно двигать, увеличивать щипком и поворачивать двумя пальцами")
                    .font(.lk(13)).foregroundStyle(Color.lkMuted)
                    .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.top, 6)
            }
        }
    }
}

// MARK: - Подпись

struct SignPanel: View {
    @Bindable var model: EditorModel
    let onAdd: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let sel = model.selected.flatMap { $0.isText ? nil : $0 }
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: onAdd) {
                    Label("Добавить подпись", systemImage: "signature").font(.lk(15, .bold))
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(Color.lkAccent, in: Capsule()).foregroundStyle(Color.lkBg)
                }
                .buttonStyle(LKPressStyle(scale: 0.94))
                Spacer()
                if sel != nil {
                    SmallIconButton(icon: "trash", label: "Удалить подпись") {
                        Haptics.warning()
                        withAnimation(lkAnim(reduce)) { model.deleteSelected() }
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            if let sel {
                HStack(spacing: 6) {
                    Text("Цвет").font(.lk(13, .semibold)).foregroundStyle(Color.lkMuted)
                    let tints = EditorPalette.signTints
                    ForEach(tints.indices, id: \.self) { i in
                        let on = sel.color == tints[i].0
                        Button { Haptics.soft(); model.updateSelected { $0.setColor(tints[i].0) } } label: {
                            Circle().fill(Color(uiColor: tints[i].0)).frame(width: 26, height: 26)
                                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().stroke(on ? Color.lkAccent : .clear, lineWidth: 2))
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr(tints[i].1))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
            } else {
                Text("Подпись можно двигать, менять размер щипком и поворачивать двумя пальцами")
                    .font(.lk(13)).foregroundStyle(Color.lkMuted)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        }
    }
}

// MARK: - PencilKit

struct InkCanvas: UIViewRepresentable {
    let model: EditorModel
    let tool: PKTool
    let active: Bool

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.drawingPolicy = .anyInput
        v.overrideUserInterfaceStyle = .light
        v.isScrollEnabled = false
        v.bounces = false
        v.drawing = model.drawing
        v.tool = tool
        v.delegate = context.coordinator
        v.isUserInteractionEnabled = active
        model.canvas = v
        DispatchQueue.main.async { v.becomeFirstResponder() }
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        v.tool = tool
        v.isUserInteractionEnabled = active
        context.coordinator.model = model
        if model.canvas !== v { model.canvas = v }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var model: EditorModel
        init(model: EditorModel) { self.model = model }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let d = canvasView.drawing
            MainActor.assumeIsolated { model.syncDrawing(d) }
        }
    }
}
