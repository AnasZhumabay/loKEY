import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Общий каркас шторки

struct SheetFrame<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule().fill(Color.lkTrack).frame(width: 40, height: 5).frame(maxWidth: .infinity)
            Text(title).font(.lk(22, .heavy))
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.lkBg)
        .foregroundStyle(Color.lkText)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Переместить в другой кейс

struct MoveSheet: View {
    let currentCaseID: String
    let fileIDs: [String]
    let onDone: () async -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    private var targets: [VaultCase] { store.unlockedCases.filter { $0.id != currentCaseID } }

    var body: some View {
        SheetFrame(title: "Переместить в кейс") {
            if targets.isEmpty {
                Text("Нет других открытых кейсов. Откройте нужный кейс ключом и повторите.")
                    .font(.lk(15, .medium)).foregroundStyle(Color.lkText2)
            } else {
                Text("Файлы будут перешифрованы ключом выбранного кейса.")
                    .font(.lk(14, .medium)).foregroundStyle(Color.lkText2)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(targets) { c in
                            Button { move(to: c) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: c.icon.systemName).font(.system(size: 18))
                                        .frame(width: 44, height: 44)
                                        .background(Color.lkRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.name).font(.lk(16, .bold))
                                        LevelTag(level: c.level)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(Color.lkMuted)
                                }
                                .padding(12).lkCard(radius: 18)
                            }
                            .buttonStyle(.plain).disabled(busy)
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func move(to c: VaultCase) {
        busy = true
        Task {
            do {
                try await store.repo.moveFiles(ids: fileIDs, toCaseID: c.id)
                await store.refreshCases()
                store.showToast(trf("Перемещено в «%@»", c.name))
                dismiss()
                await onDone()
            } catch {
                busy = false
                store.showError(error)
            }
        }
    }
}

// MARK: - Заметка

struct NoteSheet: View {
    let onSave: (String, String) -> Void   // (имя, текст)
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        SheetFrame(title: "Новая заметка") {
            LKField(title: "Название") { TextField("Например, Wi-Fi дома", text: $title) }
            VStack(alignment: .leading, spacing: 8) {
                Text("Текст").font(.lk(13, .bold)).foregroundStyle(Color.lkText2)
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .padding(10).frame(minHeight: 160)
                    .background(Color.lkCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
            }
            Button("Сохранить в кейс") {
                let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                onSave(name.isEmpty ? "Заметка" : name, text); dismiss()
            }
            .buttonStyle(.lkPrimary)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .presentationDetents([.large])
    }
}

// MARK: - Пароль / карта

struct SecretSheet: View {
    let onSave: (FileKind, String, String) -> Void   // (kind, имя, содержимое)
    @Environment(\.dismiss) private var dismiss
    @State private var isCard = false
    @State private var title = ""
    @State private var login = ""
    @State private var secret = ""
    @State private var extra = ""

    var body: some View {
        SheetFrame(title: "Пароль или карта") {
            Picker("Тип", selection: $isCard) {
                Text("Пароль").tag(false); Text("Карта").tag(true)
            }.pickerStyle(.segmented)
            LKField(title: "Название") { TextField(isCard ? "Например, Visa" : "Например, Почта", text: $title) }
            if isCard {
                LKField(title: "Номер карты") {
                    SecureField("•••• •••• •••• ••••", text: $secret).keyboardType(.numberPad).font(.lkMono(16, .semibold))
                }
                LKField(title: "Срок и CVC") { SecureField("MM/YY · CVC", text: $extra).font(.lkMono(16, .semibold)) }
            } else {
                LKField(title: "Логин") {
                    TextField("name@example.com", text: $login)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                LKField(title: "Пароль") { SecureField("Пароль", text: $secret) }
            }
            Text("Значения не показываются в списках и хранятся зашифрованными.")
                .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted)
            Button("Сохранить в кейс") {
                let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = isCard
                    ? "Карта: \(secret)\nСрок/CVC: \(extra)"
                    : "Логин: \(login)\nПароль: \(secret)"
                onSave(isCard ? .card : .password, name.isEmpty ? (isCard ? "Карта" : "Пароль") : name, body)
                dismiss()
            }
            .buttonStyle(.lkPrimary)
            .disabled(secret.isEmpty)
        }
        .presentationDetents([.large])
    }
}

// MARK: - Камера (JPEG только в памяти)

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage, let d = img.jpegData(compressionQuality: 0.9) {
                parent.onImage(d)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - Экспорт .key

struct KeyFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
