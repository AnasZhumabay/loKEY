import SwiftUI

/// Одна страница: картинка + подписи поверх неё (перетаскивание, щипок, поворот).
struct PDFPageCanvas: View {
    let pageIndex: Int
    let image: UIImage?
    let aspect: CGFloat          // высота / ширина страницы
    @Binding var signatures: [PDFPlacedSignature]
    @Binding var selectedID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let avail = CGSize(width: max(geo.size.width - 32, 1), height: max(geo.size.height - 16, 1))
            let fitW = min(avail.width, avail.height / max(aspect, 0.1))
            let size = CGSize(width: fitW, height: fitW * aspect)
            ZStack {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().interpolation(.high)
                    } else {
                        Color.white.overlay(ProgressView().tint(.gray))
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(reduceMotion ? nil : LKMotion.snappy) { selectedID = nil }
                }
                .accessibilityLabel(trf("Страница %lld", pageIndex + 1))

                ForEach($signatures) { $sig in
                    if sig.page == pageIndex {
                        PDFSignatureItem(sig: $sig, pageSize: size, isSelected: selectedID == sig.id) {
                            if selectedID != sig.id { Haptics.soft() }
                            withAnimation(reduceMotion ? nil : LKMotion.snappy) { selectedID = sig.id }
                        }
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width, height: size.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

/// Подпись-оверлей. Позиция/размер хранятся нормализованно; жесты применяются «вживую» и фиксируются по окончании.
struct PDFSignatureItem: View {
    @Binding var sig: PDFPlacedSignature
    let pageSize: CGSize
    let isSelected: Bool
    let onSelect: () -> Void

    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var twist: Angle = .zero

    var body: some View {
        let w = max(sig.width * pageSize.width, 8)
        let h = w * sig.aspect
        let dateH = sig.withDate ? w * PDFPlacedSignature.dateBand : 0
        VStack(spacing: 0) {
            Image(uiImage: sig.image).resizable().scaledToFit().frame(width: w, height: h)
            if sig.withDate {
                Text(PDFPlacedSignature.dateText)
                    .font(.system(size: w * PDFPlacedSignature.dateFont, weight: .medium))
                    .foregroundStyle(sig.tint.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: w, height: dateH)
            }
        }
        .frame(width: w, height: h + dateH)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.lkAccent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .padding(-6)
                .opacity(isSelected ? 1 : 0)
        )
        .contentShape(Rectangle().inset(by: -6))
        .scaleEffect(pinch)
        .rotationEffect(sig.rotation + twist)
        .position(x: sig.center.x * pageSize.width + drag.width,
                  y: sig.center.y * pageSize.height + drag.height)
        .gesture(
            DragGesture(minimumDistance: 2)
                .updating($drag) { v, s, _ in s = v.translation }
                .onChanged { _ in if !isSelected { onSelect() } }
                .onEnded { v in
                    let nx = sig.center.x + v.translation.width / pageSize.width
                    let ny = sig.center.y + v.translation.height / pageSize.height
                    sig.center = CGPoint(x: min(max(nx, 0.02), 0.98), y: min(max(ny, 0.02), 0.98))
                }
                .simultaneously(with:
                    MagnifyGesture()
                        .updating($pinch) { v, s, _ in s = v.magnification }
                        .onEnded { v in sig.width = min(max(sig.width * v.magnification, 0.08), 0.95) }
                )
                .simultaneously(with:
                    RotateGesture()
                        .updating($twist) { v, s, _ in s = v.rotation }
                        .onEnded { v in sig.rotation = sig.rotation + v.rotation }
                )
        )
        .onTapGesture { onSelect() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Подпись")
        .accessibilityHint("Перетащите, чтобы переместить")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
