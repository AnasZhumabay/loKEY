import CoreGraphics

/// Чистая математика «исходное изображение ↔ геометрия (поворот/отражение) ↔ обрезка ↔ экран ↔ вывод».
/// Все точки — в пикселях с началом в левом верхнем углу.
/// «Source» — пиксели исходника (без поворота), «geometry» — после поворота и отражения,
/// «view» — экранный холст, показывающий обрезанную область.
struct CropMath: Equatable, Sendable {
    var sourceSize: CGSize
    var rotation: Int = 0            // четверти оборота по часовой
    var flipH = false
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)   // нормализован в геометрии, верх-лево
    var viewSize: CGSize

    var turns: Int { ((rotation % 4) + 4) % 4 }

    var geometrySize: CGSize {
        turns % 2 == 0 ? sourceSize : CGSize(width: sourceSize.height, height: sourceSize.width)
    }

    /// Исходник → геометрия.
    var sourceToGeometry: CGAffineTransform {
        var t = CGAffineTransform.identity
        var w = sourceSize.width, h = sourceSize.height
        for _ in 0..<turns {
            // поворот на 90° по часовой в системе с началом сверху-слева: (x, y) → (h - y, x)
            t = t.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0))
            swap(&w, &h)
        }
        if flipH { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)) }
        return t
    }

    /// Масштаб «геометрия → экран» (одинаковый по обеим осям, считается по ширине).
    var viewScale: CGFloat {
        let cw = crop.width * geometrySize.width
        return cw > 0 ? viewSize.width / cw : 1
    }

    var geometryToView: CGAffineTransform {
        let g = geometrySize
        let s = viewScale
        return CGAffineTransform(translationX: -crop.minX * g.width, y: -crop.minY * g.height)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
    }

    var sourceToView: CGAffineTransform { sourceToGeometry.concatenating(geometryToView) }
    var viewToSource: CGAffineTransform { sourceToView.inverted() }

    /// Исходник → пиксели итогового (обрезанного) изображения размера `output`; масштаб считается по обеим осям.
    func sourceToOutput(_ output: CGSize) -> CGAffineTransform {
        let g = geometrySize
        let cw = crop.width * g.width, ch = crop.height * g.height
        guard cw > 0, ch > 0 else { return sourceToGeometry }
        return sourceToGeometry
            .concatenating(CGAffineTransform(translationX: -crop.minX * g.width, y: -crop.minY * g.height))
            .concatenating(CGAffineTransform(scaleX: output.width / cw, y: output.height / ch))
    }
}
