import SwiftUI
import UIKit
import CoreImage
import Vision
import PDFKit

// MARK: - Модель страницы и фильтры

enum ScanFilter: String, CaseIterable, Identifiable {
    case color, gray, document
    var id: String { rawValue }
    var title: String {
        switch self {
        case .color: return "Цвет"
        case .gray: return "Серый"
        case .document: return "Документ"
        }
    }
    var icon: String {
        switch self {
        case .color: return "photo"
        case .gray: return "circle.lefthalf.filled"
        case .document: return "doc.text.viewfinder"
        }
    }
}

enum ScanMode: String { case pdf, photos }

struct ScanPage: Identifiable {
    let id = UUID()
    /// Полноразмерная страница (в памяти), ориентация .up
    let full: UIImage
    /// Уменьшенная копия для превью
    let small: UIImage
    var turns: Int = 0
}

enum ScanError: LocalizedError {
    case render, pdf
    var errorDescription: String? {
        switch self {
        case .render: return "Не удалось обработать страницу."
        case .pdf: return "Не удалось собрать PDF."
        }
    }
}

/// Обёртка, чтобы переносить изображения между задачами.
struct ScanBox: @unchecked Sendable { let image: UIImage }

// MARK: - Обработка изображений, OCR, PDF

enum ScanEngine {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let maxStoredText = 50_000

    /// Приводит ориентацию к .up и ограничивает размер. Возвращает полную и малую версии.
    static func prepare(_ source: UIImage) -> (full: UIImage, small: UIImage) {
        let full = resized(source, maxSide: 3200)
        let small = resized(full, maxSide: 1400)
        return (full, small)
    }

    static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return image }
        let s = min(1, maxSide / max(w, h))
        if s >= 1 && image.imageOrientation == .up { return image }
        let size = CGSize(width: (w * s).rounded(), height: (h * s).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func render(_ image: UIImage, turns: Int, filter: ScanFilter, maxSide: CGFloat) -> UIImage? {
        guard var ci = CIImage(image: image) else { return nil }
        for _ in 0..<(((turns % 4) + 4) % 4) { ci = ci.oriented(.right) }
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        let longSide = max(ci.extent.width, ci.extent.height)
        if longSide > maxSide, longSide > 0 {
            let s = maxSide / longSide
            ci = ci.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
        }
        let extent = ci.extent
        switch filter {
        case .color:
            break
        case .gray:
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.08])
        case .document:
            let gray = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            let sigma = max(extent.width, extent.height) / 28
            let blurred = gray.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            // Выравниваем освещённость: фон -> белый, текст остаётся тёмным.
            let flat = blurred.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: gray])
            ci = flat.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.04),
                "inputPoint2": CIVector(x: 0.5, y: 0.32),
                "inputPoint3": CIVector(x: 0.75, y: 0.92),
                "inputPoint4": CIVector(x: 1, y: 1)
            ])
        }
        guard let cg = context.createCGImage(ci, from: extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    static func recognizeText(in image: UIImage) -> String {
        guard let cg = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    static func joinAndCap(_ texts: [String]) -> String? {
        let joined = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        if joined.isEmpty { return nil }
        return String(joined.prefix(maxStoredText))
    }

    /// PDF в порядке страниц. JPEG-данные сохраняют сжатие внутри PDF.
    static func makePDF(jpegs: [Data]) throws -> Data {
        let doc = PDFDocument()
        for d in jpegs {
            guard let probe = UIImage(data: d), probe.size.width > 0 else { throw ScanError.pdf }
            let scale = max(probe.size.width, probe.size.height) / 842
            guard let img = UIImage(data: d, scale: max(scale, 1)),
                  let page = PDFPage(image: img) else { throw ScanError.pdf }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.pageCount > 0, let data = doc.dataRepresentation() else { throw ScanError.pdf }
        return data
    }

    static func defaultName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return "Скан " + f.string(from: date).replacingOccurrences(of: ".", with: "")
    }
}

// MARK: - Камера документов (VisionKit)

import VisionKit

struct DocumentCameraView: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void
    let onCancel: () -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentCameraView
        init(_ parent: DocumentCameraView) { self.parent = parent }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onFinish(images)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.onCancel() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.onError(error) }
    }
}
