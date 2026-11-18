import UIKit
import UniformTypeIdentifiers
import ImageIO

/// Элемент, готовый к сохранению (данные только в памяти).
struct ShareEntry: Identifiable {
    let id = UUID()
    var name: String
    var data: Data?
    var thumbnail: UIImage?
    var kind: String
    var problem: String?
    var saved = false
    var bytes: Int { data?.count ?? 0 }
}

@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, saving, done, failed(String) }

    @Published var phase: Phase = .loading
    @Published var entries: [ShareEntry] = []
    @Published var progress: Double = 0

    private let providers: [NSItemProvider]
    private let finishHandler: () -> Void
    private let cancelHandler: () -> Void

    init(providers: [NSItemProvider], finish: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.providers = providers
        self.finishHandler = finish
        self.cancelHandler = cancel
    }

    var readyEntries: [ShareEntry] { entries.filter { $0.data != nil } }

    func cancel() { cancelHandler() }
    func finish() { finishHandler() }

    // MARK: Загрузка вложений

    func load() {
        Task {
            var result: [ShareEntry] = []
            for (i, p) in providers.enumerated() {
                result.append(await Self.makeEntry(from: p, index: i))
            }
            entries = result
            phase = result.isEmpty ? .failed("Нечего сохранять: вложения не найдены.") : .ready
        }
    }

    private static func makeEntry(from provider: NSItemProvider, index: Int) async -> ShareEntry {
        let ids = provider.registeredTypeIdentifiers
        let types = ids.compactMap { UTType($0) }
        let preferred: String? =
            ids.first(where: { UTType($0)?.conforms(to: .image) == true })
            ?? ids.first(where: { UTType($0)?.conforms(to: .pdf) == true })
            ?? ids.first(where: { UTType($0)?.conforms(to: .movie) == true })
            ?? ids.first(where: { id in
                guard let t = UTType(id) else { return false }
                return t.conforms(to: .data) && t != .url && t != .fileURL
            })
        let ext = types.first(where: { $0 != .fileURL && $0 != .url })?.preferredFilenameExtension

        // 1) Файл через loadFileRepresentation (память под контролем: размер проверяем до чтения)
        if let id = preferred {
            if let r = await loadFile(provider, typeID: id) {
                return finalize(name: r.name ?? provider.suggestedName, ext: UTType(id)?.preferredFilenameExtension ?? ext, data: r.data,
                                problem: r.problem, index: index)
            }
        }
        // 2) file-url (Файлы, AirDrop и т.п.)
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let r = await loadFileURL(provider) {
            return finalize(name: r.name, ext: ext, data: r.data, problem: r.problem, index: index)
        }
        // 3) Изображение как UIImage/URL/Data
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let r = await loadImageItem(provider) {
            return finalize(name: r.name ?? provider.suggestedName, ext: r.ext ?? "jpg", data: r.data, problem: r.problem, index: index)
        }
        return ShareEntry(name: provider.suggestedName ?? "Файл \(index + 1)", data: nil, thumbnail: nil, kind: "other",
                          problem: "Этот тип вложения не поддерживается.")
    }

    private struct Loaded { var name: String?; var ext: String?; var data: Data?; var problem: String? }

    private static func readLimited(_ url: URL) -> (Data?, String?) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > InboxStore.maxItemBytes {
            return (nil, "Файл больше \(InboxStore.maxItemBytes >> 20) МБ.")
        }
        do { return (try Data(contentsOf: url, options: .mappedIfSafe), nil) }
        catch { return (nil, "Не удалось прочитать файл.") }
    }

    private static func loadFile(_ p: NSItemProvider, typeID: String) async -> Loaded? {
        await withCheckedContinuation { (c: CheckedContinuation<Loaded?, Never>) in
            _ = p.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                guard let url else { c.resume(returning: nil); return }
                let (d, prob) = readLimited(url)
                c.resume(returning: Loaded(name: url.lastPathComponent, ext: nil, data: d, problem: prob))
            }
        }
    }

    private static func loadFileURL(_ p: NSItemProvider) async -> Loaded? {
        await withCheckedContinuation { (c: CheckedContinuation<Loaded?, Never>) in
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let u = item as? URL { url = u }
                else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                guard let url else { c.resume(returning: nil); return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let (d, prob) = readLimited(url)
                c.resume(returning: Loaded(name: url.lastPathComponent, ext: nil, data: d, problem: prob))
            }
        }
    }

    private static func loadImageItem(_ p: NSItemProvider) async -> Loaded? {
        await withCheckedContinuation { (c: CheckedContinuation<Loaded?, Never>) in
            p.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                if let img = item as? UIImage {
                    guard let d = img.jpegData(compressionQuality: 0.92) else { c.resume(returning: nil); return }
                    c.resume(returning: Loaded(name: nil, ext: "jpg", data: d, problem: d.count > InboxStore.maxItemBytes ? "Файл больше \(InboxStore.maxItemBytes >> 20) МБ." : nil))
                } else if let u = item as? URL {
                    let scoped = u.startAccessingSecurityScopedResource()
                    defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                    let (d, prob) = readLimited(u)
                    c.resume(returning: Loaded(name: u.lastPathComponent, ext: nil, data: d, problem: prob))
                } else if let d = item as? Data {
                    c.resume(returning: Loaded(name: nil, ext: "jpg", data: d, problem: d.count > InboxStore.maxItemBytes ? "Файл больше \(InboxStore.maxItemBytes >> 20) МБ." : nil))
                } else { c.resume(returning: nil) }
            }
        }
    }

    private static func finalize(name: String?, ext: String?, data: Data?, problem: String?, index: Int) -> ShareEntry {
        var n = (name?.isEmpty == false) ? name! : "Файл \(index + 1)"
        if (n as NSString).pathExtension.isEmpty, let ext, !ext.isEmpty { n += "." + ext }
        let kind = InboxStore.kind(forName: n)
        var thumb: UIImage?
        if let data, ["jpg", "png", "heic"].contains(kind) { thumb = downsample(data, maxPixel: 120) }
        return ShareEntry(name: n, data: data, thumbnail: thumb, kind: kind, problem: problem)
    }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Сохранение

    func save() {
        guard phase == .ready || { if case .failed = phase { return true } else { return false } }() else { return }
        let todo = entries.indices.filter { entries[$0].data != nil && !entries[$0].saved }
        guard !todo.isEmpty else { phase = .failed("Нет файлов, которые можно сохранить."); return }
        phase = .saving
        progress = 0
        Task {
            for (n, i) in todo.enumerated() {
                guard let data = entries[i].data else { continue }
                let name = entries[i].name
                do {
                    try await Task.detached(priority: .userInitiated) { try InboxStore.add(name: name, data: data) }.value
                    entries[i].saved = true
                    withAnimationIfPossible { self.progress = Double(n + 1) / Double(todo.count) }
                } catch {
                    phase = .failed(error.localizedDescription)
                    return
                }
            }
            phase = .done
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            finish()
        }
    }

    private func withAnimationIfPossible(_ body: () -> Void) { body() }

    func backToList() { phase = .ready }
}
