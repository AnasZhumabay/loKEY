import XCTest
import PDFKit
import PencilKit
@testable import loKEY

final class EditorTests: XCTestCase {
    private func close(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: eps, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: eps, file: file, line: line)
    }

    // MARK: CropMath

    func testNoCropIsUniformScale() {
        let m = CropMath(sourceSize: CGSize(width: 2000, height: 1000), viewSize: CGSize(width: 400, height: 200))
        close(CGPoint(x: 1000, y: 500).applying(m.sourceToView), CGPoint(x: 200, y: 100))
        XCTAssertEqual(m.viewScale, 0.2, accuracy: 1e-9)
    }

    func testCropAcrossAspectRatios() {
        let ratios: [(CGSize, CGRect, CGSize)] = [
            (CGSize(width: 4000, height: 3000), CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.5), CGSize(width: 300, height: 225)),
            (CGSize(width: 3000, height: 4000), CGRect(x: 0.0, y: 0.3, width: 1.0, height: 0.25), CGSize(width: 300, height: 100)),
            (CGSize(width: 1000, height: 1000), CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), CGSize(width: 240, height: 240))
        ]
        for (src, crop, view) in ratios {
            let m = CropMath(sourceSize: src, crop: crop, viewSize: view)
            // верхний левый угол обрезки -> (0,0) экрана; нижний правый -> правый нижний угол холста (по ширине)
            close(CGPoint(x: crop.minX * src.width, y: crop.minY * src.height).applying(m.sourceToView), .zero, 1e-6)
            let br = CGPoint(x: crop.maxX * src.width, y: crop.maxY * src.height).applying(m.sourceToView)
            XCTAssertEqual(br.x, view.width, accuracy: 1e-6)
            // пропорции сохраняются (равномерный масштаб): высота ≈ ширина × соотношение обрезки
            let expectH = view.width * (crop.height * src.height) / (crop.width * src.width)
            XCTAssertEqual(br.y, expectH, accuracy: 1e-6)
        }
    }

    func testRotate90Clockwise() {
        // исходник 200x100, после поворота по часовой 100x200; левый верхний угол уходит в правый верхний
        let m = CropMath(sourceSize: CGSize(width: 200, height: 100), rotation: 1, viewSize: CGSize(width: 100, height: 200))
        XCTAssertEqual(m.geometrySize, CGSize(width: 100, height: 200))
        close(CGPoint(x: 0, y: 0).applying(m.sourceToGeometry), CGPoint(x: 100, y: 0))
        close(CGPoint(x: 200, y: 0).applying(m.sourceToGeometry), CGPoint(x: 100, y: 200))
        close(CGPoint(x: 0, y: 100).applying(m.sourceToGeometry), CGPoint(x: 0, y: 0))
        let m4 = CropMath(sourceSize: CGSize(width: 200, height: 100), rotation: 4, viewSize: CGSize(width: 200, height: 100))
        close(CGPoint(x: 37, y: 11).applying(m4.sourceToGeometry), CGPoint(x: 37, y: 11))
    }

    func testFlip() {
        let m = CropMath(sourceSize: CGSize(width: 200, height: 100), flipH: true, viewSize: CGSize(width: 200, height: 100))
        close(CGPoint(x: 10, y: 20).applying(m.sourceToGeometry), CGPoint(x: 190, y: 20))
    }

    func testRoundTripAllRotations() {
        for r in 0..<4 {
            for flip in [false, true] {
                let m = CropMath(sourceSize: CGSize(width: 1600, height: 900), rotation: r, flipH: flip,
                                 crop: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5), viewSize: CGSize(width: 333, height: 250))
                let p = CGPoint(x: 421, y: 77)
                close(p.applying(m.sourceToView).applying(m.viewToSource), p, 1e-6)
            }
        }
    }

    func testCropChangeKeepsStrokeOnSameImagePoint() {
        // штрих хранится в пикселях исходника: смена обрезки меняет только отображение, но не точку на фото
        let src = CGSize(width: 1000, height: 500)
        let wide = CropMath(sourceSize: src, viewSize: CGSize(width: 400, height: 200))
        let tall = CropMath(sourceSize: src, crop: CGRect(x: 0.5, y: 0, width: 0.25, height: 1), viewSize: CGSize(width: 100, height: 200))
        let imagePoint = CGPoint(x: 600, y: 250)
        let onWide = imagePoint.applying(wide.sourceToView)
        close(onWide.applying(wide.viewToSource), imagePoint)
        let onTall = imagePoint.applying(tall.sourceToView)
        close(onTall, CGPoint(x: 40, y: 100))
    }

    func testOutputTransformBothAxes() {
        let src = CGSize(width: 1600, height: 900)
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let m = CropMath(sourceSize: src, crop: crop, viewSize: CGSize(width: 100, height: 56))
        let out = CGSize(width: 2000, height: 1125)   // полноразмерный вывод другого масштаба
        let t = m.sourceToOutput(out)
        close(CGPoint(x: 400, y: 225).applying(t), .zero)
        close(CGPoint(x: 1200, y: 675).applying(t), CGPoint(x: 2000, y: 1125))
    }

    func testDrawingKeepsShapeAfterCrop() {
        let ink = PKInkingTool(.pen, color: .black, width: 4).ink
        let pts = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)]
        let path = PKStrokePath(controlPoints: pts.enumerated().map {
            PKStrokePoint(location: $0.element, timeOffset: TimeInterval($0.offset), size: CGSize(width: 4, height: 4),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date())
        let ref = PKDrawing(strokes: [PKStroke(ink: ink, path: path)])
        let p = EditParams()
        var q = p
        q.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let out = EditorModel.outputDrawing(ref, sourceSize: CGSize(width: 800, height: 400), params: q, output: CGSize(width: 800, height: 800))
        // ширина обрезки 400 px -> 800 px (x2), высота 400 -> 800 (x2): горизонтальная линия остаётся горизонтальной, длина x2
        let b = out.bounds
        XCTAssertEqual(b.width, 400, accuracy: 12)
        XCTAssertLessThan(b.height, 20)
    }

    // MARK: PDF

    private func makePDF(rotation: Int = 0) -> Data? {
        let fmt = UIGraphicsPDFRendererFormat()
        let r = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400), format: fmt)
        let raw = r.pdfData { ctx in
            ctx.beginPage()
            "Hello".draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
            ctx.beginPage()
        }
        guard let doc = PDFDocument(data: raw), let page = doc.page(at: 0) else { return nil }
        page.rotation = rotation
        let note = PDFAnnotation(bounds: CGRect(x: 200, y: 300, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "note"
        page.addAnnotation(note)
        let hl = PDFAnnotation(bounds: CGRect(x: 20, y: 350, width: 80, height: 14), forType: .highlight, withProperties: nil)
        hl.color = .yellow
        page.addAnnotation(hl)
        return doc.dataRepresentation()
    }

    private func signatureImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 40)).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 5, y: 15, width: 110, height: 6))
        }
    }

    func testSignKeepsAnnotationsAndAddsSignature() throws {
        let pdf = try XCTUnwrap(makePDF())
        let before = try XCTUnwrap(PDFDocument(data: pdf)?.page(at: 0)?.annotations.count)
        XCTAssertGreaterThanOrEqual(before, 2)
        let out = try XCTUnwrap(PDFSigner.sign(pdfData: pdf, signature: signatureImage(),
                                               placements: [PDFSigner.Placement(page: 0)]))
        let doc = try XCTUnwrap(PDFDocument(data: out))
        XCTAssertEqual(doc.pageCount, 2)
        let anns = try XCTUnwrap(doc.page(at: 0)?.annotations)
        XCTAssertGreaterThanOrEqual(anns.count, before)
        XCTAssertEqual(anns.count, before + 1)
        XCTAssertTrue(anns.contains { ($0.type ?? "").lowercased().contains("stamp") })
        XCTAssertTrue(anns.contains { ($0.type ?? "").lowercased().contains("highlight") })
        XCTAssertEqual(doc.page(at: 1)?.annotations.count, 0)
    }

    func testSignOnRotatedPageStaysInsidePage() throws {
        let pdf = try XCTUnwrap(makePDF(rotation: 90))
        let out = try XCTUnwrap(PDFSigner.sign(pdfData: pdf, signature: signatureImage(),
                                               placements: [PDFSigner.Placement(page: 0, center: CGPoint(x: 0.5, y: 0.5), width: 0.3)]))
        let doc = try XCTUnwrap(PDFDocument(data: out))
        let page = try XCTUnwrap(doc.page(at: 0))
        let box = page.bounds(for: .cropBox)
        let stamp = try XCTUnwrap(page.annotations.first { ($0.type ?? "").lowercased().contains("stamp") })
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(stamp.bounds))
    }

    func testSignInvalidDataReturnsNil() {
        XCTAssertNil(PDFSigner.sign(pdfData: Data([1, 2, 3]), signature: signatureImage(), placements: [PDFSigner.Placement(page: 0)]))
    }

    func testPageRectMapping() {
        let box = CGRect(x: 0, y: 0, width: 300, height: 400)
        // без поворота: верх-лево отображения -> верх-лево страницы (y вверх)
        let r0 = PDFSigner.pageRect(display: CGRect(x: 10, y: 20, width: 50, height: 30), box: box, turns: 0, displaySize: box.size)
        XCTAssertEqual(r0, CGRect(x: 10, y: 350, width: 50, height: 30))
        // 90°: отображение 400x300; верх-лево отображения = низ-лево страницы
        let r1 = PDFSigner.pageRect(display: CGRect(x: 0, y: 0, width: 40, height: 20), box: box, turns: 1, displaySize: CGSize(width: 400, height: 300))
        XCTAssertEqual(r1, CGRect(x: 0, y: 0, width: 20, height: 40))
    }
}
