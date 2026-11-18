// Небольшие настоящие файлы для демо-данных, чтобы предпросмотр работал.
import UIKit

enum DemoContent {
    static func pdf(title: String, subtitle: String = "Демо-документ loKEY") -> Data {
        let rect = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: rect).pdfData { ctx in
            ctx.beginPage()
            let t: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 28), .foregroundColor: UIColor.black]
            let s: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.darkGray]
            (title as NSString).draw(in: CGRect(x: 48, y: 72, width: 499, height: 80), withAttributes: t)
            (subtitle as NSString).draw(in: CGRect(x: 48, y: 160, width: 499, height: 24), withAttributes: s)
            UIColor.lightGray.setFill()
            for i in 0..<12 { UIRectFill(CGRect(x: 48, y: 220 + i * 28, width: i % 3 == 2 ? 300 : 499, height: 8)) }
        }
    }

    static func jpeg(title: String, tint: UIColor) -> Data {
        let size = CGSize(width: 900, height: 600)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let colors = [tint.withAlphaComponent(0.95).cgColor, UIColor.black.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let a: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 54), .foregroundColor: UIColor.white, .paragraphStyle: p]
            (title as NSString).draw(in: CGRect(x: 40, y: 240, width: 820, height: 140), withAttributes: a)
        }
        return img.jpegData(compressionQuality: 0.8) ?? Data()
    }
}
