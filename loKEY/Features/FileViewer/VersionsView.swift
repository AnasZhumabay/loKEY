import SwiftUI
import UniformTypeIdentifiers

/// История версий файла: посмотреть, восстановить, загрузить новую. Всё расшифровывается в памяти.
struct VersionsSheet: View {
    let fileID: String
    let onChanged: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var versions: [FileVersion] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var busyID: String?
    @State private var progress: Double?
    @State private var showImporter = false
    @State private var confirmRestore: FileVersion?
    @State private var preview: PreviewItem?

    struct PreviewItem: Identifiable { let id = UUID(); let version: FileVersion; let data: Data }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Версии файла").font(.lk(20, .heavy))
                Spacer()
                Button("Готово") { dismiss() }.font(.lk(16, .bold)).foregroundStyle(Color.lkAccent).frame(minHeight: 44)
            }
            .padding(.horizontal, 20).padding(.top, 16)
            content
        }
        .lkScreen()
        .task { await load() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { r in
            if case .success(let url) = r { Task { await upload(url) } }
        }
        .confirmationDialog("Восстановить эту версию?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
                            titleVisibility: .visible, presenting: confirmRestore) { v in
            Button("Восстановить") { Task { await restore(v) } }
            Button("Отмена", role: .cancel) {}
        } message: { _ in Text("Текущая версия сохранится в истории — её можно будет вернуть.") }
        .sheet(item: $preview) { p in VersionPreview(item: p).presentationDetents([.large]).presentationBackground(Color.lkCard) }
    }

    @ViewBuilder private var content: some View {
        if loading && versions.isEmpty {
            Spacer(); ProgressView().tint(Color.lkAccent); Spacer()
        } else if let loadError, versions.isEmpty {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(Color.lkWarn)
                Text(loadError).font(.lk(15, .medium)).foregroundStyle(Color.lkText2).multilineTextAlignment(.center)
                Button("Повторить") { Task { await load() } }.buttonStyle(.lkSecondary).frame(maxWidth: 200)
            }.padding(24)
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Прежние версии хранятся зашифрованными тем же ключом кейса. Занимают место в хранилище.")
                        .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
                    VStack(spacing: 0) {
                        ForEach(Array(versions.enumerated()), id: \.element.id) { i, v in
                            if i > 0 { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
                            row(v, number: versions.count - i).lkAppear(i)
                        }
                    }
                    .padding(.horizontal, 16).lkCard(radius: 22)

                    if let progress {
                        ProgressView(value: progress).tint(Color.lkAccent)
                    }
                    Button { showImporter = true } label: {
                        Label("Загрузить новую версию", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.lkPrimary).disabled(busyID != nil || progress != nil)
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 32)
            }
        }
    }

    private func row(_ v: FileVersion, number: Int) -> some View {
        HStack(spacing: 12) {
            Text("v\(number)").font(.lkMono(13, .bold)).foregroundStyle(v.isCurrent ? Color.lkBg : Color.lkText2)
                .frame(width: 40, height: 40)
                .background(v.isCurrent ? Color.lkAccent : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: v.isCurrent ? tr("Текущая") : trf("Версия %lld", number)).font(.lk(15, .bold))
                }
                Text("\(Self.date.string(from: v.createdAt)) · \(LKFormat.bytes(v.bytes))").font(.lk(12, .medium)).foregroundStyle(Color.lkMuted)
            }
            Spacer(minLength: 8)
            if busyID == v.id { ProgressView().tint(Color.lkAccent) }
            else {
                Button { Task { await open(v) } } label: {
                    Image(systemName: "eye").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(LKPressStyle(scale: 0.88)).accessibilityLabel(trf("Посмотреть версию %lld", number))
                if !v.isCurrent {
                    Button { confirmRestore = v } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.lkAccent)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(LKPressStyle(scale: 0.88)).accessibilityLabel(trf("Восстановить версию %lld", number))
                }
            }
        }
        .frame(minHeight: 62)
    }

    private static var date: DateFormatter {
        let f = DateFormatter(); f.locale = LKBundle.uiLocale; f.dateStyle = .medium; f.timeStyle = .short; return f
    }

    private func load() async {
        loading = true; loadError = nil
        defer { loading = false }
        do { versions = try await store.repo.listVersions(fileID: fileID) }
        catch { loadError = (error as? VaultError)?.message ?? "Не удалось загрузить версии" }
    }
    private func open(_ v: FileVersion) async {
        busyID = v.id; defer { busyID = nil }
        do { preview = PreviewItem(version: v, data: try await store.repo.openVersion(fileID: fileID, versionID: v.id)); store.noteActivity() }
        catch { store.showError(error) }
    }
    private func restore(_ v: FileVersion) async {
        busyID = v.id; defer { busyID = nil }
        do {
            _ = try await store.repo.restoreVersion(fileID: fileID, versionID: v.id)
            await store.refreshCases(); Haptics.success(); store.showToast("Версия восстановлена")
            onChanged(); await load()
        } catch { store.showError(error) }
    }
    private func upload(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { store.showToast("Не удалось прочитать файл", isError: true); return }
        progress = 0; defer { progress = nil }
        do {
            _ = try await store.repo.replaceFileContent(fileID: fileID, data: data) { p in
                Task { @MainActor in progress = p.fraction }
            }
            await store.refreshCases(); Haptics.success(); store.showToast("Новая версия сохранена")
            onChanged(); await load()
        } catch { store.showError(error) }
    }
}

private struct VersionPreview: View {
    let item: VersionsSheet.PreviewItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(item.version.isCurrent ? "Текущая версия" : "Прежняя версия").font(.lk(18, .heavy))
                Spacer()
                Button("Закрыть") { dismiss() }.font(.lk(16, .bold)).foregroundStyle(Color.lkAccent).frame(minHeight: 44)
            }
            Group {
                if let img = UIImage(data: item.data) {
                    Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if let text = String(data: item.data, encoding: .utf8), item.data.count < 200_000 {
                    ScrollView { Text(text).font(.lkMono(13)).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: item.version.kind.systemName).font(.system(size: 40, weight: .light)).foregroundStyle(Color.lkMuted)
                        Text(verbatim: trf("Предпросмотр недоступен · %@", LKFormat.bytes(Int64(item.data.count)))).font(.lk(14, .medium)).foregroundStyle(Color.lkMuted)
                    }.frame(maxHeight: .infinity)
                }
            }
            Label("Открыто только в памяти", systemImage: "memorychip").font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted)
        }
        .padding(20)
    }
}
