import SwiftUI
import UIKit

/// Разделы внутри кейса: каждый тип содержимого показывается по-своему.
enum CaseCategory: String, CaseIterable, Identifiable {
    case all = "Все", photos = "Фото", videos = "Видео", files = "Файлы", notes = "Заметки", secrets = "Пароли"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .photos: return "photo.on.rectangle"
        case .videos: return "play.rectangle"
        case .files: return "doc.text"
        case .notes: return "note.text"
        case .secrets: return "key.horizontal"
        }
    }
    var tint: Color {
        switch self {
        case .all: return .lkAccent
        case .photos: return Color(hex: 0x4DA3FF)
        case .videos: return Color(hex: 0xFF7EB6)
        case .files: return .lkWarn
        case .notes: return Color(hex: 0xFFC857)
        case .secrets: return .lkPurple
        }
    }
    var emptyTitle: String {
        switch self {
        case .all: return "В кейсе пока нет файлов"
        case .photos: return "Здесь пока нет фото"
        case .videos: return "Здесь пока нет видео"
        case .files: return "Здесь пока нет файлов"
        case .notes: return "Здесь пока нет заметок"
        case .secrets: return "Здесь пока нет паролей и карт"
        }
    }
    static func of(_ k: FileKind) -> CaseCategory {
        switch k {
        case .jpg, .heic, .png: return .photos
        case .video: return .videos
        case .pdf, .other: return .files
        case .note: return .notes
        case .password, .card: return .secrets
        }
    }
}

/// Кэш превью в памяти (расшифрованные миниатюры живут только пока приложение открыто).
@MainActor
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, UIImage>()
    private let texts = NSCache<NSString, NSString>()
    init() { cache.countLimit = 200; texts.countLimit = 200 }
    func image(_ id: String) -> UIImage? { cache.object(forKey: id as NSString) }
    func set(_ img: UIImage, _ id: String) { cache.setObject(img, forKey: id as NSString) }
    func text(_ id: String) -> String? { texts.object(forKey: id as NSString) as String? }
    func setText(_ t: String, _ id: String) { texts.setObject(t as NSString, forKey: id as NSString) }
    func clear() { cache.removeAllObjects(); texts.removeAllObjects() }
}

// MARK: - Панель разделов

struct CategoryBar: View {
    let counts: [CaseCategory: Int]
    @Binding var selection: CaseCategory
    @Namespace private var ns

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(CaseCategory.allCases) { c in
                    let n = counts[c] ?? 0
                    let on = selection == c
                    Button {
                        withAnimation(LKMotion.snappy) { selection = c }; Haptics.soft()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: c.icon).font(.system(size: 14, weight: .semibold))
                            Text(c.rawValue).font(.lk(13, on ? .heavy : .bold))
                            if n > 0 { Text("\(n)").font(.lkMono(11, .bold)).opacity(0.75) }
                        }
                        .foregroundStyle(on ? Color.lkBg : (n == 0 && c != .all ? Color.lkMuted.opacity(0.6) : Color.lkText2))
                        .padding(.horizontal, 13).frame(height: 40)
                        .background {
                            if on { Capsule().fill(c.tint).matchedGeometryEffect(id: "catPill", in: ns).shadow(color: c.tint.opacity(0.45), radius: 8) }
                            else { Capsule().fill(Color.white.opacity(0.06)) }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(LKPressStyle(scale: 0.94))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Ячейки

/// Квадратная миниатюра фото: расшифровывается лениво, в памяти.
struct PhotoThumb: View {
    let file: VaultFile
    @Environment(AppStore.self) private var store
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { g in
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                        .transition(.opacity)
                } else {
                    LinearGradient(colors: [Color(hex: 0x4DA3FF).opacity(0.22), Color.lkCard], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: failed ? "photo.badge.exclamationmark" : "photo").font(.system(size: 22, weight: .light)).foregroundStyle(Color.lkMuted)
                    if !failed { Color.clear.lkShimmer() }
                }
                if file.favorite {
                    VStack { HStack { Spacer(); Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color.lkAccent)
                        .padding(6).background(.ultraThinMaterial, in: Circle()) }; Spacer() }.padding(6)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .task(id: file.id) { await load() }
        .accessibilityLabel(trf("Фото %@", file.name))
    }

    private func load() async {
        if let c = ThumbCache.shared.image(file.id) { image = c; return }
        guard let d = try? await store.repo.openFile(id: file.id) else { failed = true; return }
        let thumb = await Task.detached(priority: .utility) { UIImage(data: d)?.preparingThumbnail(of: CGSize(width: 420, height: 420)) }.value
        guard let thumb else { failed = true; return }
        ThumbCache.shared.set(thumb, file.id)
        withAnimation(.easeOut(duration: 0.25)) { image = thumb }
    }
}

struct VideoCard: View {
    let file: VaultFile
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(hex: 0xFF7EB6).opacity(0.35), Color(hex: 0x7C5CE0).opacity(0.25), Color.lkCard], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "play.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                .frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.lk(13, .bold)).lineLimit(1)
                Text(LKFormat.bytes(file.bytes)).font(.lkMono(11, .medium)).opacity(0.75)
            }
            .foregroundStyle(.white).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            if file.favorite {
                Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color.lkAccent).padding(6)
                    .background(.ultraThinMaterial, in: Circle()).padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityLabel(trf("Видео %@", file.name))
    }
}

struct NoteCard: View {
    let file: VaultFile
    @Environment(AppStore.self) private var store
    @State private var text = ""
    private var tint: Color { Color(hex: 0xFFC857) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "note.text").font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
                Spacer()
                if file.favorite { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color.lkAccent) }
            }
            Text(file.name).font(.lk(14, .heavy)).lineLimit(2).multilineTextAlignment(.leading)
            if text.isEmpty { Capsule().fill(Color.white.opacity(0.08)).frame(height: 8).lkShimmer() }
            else { Text(text).font(.lk(12, .medium)).foregroundStyle(Color.lkText2).lineLimit(4).multilineTextAlignment(.leading) }
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(LinearGradient(colors: [tint.opacity(0.14), Color.lkCard], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(tint.opacity(0.22), lineWidth: 1))
        .task(id: file.id) {
            if let t = ThumbCache.shared.text(file.id) { text = t; return }
            guard let d = try? await store.repo.openFile(id: file.id), let s = String(data: d, encoding: .utf8) else { text = "—"; return }
            let t = String(s.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
            ThumbCache.shared.setText(t.isEmpty ? "—" : t, file.id)
            withAnimation(.easeOut(duration: 0.2)) { text = t.isEmpty ? "—" : t }
        }
        .accessibilityLabel(trf("Заметка %@", file.name))
    }
}
