import SwiftUI

/// Код безопасности: если цифры у двоих совпадают, между вами нет подмены ключа.
struct SafetyNumberView: View {
    let contactID: String
    @Environment(AppStore.self) private var store
    @State private var contact: ChatContact?
    @State private var shown = false
    @State private var showQR = false

    var body: some View {
        VStack(spacing: 0) {
            LKTopBar(title: "Код безопасности") { Color.clear }.padding(.horizontal, 20).padding(.top, 8)
            ScrollView {
                VStack(spacing: 18) {
                    if let c = contact {
                        ChatAvatar(name: c.name, size: 64)
                        Text(verbatim: trf("Чат с %@", c.name)).font(.lk(20, .heavy))
                        grid(c.safetyNumber)
                        Text("Сверьте эти цифры с собеседником лично или по звонку. Если они совпадают, то ваш разговор не перехвачен. Если нет, не доверяйте чату.")
                            .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center)
                        Button {
                            Task {
                                await store.chat.markVerified(contactID: c.id, !c.verified)
                                contact = await store.chat.contact(id: c.id)
                                Haptics.success()
                            }
                        } label: {
                            Label(tr(c.verified ? "Контакт проверен" : "Отметить как проверенный"), systemImage: c.verified ? "checkmark.seal.fill" : "checkmark.shield")
                        }
                        .buttonStyle(.lkPrimary(fill: c.verified ? .lkAccentDim : .lkAccent))
                        Button { showQR = true } label: {
                            Label("Сверить по QR", systemImage: "qrcode.viewfinder").font(.lk(15, .bold)).frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .foregroundStyle(Color.lkAccent).lkCard(radius: 16, stroke: Color.lkAccent.opacity(0.35))
                        .buttonStyle(LKPressStyle(scale: 0.97))
                        Text("Или сверьте цифры выше вручную.").font(.lk(12, .medium)).foregroundStyle(Color.lkMuted)
                    } else { ProgressView().tint(Color.lkAccent) }
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .lkScreen()
        .sheet(isPresented: $showQR) {
            SafetyQRSheet(contactID: contactID) { Task { contact = await store.chat.contact(id: contactID) } }
                .presentationDetents([.large]).presentationBackground(Color.lkCard)
        }
        .navigationBarBackButtonHidden(true).toolbar(.hidden, for: .navigationBar)
        .task { contact = await store.chat.contact(id: contactID); withAnimation(.easeOut(duration: 0.6)) { shown = true } }
    }

    private func grid(_ s: String) -> some View {
        let rows = s.split(separator: "\n").map(String.init)
        return VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { ri, row in
                HStack(spacing: 14) {
                    ForEach(Array(row.split(separator: " ").enumerated()), id: \.offset) { ci, g in
                        Text(g).font(.lkMono(20, .bold)).foregroundStyle(Color.lkAccent)
                            .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 8)
                            .animation(.easeOut(duration: 0.4).delay(Double(ri * 4 + ci) * 0.05), value: shown)
                    }
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity).lkCard(radius: 24, stroke: Color.lkAccent.opacity(0.3))
        .accessibilityElement(children: .ignore).accessibilityLabel("Код безопасности: " + s.replacingOccurrences(of: "\n", with: " "))
    }
}

// MARK: - Сверка по QR

/// Два режима: «Мой QR» (его сканирует собеседник) и «Сканировать» (QR собеседника).
/// В QR лежит не сам код, а его хэш: `lokey://verify?a=<мой id>&b=<id собеседника>&h=<хэш>`. Совпало = контакт проверен.
private struct SafetyQRSheet: View {
    let contactID: String
    let onChanged: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Mode: String, CaseIterable { case mine = "Мой QR", scan = "Сканировать" }
    @State private var mode: Mode = .mine
    @State private var qr: UIImage?
    @State private var outcome: ChatVerifyOutcome?
    @State private var handled = false
    @State private var pop = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Сверить по QR").font(.lk(20, .heavy)); Spacer()
                Button("Готово") { dismiss() }.font(.lk(16, .bold)).foregroundStyle(Color.lkAccent).frame(minHeight: 44)
            }
            Picker("Режим", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                .pickerStyle(.segmented)
            if outcome == .match { success }
            else {
                if outcome == .mismatch || outcome == .wrongContact || outcome == .invalid { warning }
                if mode == .mine { mine } else { scanner }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
        .task { if let s = await store.chat.verificationQR(contactID: contactID) { qr = QRImage.make(s) } }
        .animation(reduceMotion ? nil : LKMotion.spring, value: outcome)
    }

    private var mine: some View {
        VStack(spacing: 12) {
            if let img = qr {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260)
                    .padding(14).background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityLabel("QR-код для сверки безопасности")
            } else { ProgressView().tint(Color.lkAccent).frame(height: 260) }
            Text("Покажите этот код собеседнику: пусть откроет «Сверить по QR» → «Сканировать». Потом отсканируйте его код.")
                .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center)
        }
    }

    private var scanner: some View {
        VStack(spacing: 10) {
            QRScanner { code in Task { await check(code) } }
                .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.lkAccent.opacity(0.5), lineWidth: 1.5))
            Text("Наведите камеру на QR собеседника").font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
            Button {
                if let s = UIPasteboard.general.string { Task { await check(s) } }
            } label: { Label("Вставить из буфера", systemImage: "doc.on.clipboard").font(.lk(13, .bold)).frame(minHeight: 44) }
                .foregroundStyle(Color.lkAccent)
        }
    }

    private var success: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.lkAccent.opacity(0.15)).frame(width: 120, height: 120).scaleEffect(pop ? 1 : 0.4)
                Circle().stroke(Color.lkAccent, lineWidth: 3).frame(width: 120, height: 120).scaleEffect(pop ? 1.25 : 1).opacity(pop ? 0 : 0.8)
                Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(Color.lkAccent).scaleEffect(pop ? 1 : 0.2)
            }
            .onAppear { withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6)) { pop = true } }
            Text("Контакт проверен").font(.lk(20, .heavy))
            Text("Коды совпали: между вами нет подмены ключа.").font(.lk(13, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center)
        }
        .padding(.top, 30).accessibilityElement(children: .combine)
    }

    private var warning: some View {
        let text: LocalizedStringKey = outcome == .mismatch ? "Код не совпал — возможна подмена"
            : (outcome == .wrongContact ? "Это QR другого собеседника" : "Это не QR проверки loKEY")
        return VStack(alignment: .leading, spacing: 8) {
            Label { Text(text) } icon: { Image(systemName: "exclamationmark.octagon.fill") }.font(.lk(15, .heavy))
            if outcome == .mismatch {
                Text("Не доверяйте этому чату. Сверьте цифры кода вручную по звонку или при встрече.").font(.lk(12, .medium))
            }
            Button("Сканировать снова") { handled = false; outcome = nil; mode = .scan }
                .font(.lk(13, .bold)).foregroundStyle(Color.lkText).frame(minHeight: 44)
        }
        .foregroundStyle(Color.lkDanger).padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lkDangerSolid.opacity(0.2), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.lkDanger.opacity(0.6), lineWidth: 1))
        .transition(.scale(scale: 0.95).combined(with: .opacity)).accessibilityElement(children: .combine)
    }

    private func check(_ code: String) async {
        guard !handled else { return }
        handled = true
        let r = await store.chat.verify(scanned: code, contactID: contactID)
        outcome = r
        if r == .match { Haptics.success(); onChanged() } else { Haptics.error(); onChanged() }
        if r != .match { handled = false }
    }
}
