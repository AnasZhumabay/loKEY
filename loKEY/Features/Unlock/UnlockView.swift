import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Разблокировка кейса: Face ID, ключ (текст / файл), неверный ключ, блокировка, восстановление.
struct UnlockView: View {
    let caseID: String

    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Phase: Equatable {
        case idle, scanning, success
        case wrongKey(left: Int)
        case lockedOut(until: Date)
    }

    @State private var phase: Phase = .idle
    @State private var key = ""
    @State private var fieldError: String?
    @State private var busy = false
    @State private var shakes: CGFloat = 0
    @State private var showImporter = false
    @State private var showRecovery = false
    @State private var wipe: WipePolicy = .off
    @State private var wiped = false
    @FocusState private var keyFocused: Bool

    private var vaultCase: VaultCase? { store.vaultCase(caseID) }
    private var caseName: String { vaultCase?.name ?? "Кейс" }
    private var level: SecurityLevel { vaultCase?.level ?? .standard }
    private var isWrongOrLocked: Bool {
        switch phase { case .wrongKey, .lockedOut: return true; default: return false }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                LKIconButton(systemName: "chevron.left", label: "Назад") { router.pop() }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 8)

            ScrollView {
                VStack(spacing: 20) {
                    if wiped {
                        wipedContent
                    } else {
                        switch phase {
                        case .lockedOut(let until): lockout(until: until)
                        case .wrongKey(let left): wrongKey(left: left)
                        default: idleContent
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 32).padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .lkScreen(glow: glowColor, strength: phase == .success ? 0.28 : 0.2)
        .task { await loadStatus() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            handleKeyFile(result)
        }
        .sheet(isPresented: $showRecovery) {
            RecoverySheet(caseName: caseName) { words in
                try await store.repo.recoverCase(id: caseID, words: words)
                await store.refreshCases()
                await finishSuccess()
            }
        }
    }

    private var glowColor: Color {
        switch phase {
        case .wrongKey, .lockedOut: return .lkDanger
        case .success, .scanning: return .lkAccent
        default: return .lkPurple
        }
    }

    // MARK: Idle / scanning / success

    private var idleContent: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                caseHeader
                ScanTile(phase: phase, icon: vaultCase?.icon ?? .key, reduceMotion: reduceMotion)
                    .padding(.top, 6)
                Text(statusText)
                    .font(.lk(15, .medium)).foregroundStyle(Color.lkText2)
                    .multilineTextAlignment(.center).frame(maxWidth: 300)
                    .accessibilityLabel(tr(statusText))
            }
            if store.faceIDEnabled {
                Button { startBiometrics() } label: {
                    Label(tr(phase == .scanning ? "Сканируем…" : "Открыть по Face ID"), systemImage: "faceid")
                }
                .buttonStyle(.lkPrimary)
                .disabled(phase != .idle || busy)
                HStack(spacing: 12) {
                    Rectangle().fill(Color.lkBorder).frame(height: 1)
                    Text("ИЛИ КЛЮЧОМ").font(.lk(11, .heavy)).tracking(1.2).foregroundStyle(Color.lkMuted)
                    Rectangle().fill(Color.lkBorder).frame(height: 1)
                }
            }
            keySection
            Text("Ключ хранится в Keychain этого iPhone. Сервер не может открыть кейс за вас.")
                .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center)
            if wipe.enabled { wipeWarning }
            recoveryButton
        }
    }

    /// Честное предупреждение: включено экстренное стирание ключа на этом устройстве.
    private var wipeWarning: some View {
        Label(trf("Включено экстренное стирание: после %lld неверных попыток ключ этого кейса удалится с iPhone.", wipe.clamped.maxAttempts),
              systemImage: "exclamationmark.triangle.fill")
            .font(.lk(13, .semibold)).foregroundStyle(Color.lkWarn)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.lkWarn.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
    }

    /// Показывается после стирания: объясняем, что осталось и как вернуть доступ.
    private var wipedContent: some View {
        VStack(spacing: 18) {
            caseHeader
            ZStack {
                Circle().fill(Color.lkDanger.opacity(0.12)).frame(width: 84, height: 84)
                Image(systemName: "key.slash").font(.system(size: 32, weight: .bold)).foregroundStyle(Color.lkDanger)
            }
            Text("Ключ стёрт с этого iPhone").font(.lk(24, .heavy)).multilineTextAlignment(.center)
            Text("Из-за неверных попыток ключ этого кейса удалён с устройства. Зашифрованная копия на сервере осталась, а открыть кейс можно ключом-файлом или по 12 словам.")
                .font(.lk(15, .medium)).foregroundStyle(Color.lkText2).multilineTextAlignment(.center)
            Button("Восстановить по 12 словам") { showRecovery = true }
                .buttonStyle(.lkPrimary)
            Button("К списку кейсов") { router.popToRoot() }
                .buttonStyle(.lkSecondary)
        }
        .accessibilityElement(children: .contain)
    }

    private var statusText: String {
        switch phase {
        case .success: return "Кейс разблокирован. Ключ расшифрован в памяти телефона."
        case .scanning: return "Смотрите на экран…"
        default: return "Кейс закрыт. Названия и содержимое файлов зашифрованы."
        }
    }

    private var caseHeader: some View {
        VStack(spacing: 6) {
            LevelTag(level: level)
            Text(caseName).font(.lk(28, .heavy)).lineLimit(2).minimumScaleFactor(0.7)
        }
    }

    // MARK: Key input

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LKField(title: "Ключ кейса", error: fieldError) {
                SecureField("XXXX-XXXX-XXXX-XXXX-…", text: $key)
                    .font(.lkMono(16, .semibold))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .focused($keyFocused)
                    .submitLabel(.go)
                    .onSubmit { submitKey() }
                    .onChange(of: key) { _, new in
                        let f = Self.formatKey(new)
                        if f != new { key = f }
                        if fieldError != nil { fieldError = nil }
                        store.noteActivity()
                    }
            }
            .modifier(ShakeEffect(animatableData: shakes))
            HStack(spacing: 10) {
                smallButton("Вставить", "doc.on.clipboard") {
                    if let s = UIPasteboard.general.string { key = Self.formatKey(s) }
                }
                smallButton("Файл .key", "doc.badge.key") { showImporter = true }
            }
            Button { submitKey() } label: {
                if busy && phase == .idle { ProgressView().tint(Color.lkBg) } else { Text("Открыть кейс") }
            }
            .buttonStyle(.lkPrimary)
            .disabled(key.filter { $0 != "-" }.isEmpty || busy)
        }
    }

    private func smallButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(tr(title), systemImage: icon)
                .font(.lk(14, .bold)).foregroundStyle(Color.lkText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.lkCard, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    @ViewBuilder private var recoveryButton: some View {
        if vaultCase?.isRecoverable ?? true {
            Button("Восстановить по 12 словам") { showRecovery = true }
                .font(.lk(15, .bold)).foregroundStyle(Color.lkAccent)
                .frame(minHeight: 44)
        }
    }

    static func formatKey(_ raw: String) -> String {
        let chars = raw.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(32)
        var out = ""
        for (i, c) in chars.enumerated() {
            if i > 0 && i % 4 == 0 { out.append("-") }
            out.append(c)
        }
        return out
    }

    // MARK: Wrong key

    private func wrongKey(left: Int) -> some View {
        VStack(spacing: 18) {
            caseHeader
            ZStack {
                Circle().fill(Color.lkDanger.opacity(0.12)).frame(width: 84, height: 84)
                Image(systemName: "xmark").font(.system(size: 32, weight: .bold)).foregroundStyle(Color.lkDanger)
            }
            .modifier(ShakeEffect(animatableData: shakes))
            Text("Ключ не подошёл").font(.lk(24, .heavy))
            Text(verbatim: trf("Проверьте, что это ключ именно от кейса «%@». Ключи разных кейсов не взаимозаменяемы.", caseName))
                .font(.lk(15, .medium)).foregroundStyle(Color.lkText2).multilineTextAlignment(.center)
            keySection
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(0..<(wipe.enabled ? wipe.clamped.maxAttempts : 5), id: \.self) { i in
                        Capsule().fill(i < left ? Color.lkDanger : Color.lkTrack).frame(height: 6)
                    }
                }
                Text(verbatim: trf("Осталось попыток: %lld", left)).font(.lk(15, .heavy)).foregroundStyle(Color.lkDanger)
                Text(wipe.enabled ? LocalizedStringKey("Потом ключ этого кейса удалится с iPhone") : LocalizedStringKey("Потом кейс закроется на 5 минут"))
                    .font(.lk(13, .medium)).foregroundStyle(wipe.enabled ? Color.lkWarn : Color.lkMuted)
            }
            .padding(16).frame(maxWidth: .infinity)
            .lkCard(radius: 18)
            .accessibilityElement(children: .combine)
            Button("Попробовать снова") {
                key = ""; fieldError = nil; phase = .idle; keyFocused = true
            }
            .buttonStyle(.lkSecondary)
            recoveryButton
        }
    }

    // MARK: Lockout

    private func lockout(until: Date) -> some View {
        VStack(spacing: 20) {
            caseHeader
            LockoutRing(until: until, reduceMotion: reduceMotion) {
                Task { await loadStatus(force: true) }
            }
            .padding(.top, 8)
            Text(verbatim: trf("Кейс «%@» заблокирован", caseName)).font(.lk(22, .heavy)).multilineTextAlignment(.center)
            Text("5 неверных попыток подряд. Мы защищаем ключ от перебора, поэтому следующая попытка будет через несколько минут.")
                .font(.lk(15, .medium)).foregroundStyle(Color.lkText2).multilineTextAlignment(.center)
            Label("Попытка записана в журнал", systemImage: "list.bullet.clipboard")
                .font(.lk(14, .semibold)).foregroundStyle(Color.lkText2)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .lkCard(radius: 16)
            recoveryButton
            Button("К списку кейсов") { router.popToRoot() }
                .buttonStyle(.lkSecondary)
        }
    }

    // MARK: Actions

    private func loadStatus(force: Bool = false) async {
        if vaultCase?.isUnlocked == true && !force && phase == .idle {
            router.replaceTop(with: .vaultCase(caseID: caseID)); return
        }
        wipe = await store.repo.wipePolicy
        let st = await store.repo.unlockStatus(caseID: caseID)
        if let until = st.lockedUntil, until > Date() {
            phase = .lockedOut(until: until)
        } else if case .lockedOut = phase {
            phase = .idle
        }
    }

    private func startBiometrics() {
        guard phase == .idle, !busy else { return }
        busy = true; fieldError = nil; keyFocused = false
        phase = .scanning
        Task {
            let started = Date()
            do {
                try await store.unlock(caseID: caseID, method: .biometrics)
                let el = Date().timeIntervalSince(started)
                if el < 1.4 { try? await Task.sleep(for: .seconds(1.4 - el)) }
                await finishSuccess()
            } catch {
                busy = false
                handle(error, fromBiometrics: true)
            }
        }
    }

    private func submitKey() {
        guard !busy else { return }
        let value = key
        let digits = value.filter { $0 != "-" }
        guard !digits.isEmpty else { return }
        // Ровно 6 цифр: это не ключ кейса (ключ — 32 символа), проверяем PIN «под принуждением». Если не он, обрабатываем как обычный ключ.
        if SecurityRules.isDuressPINFormatValid(digits) {
            busy = true; fieldError = nil
            Task {
                if await store.enterDuress(pin: digits) { await finishDuress(); return }
                busy = false
                run(.keyString(value))
            }
            return
        }
        run(.keyString(value))
    }

    private func finishDuress() async {
        busy = true
        phase = .success
        Haptics.soft()
        try? await Task.sleep(for: .seconds(reduceMotion ? 0.3 : 0.8))
        if let first = store.cases.first(where: \.isUnlocked) { router.replaceTop(with: .vaultCase(caseID: first.id)) }
        else { router.popToRoot() }
    }

    private func handleKeyFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e): store.showError(e)
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                run(.keyFile(data))
            } catch {
                fieldError = "Не удалось прочитать файл ключа"
            }
        }
    }

    private func run(_ method: UnlockMethod) {
        busy = true; fieldError = nil
        Task {
            do {
                try await store.unlock(caseID: caseID, method: method)
                await finishSuccess()
            } catch {
                busy = false
                handle(error, fromBiometrics: false)
            }
        }
    }

    private func finishSuccess() async {
        busy = true
        phase = .success
        Haptics.soft()
        try? await Task.sleep(for: .seconds(reduceMotion ? 0.3 : 0.8))
        router.replaceTop(with: .vaultCase(caseID: caseID))
    }

    private func handle(_ error: Error, fromBiometrics: Bool) {
        if phase == .scanning { phase = .idle }
        switch error as? VaultError {
        case .wrongKey(let left):
            Haptics.error(); shake()
            phase = .wrongKey(left: left)
            fieldError = "Ключ не подошёл"
        case .lockedOut(let until):
            Haptics.error()
            phase = .lockedOut(until: until)
        case .localKeyWiped:
            Haptics.error()
            wiped = true
            phase = .idle
        case .invalidKeyFormat:
            Haptics.warning(); shake()
            fieldError = VaultError.invalidKeyFormat.message
        default:
            store.showError(error)
        }
    }

    private func shake() {
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 0.4)) { shakes += 1 }
    }
}

// MARK: - Shake

private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(animatableData * .pi * 4), y: 0))
    }
}

// MARK: - Face ID tile

private struct ScanTile: View {
    let phase: UnlockView.Phase
    let icon: CaseIcon
    let reduceMotion: Bool
    @State private var sweep = false
    @State private var pulse = false
    @State private var opened = false

    private var scanning: Bool { phase == .scanning }
    private var ok: Bool { phase == .success }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.lkCard)
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(ok ? Color.lkAccent : (scanning ? Color.lkAccent.opacity(0.5) : Color.white.opacity(0.08)), lineWidth: ok ? 2 : 1))
            if ok {
                Circle().stroke(Color.lkAccent, lineWidth: 2).frame(width: 90, height: 90)
                    .scaleEffect(pulse ? 1.3 : 0.9).opacity(pulse ? 0 : 0.6)
                Image(systemName: opened ? "lock.open.fill" : "lock.fill").font(.system(size: 50)).foregroundStyle(Color.lkAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: opened)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Image(systemName: scanning ? "faceid" : icon.systemName)
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(scanning ? Color.lkAccent : Color.lkText2)
                if scanning {
                    Brackets().stroke(Color.lkAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 92, height: 92)
                    Rectangle().fill(Color.lkAccent).frame(width: 80, height: 2)
                        .shadow(color: .lkAccent, radius: 6)
                        .offset(y: sweep ? 38 : -38)
                }
            }
        }
        .frame(width: 128, height: 128)
        .animation(reduceMotion ? nil : .spring(duration: 0.4), value: ok)
        .onChange(of: scanning) { _, on in
            guard !reduceMotion else { return }
            if on {
                sweep = false
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { sweep = true }
            } else {
                withAnimation(.none) { sweep = false }
            }
        }
        .onChange(of: ok) { _, on in
            guard on, !reduceMotion else { return }
            pulse = false; opened = false
            withAnimation(.easeOut(duration: 0.8)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation { opened = true } }
        }
        .accessibilityHidden(true)
    }
}

private struct Brackets: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l: CGFloat = 20
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                               (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x, y: y + dy * l))
            p.addLine(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x + dx * l, y: y))
        }
        return p
    }
}

// MARK: - Lockout ring

private struct LockoutRing: View {
    let until: Date
    let reduceMotion: Bool
    let onFinish: () -> Void
    private let total: Double = 300

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int(until.timeIntervalSince(ctx.date).rounded(.up)))
            let frac = min(1, Double(left) / total)
            ZStack {
                Circle().stroke(Color.lkTrack, lineWidth: 8)
                Circle().trim(from: 0, to: frac)
                    .stroke(Color.lkDanger, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 1), value: left)
                VStack(spacing: 4) {
                    Text(LKFormat.clock(left)).font(.lkMono(40, .bold))
                    Text("ДО СЛЕДУЮЩЕЙ ПОПЫТКИ").font(.lk(10, .heavy)).tracking(1).foregroundStyle(Color.lkMuted)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: 220, height: 220)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(trf("До следующей попытки %@", LKFormat.clock(left)))
            .onChange(of: left) { _, v in if v == 0 { onFinish() } }
        }
        .frame(width: 220, height: 220)
    }
}

// MARK: - Recovery sheet

private struct RecoverySheet: View {
    let caseName: String
    let onRecover: ([String]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false

    private var words: [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule().fill(Color.lkTrack).frame(width: 40, height: 5).frame(maxWidth: .infinity)
            Text("Восстановление по 12 словам").font(.lk(22, .heavy))
            Text(verbatim: trf("Введите фразу восстановления кейса «%@» через пробел в том порядке, в каком вы её записали.", caseName))
                .font(.lk(14, .medium)).foregroundStyle(Color.lkText2)
            LKField(title: trf("Слова (%lld из 12)", words.count), error: error) {
                TextField("слово1 слово2 слово3 …", text: $text, axis: .vertical)
                    .lineLimit(4...8)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.vertical, 12)
                    .onChange(of: text) { _, _ in error = nil }
            }
            Button {
                run()
            } label: {
                if busy { ProgressView().tint(Color.lkBg) } else { Text("Восстановить доступ") }
            }
            .buttonStyle(.lkPrimary)
            .disabled(words.count != 12 || busy)
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Color.lkBg)
        .foregroundStyle(Color.lkText)
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    private func run() {
        busy = true
        Task {
            do {
                try await onRecover(words)
                dismiss()
            } catch {
                busy = false
                Haptics.error()
                self.error = (error as? VaultError)?.message ?? "Не удалось восстановить доступ"
            }
        }
    }
}
