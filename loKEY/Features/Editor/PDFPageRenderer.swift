import SwiftUI
import UIKit
import CoreGraphics

// MARK: - Модель подписи на странице

enum PDFInkTint: String, CaseIterable, Identifiable {
    case black, blue
    var id: String { rawValue }
    var uiColor: UIColor {
        switch self {
        case .black: return UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        case .blue: return UIColor(red: 0.10, green: 0.25, blue: 0.80, alpha: 1)
        }
    }
    var color: Color { Color(uiColor) }
    var title: String { self == .black ? "Чёрный" : "Синий" }
}

/// Подпись, поставленная на страницу. Геометрия нормализована (0...1 от размера отображаемой страницы),
/// поэтому не зависит от размера экрана и от поворота/cropBox страницы.
struct PDFPlacedSignature: Identifiable {
    let id = UUID()
    var page: Int
    let original: UIImage
    private(set) var image: UIImage
    private(set) var tint: PDFInkTint
    var center: CGPoint = CGPoint(x: 0.5, y: 0.72)
    /// Ширина как доля ширины страницы
    var width: CGFloat = 0.36
    var rotation: Angle = .zero
    var withDate = false

    init(page: Int, original: UIImage, tint: PDFInkTint = .black) {
        self.page = page
        self.original = original
        self.tint = tint
        self.image = PDFPlacedSignature.tinted(original, tint.uiColor)
    }

    mutating func setTint(_ t: PDFInkTint) {
        guard t != tint else { return }
        tint = t
        image = PDFPlacedSignature.tinted(original, t.uiColor)
    }

    var aspect: CGFloat {
        let s = original.size
        return s.width > 0 ? s.height / s.width : 0.4
    }
    /// Высота блока даты относительно ширины подписи
    static let dateBand: CGFloat = 0.2
    static let dateFont: CGFloat = 0.12
    /// Общая высота блока (подпись + дата) относительно ширины подписи
    var blockAspect: CGFloat { aspect + (withDate ? Self.dateBand : 0) }

    static func tinted(_ img: UIImage, _ color: UIColor) -> UIImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = img.scale
        f.opaque = false
        return UIGraphicsImageRenderer(size: img.size, format: f).image { ctx in
            let r = CGRect(origin: .zero, size: img.size)
            img.draw(in: r)
            color.setFill()
            ctx.cgContext.setBlendMode(.sourceIn)
            ctx.cgContext.fill(r)
        }
    }

    static var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy"
        return f.string(from: Date())
    }
}

// MARK: - Геометрия и рендер страниц (CGPDFDocument, без временных файлов)

enum PDFGeometry {
    /// Размер страницы в точках с учётом /Rotate и cropBox.
    static func displaySize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rot = ((page.rotationAngle % 360) + 360) % 360
        let s = (rot == 90 || rot == 270) ? CGSize(width: box.height, height: box.width) : box.size
        return (s.width < 1 || s.height < 1) ? CGSize(width: 612, height: 792) : s
    }

    /// Рисует страницу (вектор) в контекст с UIKit-ориентацией (начало слева сверху) в прямоугольник `dest`.
    static func draw(_ page: CGPDFPage, in cg: CGContext, dest: CGRect) {
        cg.saveGState()
        cg.setFillColor(UIColor.white.cgColor)
        cg.fill(dest)
        cg.clip(to: dest)
        cg.translateBy(x: dest.minX, y: dest.maxY)
        cg.scaleBy(x: 1, y: -1)
        let t = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: dest.size), rotate: 0, preserveAspectRatio: true)
        cg.concatenate(t)
        cg.drawPDFPage(page)
        cg.restoreGState()
    }

    static func document(_ data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) else { return nil }
        if doc.isEncrypted && !doc.isUnlocked { _ = doc.unlockWithPassword("") }
        return doc.isUnlocked ? doc : nil
    }
}

/// Рендерит страницы в картинки по запросу. Актор — CGPDFDocument не потокобезопасен.
actor PDFPageRenderer {
    private let doc: CGPDFDocument
    let pageCount: Int
    nonisolated let sizes: [CGSize]

    init?(data: Data) {
        guard let d = PDFGeometry.document(data), d.numberOfPages > 0 else { return nil }
        doc = d
        pageCount = d.numberOfPages
        sizes = (1...d.numberOfPages).map { i in d.page(at: i).map(PDFGeometry.displaySize) ?? CGSize(width: 612, height: 792) }
    }

    func render(page index: Int, width: CGFloat) -> UIImage? {
        guard let p = doc.page(at: index + 1) else { return nil }
        let size = PDFGeometry.displaySize(p)
        let h = (width * size.height / size.width).rounded()
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: h), format: f).image { ctx in
            PDFGeometry.draw(p, in: ctx.cgContext, dest: CGRect(x: 0, y: 0, width: width, height: h))
        }
    }
}

// MARK: - Сведение (flatten)

enum PDFFlattener {
    /// Перерисовывает все страницы как вектор в новый PDF и накладывает подписи.
    static func flatten(data: Data, signatures: [PDFPlacedSignature]) -> Data? {
        guard let doc = PDFGeometry.document(data), doc.numberOfPages > 0 else { return nil }
        let first = doc.page(at: 1).map(PDFGeometry.displaySize) ?? CGSize(width: 612, height: 792)
        let fmt = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first), format: fmt)
        let dateStr = PDFPlacedSignature.dateText
        return renderer.pdfData { ctx in
            for i in 1...doc.numberOfPages {
                guard let page = doc.page(at: i) else { continue }
                let size = PDFGeometry.displaySize(page)
                let rect = CGRect(origin: .zero, size: size)
                ctx.beginPage(withBounds: rect, pageInfo: [:])
                PDFGeometry.draw(page, in: ctx.cgContext, dest: rect)
                for s in signatures where s.page == i - 1 {
                    drawSignature(s, dateText: dateStr, pageSize: size, in: ctx.cgContext)
                }
            }
        }
    }

    private static func drawSignature(_ s: PDFPlacedSignature, dateText: String, pageSize: CGSize, in cg: CGContext) {
        let w = s.width * pageSize.width
        let h = w * s.aspect
        let total = w * s.blockAspect
        cg.saveGState()
        cg.translateBy(x: s.center.x * pageSize.width, y: s.center.y * pageSize.height)
        cg.rotate(by: CGFloat(s.rotation.radians))
        s.image.draw(in: CGRect(x: -w / 2, y: -total / 2, width: w, height: h))
        if s.withDate {
            let font = UIFont.systemFont(ofSize: w * PDFPlacedSignature.dateFont, weight: .medium)
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let str = NSAttributedString(string: dateText, attributes: [
                .font: font, .foregroundColor: s.tint.uiColor, .paragraphStyle: para
            ])
            let bandH = w * PDFPlacedSignature.dateBand
            let th = str.size().height
            str.draw(in: CGRect(x: -w / 2, y: -total / 2 + h + (bandH - th) / 2, width: w, height: th))
        }
        cg.restoreGState()
    }
}
