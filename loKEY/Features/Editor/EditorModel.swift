import SwiftUI
import PencilKit
import Observation

enum EditorTool: String, CaseIterable, Identifiable {
    case crop, filters, adjust, draw, text, sign
    var id: String { rawValue }
    var title: String {
        switch self {
        case .crop: return "Обрезка"
        case .filters: return "Фильтры"
        case .adjust: return "Коррекция"
        case .draw: return "Рисунок"
        case .text: return "Текст"
        case .sign: return "Подпись"
        }
    }
    var icon: String {
        switch self {
        case .crop: return "crop.rotate"
        case .filters: return "camera.filters"
        case .adjust: return "slider.horizontal.3"
        case .draw: return "pencil.tip"
        case .text: return "textformat"
        case .sign: return "signature"
        }
    }
}

enum InkKind: String, CaseIterable, Identifiable {
    case pen, marker, highlighter, eraser
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pen: return "Ручка"
        case .marker: return "Маркер"
        case .highlighter: return "Выделитель"
        case .eraser: return "Ластик"
        }
    }
    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .marker: return "paintbrush.pointed"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        }
    }
}

enum EditorPalette {
    static let colors: [UIColor] = [
        UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1),
        UIColor.white,
        UIColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1),
        UIColor(red: 1.0, green: 0.80, blue: 0.0, alpha: 1),
        UIColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1),
        UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
    ]
    static let names = ["Чёрный", "Белый", "Красный", "Жёлтый", "Синий", "Зелёный"]
    /// Оттенки подписи.
    static let signTints: [(UIColor, String)] = [
        (UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1), "Чёрный"),
        (UIColor(red: 0.05, green: 0.22, blue: 0.80, alpha: 1), "Синий"),
        (UIColor(red: 0.85, green: 0.12, blue: 0.12, alpha: 1), "Красный")
    ]
}

@Observable @MainActor
final class EditorModel {
    enum SaveMode { case newVersion, copy }
    enum SaveState: Equatable { case idle, working(String, Double), done }

    var tool: EditorTool = .crop
    var params = EditParams()
    var preview: UIImage?
    var previewHasCrop = false
    var loadFailed = false
    var thumbs: [FilterLook: UIImage] = [:]

    var drawing = PKDrawing()
    var canUndo = false
    var canRedo = false
    var ink: InkKind = .pen
    var inkColor = 4
    var inkWidth: Double = 6

    var overlays: [EditorOverlay] = []
    var selectedID: UUID?
    var canvasSize: CGSize = .zero

    /// Параметры геометрии, с которыми отрисовано текущее превью (поворот, отражение, обрезка).
    struct PreviewGeo: Equatable {
        var rotation = 0
        var flipH = false
        var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    }
    var previewGeo = PreviewGeo()
    /// Источник истины для рисунка: штрихи в пикселях исходника (не зависят от обрезки/поворота).
    @ObservationIgnored private(set) var inkRef = PKDrawing()
    /// Соответствие, в котором сейчас выражен `drawing` (экранные координаты).
    @ObservationIgnored private var inkMath: CropMath?

    var adjust: AdjustKind = .brightness
    var saveMode: SaveMode = .newVersion
    var saveState: SaveState = .idle

    @ObservationIgnored let sourceData: Data
    @ObservationIgnored private var previewSource: CIImage?
    @ObservationIgnored private var thumbSource: CIImage?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var thumbTask: Task<Void, Never>?
    @ObservationIgnored weak var canvas: PKCanvasView?

    init(data: Data) { sourceData = data }

    // MARK: Состояние

    var hasChanges: Bool {
        params != EditParams() || !drawing.strokes.isEmpty || !inkRef.strokes.isEmpty || !overlays.isEmpty
    }

    struct RenderKey: Equatable { var params: EditParams; var crop: Bool }
    /// Что именно влияет на превью: в режиме обрезки сама рамка превью не меняет.
    var renderKey: RenderKey {
        var p = params
        let crop = tool != .crop
        if !crop { p.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1); p.aspect = .free }
        return RenderKey(params: p, crop: crop)
    }

    var selected: EditorOverlay? { overlays.first { $0.id == selectedID } }
    var geometrySize: CGSize {
        let e = previewSource?.extent.size ?? CGSize(width: 1, height: 1)
        return ImageEditing.geometrySize(base: e, rotation: params.rotation)
    }

    // MARK: Загрузка и рендер

    func load() async {
        let data = sourceData
        let result = await Task.detached(priority: .userInitiated) {
            (ImageEditing.previewSource(from: data, maxPixel: 1600), ImageEditing.previewSource(from: data, maxPixel: 200))
        }.value
        previewSource = result.0
        thumbSource = result.1
        loadFailed = result.0 == nil
        scheduleRender()
    }

    func scheduleRender() {
        guard let src = previewSource else { return }
        let key = renderKey
        renderTask?.cancel()
        renderTask = Task.detached(priority: .userInitiated) { [model = self] in
            let ci = ImageEditing.process(src, key.params, applyCrop: key.crop)
            if Task.isCancelled { return }
            guard let cg = ImageEditing.render(ci, maxLongEdge: 1800) else { return }
            if Task.isCancelled { return }
            let ui = UIImage(cgImage: cg)
            await MainActor.run {
                model.preview = ui
                model.previewHasCrop = key.crop
                model.previewGeo = PreviewGeo(rotation: key.params.rotation, flipH: key.params.flipH,
                                              crop: key.crop ? key.params.cropRect : CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }
    }

    func refreshThumbs() {
        guard let src = thumbSource else { return }
        var base = params
        base.brightness = 0; base.contrast = 1; base.saturation = 1; base.sharpness = 0; base.vignette = 0
        let p = base
        thumbTask?.cancel()
        thumbTask = Task.detached(priority: .utility) { [model = self] in
            var out: [FilterLook: UIImage] = [:]
            for look in FilterLook.allCases {
                if Task.isCancelled { return }
                var q = p
                q.filter = look
                if let cg = ImageEditing.render(ImageEditing.process(src, q, applyCrop: true), maxLongEdge: 200) {
                    out[look] = UIImage(cgImage: cg)
                }
            }
            let result = out
            await MainActor.run { model.thumbs = result }
        }
    }

    // MARK: Геометрия

    func resetCrop() {
        params.cropRect = ImageEditing.cropRect(for: params.aspect.ratio, canvas: geometrySize)
    }
    func setAspect(_ a: CropAspect) {
        params.aspect = a
        resetCrop()
    }
    func rotate(_ delta: Int) {
        params.rotation = ((params.rotation + delta) % 4 + 4) % 4
        resetCrop()
    }
    func flip() {
        params.flipH.toggle()
        // отражение по горизонтали зеркалит и рамку
        let c = params.cropRect
        params.cropRect = CGRect(x: 1 - c.maxX, y: c.minY, width: c.width, height: c.height)
    }

    func resetAll() {
        params = EditParams()
        clearDrawing()
        overlays = []
        selectedID = nil
    }

    // MARK: Рисунок

    var pkTool: PKTool {
        let color = EditorPalette.colors[min(max(inkColor, 0), EditorPalette.colors.count - 1)]
        switch ink {
        case .pen: return PKInkingTool(.pen, color: color, width: CGFloat(inkWidth))
        case .marker: return PKInkingTool(.marker, color: color, width: CGFloat(inkWidth) * 1.6)
        case .highlighter: return PKInkingTool(.marker, color: color.withAlphaComponent(0.35), width: CGFloat(inkWidth) * 3.5)
        case .eraser: return PKEraserTool(.bitmap)
        }
    }

    /// Приводит рисунок в соответствие с тем, как сейчас показано превью (размер холста, обрезка, поворот).
    /// Штрихи хранятся в координатах исходника, поэтому смена обрезки/поворота их не сдвигает и не растягивает.
    func reconcileInk(viewSize: CGSize) {
        guard let src = previewSource, viewSize.width > 0, viewSize.height > 0 else { return }
        let g = previewGeo
        let m = CropMath(sourceSize: src.extent.size, rotation: g.rotation, flipH: g.flipH, crop: g.crop, viewSize: viewSize)
        guard m != inkMath else { return }
        inkMath = m
        let mapped = inkRef.strokes.isEmpty ? PKDrawing() : inkRef.transformed(using: m.sourceToView)
        drawing = mapped
        if let c = canvas {
            c.drawing = mapped
            // история отмены относится к прежним координатам
            c.undoManager?.removeAllActions()
        }
        canUndo = false
        canRedo = false
    }

    /// Рисунок в пикселях итогового изображения (для композиции при сохранении).
    nonisolated static func outputDrawing(_ ref: PKDrawing, sourceSize: CGSize, params p: EditParams, output: CGSize) -> PKDrawing {
        guard !ref.strokes.isEmpty, output.width > 0, output.height > 0 else { return PKDrawing() }
        let m = CropMath(sourceSize: sourceSize, rotation: p.rotation, flipH: p.flipH,
                         crop: p.cropRect, viewSize: output)
        return ref.transformed(using: m.sourceToOutput(output))
    }

    func syncDrawing(_ d: PKDrawing) {
        drawing = d
        if let m = inkMath { inkRef = d.transformed(using: m.viewToSource) }
        canUndo = canvas?.undoManager?.canUndo ?? false
        canRedo = canvas?.undoManager?.canRedo ?? false
    }
    func undo() {
        canvas?.undoManager?.undo()
        if let c = canvas { syncDrawing(c.drawing) }
    }
    func redo() {
        canvas?.undoManager?.redo()
        if let c = canvas { syncDrawing(c.drawing) }
    }
    func clearDrawing() {
        canvas?.drawing = PKDrawing()
        drawing = PKDrawing()
        inkRef = PKDrawing()
        canUndo = false
        canRedo = false
    }

    // MARK: Наложения

    func addText(_ s: String) {
        let o = EditorOverlay.text(s)
        overlays.append(o)
        selectedID = o.id
    }
    func addSignature(_ img: UIImage) {
        let o = EditorOverlay.signature(img)
        overlays.append(o)
        selectedID = o.id
    }
    func updateSelected(_ change: (inout EditorOverlay) -> Void) {
        guard let i = overlays.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&overlays[i])
    }
    func deleteSelected() {
        overlays.removeAll { $0.id == selectedID }
        selectedID = nil
    }

    // MARK: Сохранение

    static func isPNG(_ name: String) -> Bool { name.lowercased().hasSuffix(".png") }

    static func copyName(_ name: String) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension.lowercased()
        let base = ns.deletingPathExtension
        let newExt = ["png", "jpg", "jpeg"].contains(ext) ? ns.pathExtension : "jpg"
        return "\(base) (ред.).\(newExt)"
    }

    private func apply(_ p: UploadProgress) {
        let (title, idx): (String, Double)
        switch p.stage {
        case .encrypting: (title, idx) = ("Шифрование…", 0)
        case .uploading: (title, idx) = ("Отправка…", 1)
        case .verifying: (title, idx) = ("Проверка…", 2)
        case .done: (title, idx) = ("Готово", 3)
        }
        let total = p.stage == .done ? 1 : (idx + p.fraction) / 3
        saveState = .working(title, min(max(0.1 + total * 0.9, 0.1), 1))
    }

    /// Возвращает true при успехе.
    func save(store: AppStore, fileID: String, caseID: String, fileName: String) async -> Bool {
        saveState = .working("Обработка…", 0.05)
        let data = sourceData
        let p = params
        let d = inkRef
        let srcSize = previewSource?.extent.size ?? .zero
        let ov = overlays
        let png = Self.isPNG(fileName)
        let encoded: Data? = await Task.detached(priority: .userInitiated) {
            guard let src = ImageEditing.fullSource(from: data),
                  let cg = ImageEditing.render(ImageEditing.process(src, p, applyCrop: true), maxLongEdge: 8192) else { return nil }
            // штрихи переводятся в пиксели итога по реальной обрезке, масштаб по обеим осям
            let out = CGSize(width: cg.width, height: cg.height)
            let drawn = EditorModel.outputDrawing(d, sourceSize: srcSize, params: p, output: out)
            let ui = ImageEditing.composite(base: cg, drawing: drawn, canvasSize: out, overlays: ov)
            return png ? ui.pngData() : ui.jpegData(compressionQuality: 0.92)
        }.value
        guard let out = encoded else {
            saveState = .idle
            store.showToast("Не удалось обработать изображение", isError: true)
            return false
        }
        let progress: @Sendable (UploadProgress) -> Void = { [weak self] pr in
            Task { @MainActor in self?.apply(pr) }
        }
        do {
            switch saveMode {
            case .newVersion:
                _ = try await store.repo.replaceFileContent(fileID: fileID, data: out, progress: progress)
            case .copy:
                _ = try await store.repo.addFile(caseID: caseID, name: Self.copyName(fileName), kind: png ? .png : .jpg,
                                                 data: out, note: nil, progress: progress)
            }
        } catch {
            saveState = .idle
            store.showError(error)
            return false
        }
        saveState = .done
        Haptics.success()
        store.noteActivity()
        await store.refreshCases()
        return true
    }
}
