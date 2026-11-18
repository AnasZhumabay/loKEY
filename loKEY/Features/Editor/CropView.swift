import SwiftUI

enum CropHandle: CaseIterable {
    case tl, t, tr, l, r, bl, b, br, move
}

enum CropRectMath {
    static let minSide: CGFloat = 56

    static func apply(start s: CGRect, handle: CropHandle, t: CGSize, bounds b: CGRect, ratio: CGFloat?) -> CGRect {
        if handle == .move {
            let x = min(max(s.minX + t.width, b.minX), b.maxX - s.width)
            let y = min(max(s.minY + t.height, b.minY), b.maxY - s.height)
            return CGRect(x: x, y: y, width: s.width, height: s.height)
        }
        let left = [CropHandle.tl, .l, .bl].contains(handle)
        let right = [CropHandle.tr, .r, .br].contains(handle)
        let top = [CropHandle.tl, .t, .tr].contains(handle)
        let bottom = [CropHandle.bl, .b, .br].contains(handle)
        let isCorner = (left || right) && (top || bottom)

        if let ratio, isCorner {
            let anchor = CGPoint(x: left ? s.maxX : s.minX, y: top ? s.maxY : s.minY)
            let moving = CGPoint(x: (left ? s.minX : s.maxX) + t.width, y: (top ? s.minY : s.maxY) + t.height)
            let dx: CGFloat = left ? -1 : 1
            let dy: CGFloat = top ? -1 : 1
            var w = max((moving.x - anchor.x) * dx, 0)
            var h = max((moving.y - anchor.y) * dy, 0)
            w = max(w, h * ratio)
            h = w / ratio
            let maxW = dx > 0 ? b.maxX - anchor.x : anchor.x - b.minX
            let maxH = dy > 0 ? b.maxY - anchor.y : anchor.y - b.minY
            if w > 0 {
                let k = min(1, maxW / w, maxH / h)
                w *= k; h *= k
            }
            if w < minSide { w = minSide; h = w / ratio }
            if h < minSide { h = minSide; w = h * ratio }
            return CGRect(x: dx > 0 ? anchor.x : anchor.x - w, y: dy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
        }

        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        if left { minX = min(max(s.minX + t.width, b.minX), s.maxX - minSide) }
        if right { maxX = max(min(s.maxX + t.width, b.maxX), s.minX + minSide) }
        if top { minY = min(max(s.minY + t.height, b.minY), s.maxY - minSide) }
        if bottom { maxY = max(min(s.maxY + t.height, b.maxY), s.minY + minSide) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Рамка обрезки поверх изображения. `rect` — нормализованный (0…1, верх-лево).
struct CropView: View {
    @Binding var rect: CGRect
    let aspect: CropAspect
    let size: CGSize

    @State private var start: CGRect?
    private let space = "lkCropSpace"

    private var r: CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }

    private func point(_ h: CropHandle, in r: CGRect) -> CGPoint {
        switch h {
        case .tl: return CGPoint(x: r.minX, y: r.minY)
        case .t: return CGPoint(x: r.midX, y: r.minY)
        case .tr: return CGPoint(x: r.maxX, y: r.minY)
        case .l: return CGPoint(x: r.minX, y: r.midY)
        case .r: return CGPoint(x: r.maxX, y: r.midY)
        case .bl: return CGPoint(x: r.minX, y: r.maxY)
        case .b: return CGPoint(x: r.midX, y: r.maxY)
        case .br: return CGPoint(x: r.maxX, y: r.maxY)
        case .move: return CGPoint(x: r.midX, y: r.midY)
        }
    }

    private func gesture(_ h: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { v in
                let s = start ?? r
                if start == nil { start = s; Haptics.soft() }
                let nr = CropRectMath.apply(start: s, handle: h, t: v.translation,
                                        bounds: CGRect(origin: .zero, size: size), ratio: aspect.ratio)
                rect = CGRect(x: nr.minX / size.width, y: nr.minY / size.height,
                              width: nr.width / size.width, height: nr.height / size.height)
            }
            .onEnded { _ in start = nil }
    }

    private var visibleHandles: [CropHandle] {
        aspect.ratio == nil ? [.tl, .tr, .bl, .br, .t, .b, .l, .r] : [.tl, .tr, .bl, .br]
    }

    var body: some View {
        let rr = r
        ZStack(alignment: .topLeading) {
            // затемнение вне рамки
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(rr)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // сетка третей и рамка
            Path { p in
                for i in 1...2 {
                    let x = rr.minX + rr.width * CGFloat(i) / 3
                    let y = rr.minY + rr.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: rr.minY)); p.addLine(to: CGPoint(x: x, y: rr.maxY))
                    p.move(to: CGPoint(x: rr.minX, y: y)); p.addLine(to: CGPoint(x: rr.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
            .allowsHitTesting(false)

            Rectangle().stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: rr.width, height: rr.height)
                .position(x: rr.midX, y: rr.midY)
                .allowsHitTesting(false)

            // перемещение
            Color.clear.contentShape(Rectangle())
                .frame(width: max(rr.width - 40, 0), height: max(rr.height - 40, 0))
                .position(x: rr.midX, y: rr.midY)
                .gesture(gesture(.move))
                .accessibilityHidden(true)

            // ручки
            ForEach(visibleHandles, id: \.self) { h in
                let pt = point(h, in: rr)
                let corner = [CropHandle.tl, .tr, .bl, .br].contains(h)
                ZStack {
                    if corner {
                        Circle().fill(Color.white).frame(width: 16, height: 16)
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    } else {
                        Capsule().fill(Color.white)
                            .frame(width: (h == .t || h == .b) ? 28 : 5, height: (h == .l || h == .r) ? 28 : 5)
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .position(pt)
                .gesture(gesture(h))
                .accessibilityLabel("Граница обрезки")
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: space)
    }
}
