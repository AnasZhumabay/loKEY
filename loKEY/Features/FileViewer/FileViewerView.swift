import SwiftUI
import PDFKit
import UIKit

/// Просмотр файла: расшифровка только в память.
struct FileViewerView: View {
    let fileID: String
    let caseID: String

    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    enum LoadState { case loading, ready, corrupted, failed(String) }

    @State private var state: LoadState = .loading
    @State private var file: VaultFile?
    @State private var data: Data?
    @State private var captured = UIScreen.main.isCaptured
    @State private var revealed = false
    @State private var note = ""
    @State private var editingNote = false
    @FocusState private var noteFocused: Bool
    @State private var confirmTrash = false
    @State private var showMove = false
    @State private var shareWarning = false
    @State private var shareItems: [Any]?
    @State private var showVersions = false
    @State private var showEditor = false
    @State private var showSign = false

    private var hidden: Bool { captured || store.isPrivacyCovered }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            switch state {
            case .loading:
                Spacer(); ProgressView().tint(Color.lkAccent); Spacer()
            case .corrupted:
                corrupted
            case .failed(let m):
                failed(m)
            case .ready:
                ready
            }
        }
        .lkScreen()
        .task { await load() }
        .fullScreenCover(isPresented: $showEditor) {
            if let d = data, let f = file {
                PhotoEditorView(fileID: fileID, caseID: caseID, fileName: f.name, imageData: d) { Task { await load(); await store.refreshCases() } }
            }
        }
        .fullScreenCover(isPresented: $showSign) {
            if let d = data, let f = file {
                PDFSignView(fileID: fileID, caseID: caseID, fileName: f.name, pdfData: d) { Task { await load(); await store.refreshCases() } }
            }
        }
        .sheet(isPresented: $showVersions) {
            VersionsSheet(fileID: fileID) { Task { await load() } }
                .presentationDetents([.large]).presentationBackground(Color.lkCard)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            captured = UIScreen.main.isCaptured
        }
        .onChange(of: store.vaultCase(caseID)?.isUnlocked) { _, v in
            if v == false { data = nil; router.popToRoot() }
        }
        .onDisappear { data = nil }
        .confirmationDialog("Переместить в корзину?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("В корзину", role: .destructive) { trash() }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Файл можно будет восстановить в течение 30 дней.") }
        .alert("Файл покинет защищённое хранилище", isPresented: $shareWarning) {
            Button("Поделиться", role: .destructive) { prepareShare() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Расшифрованный файл будет передан другому приложению. loKEY больше не сможет его защитить.")
        }
        .sheet(isPresented: $showMove) {
            MoveSheet(currentCaseID: caseID, fileIDs: [fileID]) {
                showMove = false
                await store.refreshCases()
                router.pop()
            }
        }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            if let items = shareItems { ActivityView(items: items).ignoresSafeArea() }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            LKIconButton(systemName: "chevron.left", label: "Назад") { router.pop() }
            VStack(alignment: .leading, spacing: 1) {
                Text(file?.name ?? "Файл").font(.lk(17, .heavy)).lineLimit(1)
                if let f = file {
                    HStack(spacing: 4) {
                        if let c = store.vaultCase(caseID) {
                            Image(systemName: "folder.fill").font(.system(size: 9))
                            Text(c.name).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        }
                        Text("\(f.kind.label) · \(LKFormat.bytes(f.bytes))").lineLimit(1)
                    }
                    .font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted)
                }
            }
            Spacer()
            if case .ready = state {
                Menu {
                    Button { store.noteActivity(); showVersions = true } label: { Label("Версии файла", systemImage: "clock.arrow.circlepath") }
                    Button { shareWarning = true } label: { Label("Поделиться", systemImage: "square.and.arrow.up") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Color.lkCard, in: Circle()).overlay(Circle().stroke(Color.lkBorder, lineWidth: 1))
                }
                .accessibilityLabel("Ещё")
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)
    }

    // MARK: Ready

    private var ready: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    ZStack {
                        preview
                            .blur(radius: hidden ? 30 : 0)
                            .allowsHitTesting(!hidden)
                        if hidden {
                            VStack(spacing: 8) {
                                Image(systemName: "eye.slash.fill").font(.system(size: 28))
                                Text(captured ? "Запись экрана включена. Содержимое скрыто." : "Содержимое скрыто")
                                    .font(.lk(14, .bold)).multilineTextAlignment(.center)
                            }
                            .padding(20)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(minHeight: 320)
                    .background(Color.lkCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Label("Открыт только в памяти", systemImage: "memorychip")
                            .font(.lk(11, .heavy)).foregroundStyle(Color.lkAccent)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Color.lkBg.opacity(0.85), in: Capsule()).padding(10)
                    }
                    infoCard
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            actionBar
        }
    }

    @ViewBuilder private var preview: some View {
        if let file, let data {
            switch file.kind {
            case .jpg, .png, .heic:
                if let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().scaledToFit().padding(8)
                        .accessibilityLabel(file.name)
                } else { generic("Не удалось показать изображение") }
            case .pdf:
                PDFPreview(data: data).frame(height: 460)
            case .note:
                Text(String(decoding: data, as: UTF8.self)).font(.lk(16, .medium))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20).textSelection(.enabled)
            case .password, .card:
                secretView(String(decoding: data, as: UTF8.self))
            default:
                generic(file.kind == .video ? "Предпросмотр видео недоступен" : "Предпросмотр недоступен")
            }
        }
    }

    private func generic(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: file?.kind.systemName ?? "doc").font(.system(size: 54, weight: .light)).foregroundStyle(Color.lkMuted)
            Text(text).font(.lk(14, .medium)).foregroundStyle(Color.lkMuted)
        }.padding(40)
    }

    private func secretView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(revealed ? text : String(repeating: "•", count: min(max(text.count, 8), 24)))
                .font(.lkMono(16, .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button { revealed.toggle(); store.noteActivity() } label: {
                Label(tr(revealed ? "Скрыть" : "Показать"), systemImage: revealed ? "eye.slash" : "eye")
                    .font(.lk(14, .bold)).foregroundStyle(Color.lkAccent).frame(minHeight: 44)
            }
        }
        .padding(20)
    }

    // MARK: Info

    private var infoCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Подпись").font(.lk(12, .heavy)).tracking(0.8).foregroundStyle(Color.lkMuted)
                TextField("Добавить подпись", text: $note, axis: .vertical)
                    .font(.lk(15, .medium)).lineLimit(1...5)
                    .focused($noteFocused)
                    .onChange(of: noteFocused) { _, f in if !f { saveNote() } }
                    .submitLabel(.done)
                    .onSubmit { noteFocused = false }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            divider
            infoRow("Размер", file.map { LKFormat.bytes($0.bytes) } ?? "")
            divider
            infoRow("Целостность", "Не изменён", color: .lkAccent)
            divider
            HStack {
                Text("Доступ офлайн").font(.lk(15, .semibold)).foregroundStyle(Color.lkText2)
                Spacer()
                Toggle("Доступ офлайн", isOn: Binding(get: { file?.offline ?? false }, set: { setOffline($0) }))
                    .labelsHidden().tint(Color.lkAccent)
            }
            .padding(.horizontal, 16).frame(minHeight: 52)
        }
        .lkCard(radius: 20)
    }

    private var divider: some View { Rectangle().fill(Color.lkBorder).frame(height: 1) }

    private func infoRow(_ t: String, _ v: String, color: Color = .lkText) -> some View {
        HStack {
            Text(t).font(.lk(15, .semibold)).foregroundStyle(Color.lkText2)
            Spacer()
            Text(v).font(.lk(15, .bold)).foregroundStyle(color)
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
    }

    private var isPhoto: Bool { [.jpg, .png, .heic].contains(file?.kind ?? .other) }

    private var actionBar: some View {
        HStack {
            barButton(file?.favorite == true ? "star.fill" : "star", "Избранное", tint: file?.favorite == true ? .lkAccent : .lkText) { toggleFav() }
            if isPhoto {
                barButton("wand.and.stars", "Редактор") { store.noteActivity(); showEditor = true }
            } else if file?.kind == .pdf {
                barButton("signature", "Подписать") { store.noteActivity(); showSign = true }
            }
            barButton("text.alignleft", "Описание") { noteFocused = true }
            barButton("folder", "Переместить") { store.noteActivity(); showMove = true }
            barButton("trash", "В корзину", tint: .lkDanger) { confirmTrash = true }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        .background(Color.lkBg.opacity(0.92))
        .overlay(alignment: .top) { Rectangle().fill(Color.lkBorder).frame(height: 1) }
    }

    private func barButton(_ icon: String, _ title: String, tint: Color = .lkText, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                Text(title).font(.lk(11, .bold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(tint).frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.plain)
    }

    // MARK: Corrupted / failed

    private var corrupted: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Color.lkDanger.opacity(0.12)).frame(width: 110, height: 110)
                    Image(systemName: "exclamationmark.shield.fill").font(.system(size: 50)).foregroundStyle(Color.lkDanger)
                }
                .padding(.top, 24)
                Text("ФАЙЛ НЕ ПРОШЁЛ ПРОВЕРКУ").font(.lk(11, .heavy)).tracking(1.2).foregroundStyle(Color.lkDanger)
                Text("Файл изменён\nили повреждён").font(.lk(26, .heavy)).multilineTextAlignment(.center)
                Text("Контрольная метка не совпала. Мы не открываем такие файлы, чтобы вы не работали с подменённым документом.")
                    .font(.lk(15, .medium)).foregroundStyle(Color.lkText2).multilineTextAlignment(.center)
                Button("Попробовать снова") { Task { await load() } }.buttonStyle(.lkPrimary)
                Button("В корзину") { trash() }.buttonStyle(.lkSecondary)
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.system(size: 38)).foregroundStyle(Color.lkWarn)
            Text(message).font(.lk(15, .medium)).foregroundStyle(Color.lkText2).multilineTextAlignment(.center)
            Button("Повторить") { Task { await load() } }.buttonStyle(.lkSecondary).frame(maxWidth: 220)
            Spacer()
        }.padding(24)
    }

    // MARK: Actions

    private func load() async {
        state = .loading
        data = nil
        do {
            let files = try await store.repo.listFiles(caseID: caseID)
            file = files.first { $0.id == fileID }
            note = file?.note ?? ""
            let d = try await store.repo.openFile(id: fileID)
            data = d
            state = .ready
            store.noteActivity()
        } catch let e as VaultError {
            if case .integrityFailed = e { state = .corrupted }
            else if case .notUnlocked = e { router.popToRoot() }
            else { state = .failed(e.message) }
        } catch {
            state = .failed("Не удалось открыть файл")
        }
    }

    private func saveNote() {
        guard let f = file else { return }
        let new = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard new != (f.note ?? "") else { return }
        Task {
            do {
                file = try await store.repo.updateFile(id: fileID, name: nil, note: new, favorite: nil, offline: nil)
                await store.refreshCases()
            } catch { store.showError(error) }
        }
    }

    private func toggleFav() {
        guard let f = file else { return }
        store.noteActivity()
        Task {
            do { file = try await store.repo.updateFile(id: fileID, name: nil, note: nil, favorite: !f.favorite, offline: nil); Haptics.soft() }
            catch { store.showError(error) }
        }
    }

    private func setOffline(_ on: Bool) {
        store.noteActivity()
        Task {
            do { file = try await store.repo.updateFile(id: fileID, name: nil, note: nil, favorite: nil, offline: on) }
            catch { store.showError(error) }
        }
    }

    private func trash() {
        Task {
            do {
                try await store.repo.trashFiles(ids: [fileID])
                await store.refreshCases()
                store.showToast("Перемещено в корзину")
                router.pop()
            } catch { store.showError(error) }
        }
    }

    private func prepareShare() {
        guard let data, let file else { return }
        if [.jpg, .png, .heic].contains(file.kind), let img = UIImage(data: data) { shareItems = [img] }
        else if file.kind == .note, let s = String(data: data, encoding: .utf8) { shareItems = [s] }
        else { shareItems = [data] }
    }
}

// MARK: - Helpers

private struct PDFPreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.backgroundColor = .clear
        v.document = PDFDocument(data: data)
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {}
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
