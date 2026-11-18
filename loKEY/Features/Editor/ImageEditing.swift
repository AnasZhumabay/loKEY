import UIKit
import CoreImage
import ImageIO
import PencilKit

// MARK: - Параметры правок

enum CropAspect: String, CaseIterable, Identifiable, Sendable {
    case free, square, r43, r34, r169
    var id: String { rawValue }
    var title: String {
        switch self {
        case .free: return "Свободно"
        case .square: return "1:1"
        case .r43: return "4:3"
        case .r34: return "3:4"
        case .r169: return "16:9"
        }
    }
    /// ширина / высота
    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .r43: return 4.0 / 3.0
        case .r34: return 3.0 / 4.0
        case .r169: return 16.0 / 9.0
        }
    }
}

enum FilterLook: String, CaseIterable, Identifiable, Sendable {
    case original, vivid, soft, mono, noir, chrome, fade, warm, cool
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Оригинал"
        case .vivid: return "Яркий"
        case .soft: return "Мягкий"
        case .mono: return "Ч/Б"
        case .noir: return "Нуар"
        case .chrome: return "Хром"
        case .fade: return "Фейд"
        case .warm: return "Тёплый"
        case .cool: return "Холодный"
        }
    }
}

enum AdjustKind: String, CaseIterable, Identifiable, Sendable {
    case brightness, contrast, saturation, sharpness, vignette
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brightness: return "Яркость"
        case .contrast: return "Контраст"
        case .saturation: return "Насыщенность"
        case .sharpness: return "Резкость"
        case .vignette: return "Виньетка"
        }
    }
    var icon: String {
        switch self {
        case .brightness: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .saturation: return "drop"
        case .sharpness: return "triangle"
        case .vignette: return "circle.dashed"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .brightness: return -0.5...0.5
        case .contrast: return 0.5...1.5
        case .saturation: return 0...2
        case .sharpness: return 0...2
        case .vignette: return 0...1
        }
    }
    var neutral: Double {
        switch self {
        case .brightness, .sharpness, .vignette: return 0
        case .contrast, .saturation: return 1
        }
    }
    var keyPath: WritableKeyPath<EditParams, Double> {
        switch self {
        case .brightness: return \.brightness
        case .contrast: return \.contrast
        case .saturation: return \.saturation
        case .sharpness: return \.sharpness
        case .vignette: return \.vignette
        }
    }
    /// Значение для показа пользователю: −100…100 (или 0…100).
    func display(_ v: Double) -> Int {
        let span = range.upperBound - range.lowerBound
        let scale: Double = neutral == range.lowerBound ? 100 : 200
        return Int(((v - neutral) / span * scale).rounded())
    }
}

struct EditParams: Equatable, Sendable {
    var rotation = 0                 // четверти оборота по часовой
    var flipH = false
    var straighten: Double = 0       // градусы, + по часовой
    var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)   // нормализованный, верх-лево
    var aspect: CropAspect = .free
    var filter: FilterLook = .original
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var sharpness: Double = 0
    var vignette: Double = 0

    var isFullCrop: Bool { cropRect == CGRect(x: 0, y: 0, width: 1, height: 1) }
}

// MARK: - Наложения (текст / подпись)

struct EditorOverlay: Identifiable {
    enum Kind { case text(String), signature }
    let id = UUID()
    var kind: Kind
    var source: UIImage?          // исходная подпись
    var display: UIImage?         // подпись с учётом цвета
    var color: UIColor?           // для текста — цвет, для подписи — оттенок (nil = исходный)
    var center = CGPoint(x: 0.5, y: 0.5)   // нормализованный
    var size: CGFloat             // подпись: доля ширины холста; текст: доля ширины холста для высоты шрифта
    var angle: CGFloat = 0        // радианы

    var isText: Bool { if case .text = kind { return true } else { return false } }
    var text: String { if case .text(let t) = kind { return t } else { return "" } }

    static func text(_ s: String) -> EditorOverlay {
        EditorOverlay(kind: .text(s), color: .white, size: 0.07)
    }
    static func signature(_ image: UIImage) -> EditorOverlay {
        EditorOverlay(kind: .signature, source: image, display: image, color: nil, size: 0.45)
    }
    mutating func setColor(_ c: UIColor?) {
        color = c
        if case .signature = kind, let s = source {
            if let c { display = s.tinted(c) } else { display = s }
        }
    }
}

extension UIImage {
    /// Перекрашивает непрозрачные пиксели в один цвет, сохраняя альфа-канал.
    func tinted(_ color: UIColor) -> UIImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = scale
        f.opaque = false
        let size = self.size
        return UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            let r = CGRect(origin: .zero, size: size)
            self.draw(in: r)
            color.setFill()
            ctx.cgContext.setBlendMode(.sourceIn)
            ctx.cgContext.fill(r)
        }
    }
}

// MARK: - Конвейер рендера (чистые функции, без UI)

enum ImageEditing {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Уменьшенный источник для превью, EXIF-ориентация уже применена.
    static func previewSource(from data: Data, maxPixel: Int) -> CIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var limit = maxPixel
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            limit = min(maxPixel, max(w, h))
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Полное разрешение, EXIF-ориентация применена.
    static func fullSource(from data: Data) -> CIImage? {
        guard let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        return origin(ci)
    }

    static func origin(_ img: CIImage) -> CIImage {
        let e = img.extent
        if e.minX == 0 && e.minY == 0 { return img }
        return img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    /// Размер холста после поворота (без обрезки).
    static func geometrySize(base: CGSize, rotation: Int) -> CGSize {
        rotation % 2 == 0 ? base : CGSize(width: base.height, height: base.width)
    }

    /// Нормализованный прямоугольник обрезки максимального размера с заданным соотношением по центру.
    static func cropRect(for ratio: CGFloat?, canvas: CGSize) -> CGRect {
        guard let ratio, canvas.width > 0, canvas.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var w = canvas.width, h = w / ratio
        if h > canvas.height { h = canvas.height; w = h * ratio }
        return CGRect(x: (canvas.width - w) / 2 / canvas.width, y: (canvas.height - h) / 2 / canvas.height,
                      width: w / canvas.width, height: h / canvas.height)
    }

    /// Поворот, отражение, выравнивание (без обрезки).
    static func geometry(_ input: CIImage, _ p: EditParams) -> CIImage {
        var img = origin(input)
        let turns = ((p.rotation % 4) + 4) % 4
        if turns != 0 {
            img = origin(img.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2)))
        }
        if p.flipH {
            let w = img.extent.width
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))
            img = origin(img)
        }
        if abs(p.straighten) > 0.01 {
            let w = img.extent.width, h = img.extent.height
            let th = CGFloat(-p.straighten) * .pi / 180
            let s = abs(cos(th)) + abs(sin(th)) * max(w / h, h / w)
            var t = CGAffineTransform(translationX: w / 2, y: h / 2)
            t = t.rotated(by: th)
            t = t.scaledBy(x: s, y: s)
            t = t.translatedBy(x: -w / 2, y: -h / 2)
            img = origin(img.transformed(by: t).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)))
        }
        return img
    }

    static func process(_ src: CIImage, _ p: EditParams, applyCrop: Bool) -> CIImage {
        var img = geometry(src, p)
        if applyCrop && !p.isFullCrop {
            let e = img.extent
            let c = p.cropRect
            let r = CGRect(x: c.minX * e.width, y: (1 - c.maxY) * e.height,
                           width: c.width * e.width, height: c.height * e.height).integral.intersection(e)
            if !r.isNull && r.width >= 1 && r.height >= 1 { img = origin(img.cropped(to: r)) }
        }
        img = look(img, p.filter)
        if p.brightness != 0 || p.contrast != 1 || p.saturation != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: p.brightness, kCIInputContrastKey: p.contrast, kCIInputSaturationKey: p.saturation])
        }
        if p.sharpness > 0.01 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: p.sharpness])
        }
        if p.vignette > 0.01 {
            img = img.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: p.vignette * 1.6, kCIInputRadiusKey: 1.6])
        }
        return img
    }

    private static func look(_ img: CIImage, _ f: FilterLook) -> CIImage {
        switch f {
        case .original: return img
        case .vivid:
            return img.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.8])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.1, kCIInputSaturationKey: 1.12])
        case .soft:
            return img.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.86, kCIInputBrightnessKey: 0.04, kCIInputSaturationKey: 0.92])
        case .mono: return img.applyingFilter("CIPhotoEffectMono")
        case .noir: return img.applyingFilter("CIPhotoEffectNoir")
        case .chrome: return img.applyingFilter("CIPhotoEffectChrome")
        case .fade: return img.applyingFilter("CIPhotoEffectFade")
        case .warm:
            return img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 4600, y: 0)])
        case .cool:
            return img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 9500, y: 0)])
        }
    }

    /// Растеризация; при необходимости уменьшает до `maxLongEdge`.
    static func render(_ image: CIImage, maxLongEdge: CGFloat) -> CGImage? {
        var img = origin(image)
        let e = img.extent
        let long = max(e.width, e.height)
        if long > maxLongEdge {
            let s = maxLongEdge / long
            img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
        }
        let out = img.extent.integral
        return context.createCGImage(img, from: out, format: .RGBA8, colorSpace: colorSpace)
    }

    // MARK: Композиция аннотаций

    static func composite(base: CGImage, drawing: PKDrawing?, canvasSize: CGSize, overlays: [EditorOverlay]) -> UIImage {
        let W = CGFloat(base.width), H = CGFloat(base.height)
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = true
        return UIGraphicsImageRenderer(size: rect.size, format: f).image { ctx in
            UIImage(cgImage: base).draw(in: rect)
            if let d = drawing, !d.strokes.isEmpty, canvasSize.width > 0 {
                var layer = UIImage()
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    layer = d.image(from: CGRect(origin: .zero, size: canvasSize), scale: W / canvasSize.width)
                }
                layer.draw(in: rect)
            }
            for o in overlays {
                let c = ctx.cgContext
                c.saveGState()
                c.translateBy(x: o.center.x * W, y: o.center.y * H)
                c.rotate(by: o.angle)
                switch o.kind {
                case .signature:
                    if let img = o.display, img.size.height > 0 {
                        let w = o.size * W
                        let h = w * img.size.height / img.size.width
                        img.draw(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                    }
                case .text(let s):
                    let font = UIFont.systemFont(ofSize: o.size * W, weight: .bold)
                    let para = NSMutableParagraphStyle()
                    para.alignment = .center
                    let shadow = NSShadow()
                    shadow.shadowColor = UIColor.black.withAlphaComponent(0.35)
                    shadow.shadowBlurRadius = o.size * W * 0.08
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font, .foregroundColor: o.color ?? UIColor.white, .paragraphStyle: para, .shadow: shadow]
                    let str = NSAttributedString(string: s, attributes: attrs)
                    let b = str.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin], context: nil)
                    str.draw(in: CGRect(x: -b.width / 2, y: -b.height / 2, width: b.width + 1, height: b.height + 1))
                }
                c.restoreGState()
            }
        }
    }
}
