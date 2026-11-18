import SwiftUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Добавление собеседника только очным способом: свой QR показываешь, чужой сканируешь (или вставляешь приглашение).
struct AddContactView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router

    enum Mode: String, CaseIterable { case mine = "Мой код", scan = "Сканировать" }
    @State private var mode: Mode = .mine
    @State private var invite: ChatInvite?
    @State private var demo: String?
    @State private var pasted = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            LKTopBar(title: "Добавить контакт") { Color.clear }.padding(.horizontal, 20).padding(.top, 8)
            Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).padding(.horizontal, 20).padding(.top, 12)
            ScrollView {
                VStack(spacing: 16) {
                    if mode == .mine { mine } else { scan }
                    pasteBlock
                    if let demo { demoBlock(demo) }
                    if let error {
                        Label(tr(error), systemImage: "exclamationmark.triangle.fill").font(.lk(13, .semibold)).foregroundStyle(Color.lkDanger)
                            .frame(maxWidth: .infinity, alignment: .leading).transition(.opacity)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 40)
                .animation(LKMotion.snappy, value: mode)
            }
            .scrollIndicators(.hidden)
        }
        .lkScreen()
        .navigationBarBackButtonHidden(true).toolbar(.hidden, for: .navigationBar)
        .task {
            invite = try? await store.chat.myInvite()
            demo = await store.chat.demoInvite()
        }
    }

    private var mine: some View {
        VStack(spacing: 16) {
            if let invite, let img = QRImage.make(invite.string) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(width: 230, height: 230)
                    .padding(16).background(Color.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: Color.lkAccent.opacity(0.25), radius: 20)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                Text("@" + invite.username).font(.lk(18, .heavy))
                Text("Покажите этот код человеку, с которым хотите общаться. Он отсканирует его в своём loKEY.")
                    .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center)
                ShareLink(item: invite.string) { Label("Отправить приглашение", systemImage: "square.and.arrow.up") }.buttonStyle(.lkSecondary)
                Text("Код содержит только ваш публичный ключ. Он безопасен, но отправляйте его только тем, кому доверяете.")
                    .font(.lk(11, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center)
            } else {
                ProgressView().tint(Color.lkAccent).frame(height: 230)
            }
        }
    }

    private var scan: some View {
        VStack(spacing: 12) {
            QRScanner { code in Task { await add(code) } }
                .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.lkAccent.opacity(0.5), lineWidth: 2))
                .overlay { ScanFrame() }
            Text("Наведите камеру на QR-код собеседника").font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
        }
    }

    private var pasteBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ИЛИ ВСТАВЬТЕ ПРИГЛАШЕНИЕ").font(.lk(11, .heavy)).tracking(1).foregroundStyle(Color.lkMuted)
            HStack(spacing: 10) {
                TextField("lokey://add?…", text: $pasted).font(.lkMono(13, .medium)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, 14).frame(height: 48).background(Color.lkCard, in: Capsule()).overlay(Capsule().stroke(Color.lkBorder, lineWidth: 1))
                Button {
                    if let s = UIPasteboard.general.string { pasted = s }
                } label: { Image(systemName: "doc.on.clipboard").frame(width: 48, height: 48).background(Color.lkCard, in: Circle()).overlay(Circle().stroke(Color.lkBorder, lineWidth: 1)) }
                .buttonStyle(LKPressStyle(scale: 0.9)).accessibilityLabel("Вставить")
            }
            Button { Task { await add(pasted) } } label: { if busy { ProgressView().tint(Color.lkBg) } else { Text("Добавить") } }
                .buttonStyle(.lkPrimary).disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        }
    }

    private func demoBlock(_ s: String) -> some View {
        Button { Task { await add(s) } } label: {
            HStack(spacing: 12) {
                ChatAvatar(name: "А", size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Демо-собеседница Алиса").font(.lk(14, .bold))
                    Text("Только для разработки: отвечает с настоящим шифрованием").font(.lk(11, .medium)).foregroundStyle(Color.lkMuted)
                }
                Spacer()
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.lkAccent)
            }
            .padding(12).background(Color.lkAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.lkAccent.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .buttonStyle(LKPressStyle(scale: 0.97))
        .accessibilityIdentifier("demoContactButton")
    }

    private func add(_ code: String) async {
        guard !busy else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let c = try await store.chat.addContact(invite: code)
            Haptics.success()
            router.replaceTop(with: .chat(contactID: c.id))
        } catch {
            Haptics.error()
            withAnimation { self.error = (error as? ChatError)?.errorDescription ?? "Не удалось добавить контакт" }
        }
    }
}

enum QRImage {
    static func make(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8); f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private struct ScanFrame: View {
    @State private var sweep = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.lkAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [40, 220]))
                .padding(36)
            Rectangle().fill(Color.lkAccent).frame(width: 190, height: 2).shadow(color: .lkAccent, radius: 6)
                .offset(y: sweep ? 90 : -90)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { sweep = true } }
        .allowsHitTesting(false)
    }
}

/// Камера-сканер QR. В симуляторе камеры нет — показывается подсказка.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { let c = ScannerController(); c.onCode = onCode; return c }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var last = Date.distantPast
        private let label = UILabel()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = UIColor(white: 0.08, alpha: 1)
            label.textColor = .lightGray; label.numberOfLines = 0; label.textAlignment = .center
            label.font = .systemFont(ofSize: 14, weight: .medium); label.frame = view.bounds.insetBy(dx: 24, dy: 24)
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.setup() : self.show("Нет доступа к камере. Разрешите её в Настройках iPhone или вставьте приглашение ниже.") }
            }
        }
        private func show(_ t: String) { label.text = t; view.addSubview(label) }
        private func setup() {
            guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
                show("Камера недоступна на этом устройстве. Вставьте приглашение ниже."); return
            }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            guard session.canAddOutput(out) else { return }
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill; layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            DispatchQueue.global().async { self.session.startRunning() }
        }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); view.layer.sublayers?.first?.frame = view.bounds }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); if session.isRunning { session.stopRunning() } }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, Date().timeIntervalSince(last) > 2 else { return }
            last = Date(); onCode?(s)
        }
    }
}
