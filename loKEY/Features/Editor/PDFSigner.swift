import UIKit
import PDFKit

/// Подпись PDF через PDFKit: подпись добавляется аннотацией-штампом, а существующие аннотации,
/// ссылки и поля форм остаются нетронутыми (в отличие от перерисовки через CGPDFDocument).
enum PDFSigner {
    /// Подпись на странице; геометрия нормализована (0...1 от размера отображаемой страницы, начало сверху-слева).
    struct Placement {
        var page: Int                    // с нуля
        var center: CGPoint = CGPoint(x: 0.5, y: 0.72)
        var width: CGFloat = 0.36        // доля ширины страницы
        var rotation: CGFloat = 0        // радианы по часовой
        var withDate = false
        var image: UIImage?              // если nil — общая подпись из `sign`
        var tint: UIColor?               // цвет даты
    }

    static let signatureName = "loKEY.signature"

    static func placements(from sigs: [PDFPlacedSignature]) -> [Placement] {
        sigs.map {
            Placement(page: $0.page, center: $0.center, width: $0.width, rotation: CGFloat($0.rotation.radians),
                      withDate: $0.withDate, image: $0.image, tint: $0.tint.uiColor)
        }
    }

    /// nil — если PDFKit не смог разобрать файл (тогда вызывающий откатывается на `PDFFlattener`).
    static func sign(pdfData: Data, signature: UIImage, placements: [Placement]) -> Data? {
        guard let doc = PDFDocument(data: pdfData), doc.pageCount > 0 else { return nil }
        if doc.isLocked && !doc.unlock(withPassword: "") { return nil }
        let dateStr = PDFPlacedSignature.dateText
        for p in placements {
            guard p.page >= 0, p.page < doc.pageCount, let page = doc.page(at: p.page) else { continue }
            let img = p.image ?? signature
            guard img.size.width > 0, img.size.height > 0 else { continue }
            let box = page.bounds(for: .cropBox)
            let turns = ((page.rotation / 90) % 4 + 4) % 4
            let display = displaySize(box: box, turns: turns)
            guard display.width > 0, display.height > 0 else { continue }

            // блок подписи (+дата) в системе отображения
            let w = p.width * display.width
            let h = w * img.size.height / img.size.width
            let band = p.withDate ? w * PDFPlacedSignature.dateBand : 0
            let total = h + band
            let c = abs(cos(p.rotation)), s = abs(sin(p.rotation))
            let bw = w * c + total * s, bh = w * s + total * c
            let center = CGPoint(x: p.center.x * display.width, y: p.center.y * display.height)
            let dRect = CGRect(x: center.x - bw / 2, y: center.y - bh / 2, width: bw, height: bh)

            let block = renderBlock(img: img, w: w, h: h, band: band, size: dRect.size, angle: p.rotation,
                                    dateText: p.withDate ? dateStr : nil, tint: p.tint ?? .black)
            let ann = SignatureStampAnnotation(bounds: pageRect(display: dRect, box: box, turns: turns, displaySize: display),
                                               image: block, displaySize: dRect.size, turns: turns)
            page.addAnnotation(ann)
        }
        return doc.dataRepresentation()
    }

    // MARK: Геометрия

    static func displaySize(box: CGRect, turns: Int) -> CGSize {
        turns % 2 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    /// Прямоугольник из системы отображения (начало сверху-слева, с учётом /Rotate) в систему страницы (снизу-слева, cropBox).
    static func pageRect(display r: CGRect, box: CGRect, turns: Int, displaySize d: CGSize) -> CGRect {
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {   // y вниз
            let W = box.width, H = box.height
            switch turns {
            case 1: return CGPoint(x: box.minX + y, y: box.minY + x)
            case 2: return CGPoint(x: box.minX + W - x, y: box.minY + y)
            case 3: return CGPoint(x: box.minX + W - y, y: box.minY + H - x)
            default: return CGPoint(x: box.minX + x, y: box.minY + H - y)
            }
        }
        let a = map(r.minX, r.minY), b = map(r.maxX, r.maxY)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private static func renderBlock(img: UIImage, w: CGFloat, h: CGFloat, band: CGFloat, size: CGSize,
                                    angle: CGFloat, dateText: String?, tint: UIColor) -> UIImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 3
        f.opaque = false
        let total = h + band
        return UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.rotate(by: angle)
            img.draw(in: CGRect(x: -w / 2, y: -total / 2, width: w, height: h))
            if let dateText {
                let font = UIFont.systemFont(ofSize: w * PDFPlacedSignature.dateFont, weight: .medium)
                let para = NSMutableParagraphStyle()
                para.alignment = .center
                let str = NSAttributedString(string: dateText, attributes: [
                    .font: font, .foregroundColor: tint, .paragraphStyle: para])
                let th = str.size().height
                str.draw(in: CGRect(x: -w / 2, y: -total / 2 + h + (band - th) / 2, width: w, height: th))
            }
        }
    }
}

/// Штамп-подпись: PDFKit при сохранении записывает результат `draw` как appearance stream.
final class SignatureStampAnnotation: PDFAnnotation {
    private let image: UIImage
    private let displaySize: CGSize
    private let turns: Int

    init(bounds: CGRect, image: UIImage, displaySize: CGSize, turns: Int) {
        self.image = image
        self.displaySize = displaySize
        self.turns = turns
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        _ = setValue(PDFSigner.signatureName, forAnnotationKey: .name)
        shouldDisplay = true
        shouldPrint = true
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        // отображение = страница, повёрнутая по часовой на turns × 90°, значит в системе страницы картинку надо повернуть против часовой
        context.rotate(by: CGFloat(turns) * .pi / 2)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: -displaySize.width / 2, y: -displaySize.height / 2,
                              width: displaySize.width, height: displaySize.height))
        UIGraphicsPopContext()
        context.restoreGState()
    }
}
