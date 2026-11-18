import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showAccount = false
    @State private var mfaSetup: MFASetup?
    @State private var mfaBusy = false
    @State private var confirmDisableMFA = false
    @State private var confirmSignOut = false
    @State private var ringIn = false
    @State private var sub: SubScreen?
    private enum SubScreen: String, Identifiable {
        case reminders, backup, shared, panic
        var id: String { rawValue }
    }
    @Namespace private var lockNS

    private let locks: [(Int, String)] = [(0, "Сразу"), (1, "1 мин"), (5, "5 мин"), (15, "15 мин")]
    private let palette: [Color] = [.lkAccent, .lkPurple, .lkWarn, .lkMuted, .lkAccentDim, .lkText2]

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Настройки").font(.lk(30, .heavy)).tracking(-0.9)
                    .frame(height: 44, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                profileCard.lkAppear(0)
                scoreCard.lkAppear(1)

                group("БЕЗОПАСНОСТЬ", index: 2) {
                    autoLockBlock
                    div
                    toggleRow("faceid", .lkAccent, "Face ID для кейсов", "Если снять код-пароль устройства, iOS удалит ключи кейсов с телефона: нужны ключ-файл или 12 слов", $store.faceIDEnabled)
                    div
                    toggleRow("lock.shield", .lkPurple, "Двухфакторный вход", mfaOn ? "Authenticator · включено" : "Authenticator или SMS",
                              Binding(get: { mfaOn }, set: { new in
                                  if new { Task { await setMFA(true) } } else { confirmDisableMFA = true }
                              }), disabled: mfaBusy)
                    div
                    navRowIcon("envelope", backup.isEmpty ? .lkWarn : .lkText2, "Запасной email",
                               trailing: backup.isEmpty ? "Не добавлен" : backup, trailingColor: backup.isEmpty ? .lkWarn : .lkMuted) { showAccount = true }
                    div
                    toggleRow("key.fill", .lkPurple, "Ключи и 12 слов сохранены", "Без них доступ не вернуть", $store.keysSaved)
                    div
                    toggleRow("iphone.radiowaves.left.and.right", .lkWarn, "Закрывать встряхиванием", "Потрясите телефон — все кейсы закроются", $store.shakeToLock)
                }

                group("ПРИВАТНОСТЬ", index: 3) {
                    toggleRow("eye.slash", .lkText2, "Скрывать названия в виджетах", "Названия кейсов не видны на экране", $store.hideNamesInWidgets)
                }

                group("ДОКУМЕНТЫ И КОПИИ", index: 4) {
                    navRowIcon("calendar.badge.clock", .lkWarn, "Сроки документов") { sub = .reminders }
                    div
                    navRowIcon("icloud.and.arrow.up", .lkAccent, "Резервная копия") { sub = .backup }
                    div
                    navRowIcon("person.2.fill", .lkPurple, "Общие кейсы") { sub = .shared }
                }

                group("ПОД ПРИНУЖДЕНИЕМ", index: 4) {
                    navRowIcon("exclamationmark.shield.fill", .lkDanger, "Режим «под принуждением» и аварийное стирание") { sub = .panic }
                }

                sectionTitle("ХРАНИЛИЩЕ").lkAppear(4)
                VStack(spacing: 0) {
                    StorageUsageCard()
                    div.padding(.horizontal, 16)
                    navRowIcon("externaldrive", .lkAccent, "Хранилище и тариф") { router.push(.plans) }.padding(.horizontal, 16)
                }
                .lkCard(radius: 22).lkAppear(4)

                group("ДАННЫЕ И УСТРОЙСТВА", index: 5) {
                    navRowIcon("trash", .lkWarn, "Корзина") { router.push(.trash) }
                    div
                    navRowIcon("bubble.left.and.bubble.right.fill", .lkAccent, "Защищённый чат",
                               trailing: store.chatUnread > 0 ? "\(store.chatUnread)" : nil, trailingColor: .lkAccent) { router.push(.chats) }
                    div
                    navRowIcon("laptopcomputer.and.iphone", .lkAccent, "Устройства и сеансы") { router.push(.sessions) }
                    div
                    navRowIcon("waveform.path.ecg", .lkText2, "Журнал событий") { router.tab = .journal }
                }

                group("ВНЕШНИЙ ВИД", index: 6) { languageRow }

                Button { confirmSignOut = true } label: {
                    Label("Выйти из аккаунта", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.lk(15, .bold)).foregroundStyle(Color.lkDanger)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.lkDanger.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.lkDanger.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(LKPressStyle(scale: 0.97)).lkAppear(7)

                VStack(spacing: 4) {
                    BrandMark().frame(width: 44).opacity(0.5)
                    Text("loKEY \(Self.appVersion)")
                        .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted)
                }
                .frame(maxWidth: .infinity).padding(.top, 4)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .lkScreen()
        .onAppear { withAnimation(.easeOut(duration: 1.1).delay(0.25)) { ringIn = true } }
        .sheet(isPresented: $showAccount) {
            AccountSheet().presentationDetents([.large]).presentationBackground(Color.lkCard)
        }
        .sheet(item: $sub) { which in
            Group {
                switch which {
                case .reminders: RemindersView()
                case .backup: BackupSettingsView()
                case .shared: SharedCasesView()
                case .panic: PanicSettingsView()
                }
            }
            .environment(store).environment(router)
            .presentationDetents([.large]).presentationBackground(Color.lkBg)
        }
        .sheet(item: $mfaSetup) { setup in
            MFASetupSheet(setup: setup).presentationDetents([.large]).presentationBackground(Color.lkCard)
        }
        .confirmationDialog("Выключить двухфакторный вход?", isPresented: $confirmDisableMFA, titleVisibility: .visible) {
            Button("Выключить", role: .destructive) { Task { await setMFA(false) } }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { Task { await store.signOut() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все кейсы будут закрыты. Ключи останутся у вас.")
        }
    }

    private var mfaOn: Bool { store.account?.mfaEnabled ?? false }
    private var backup: String { store.account?.backupEmail ?? "" }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    // MARK: Каркас

    private var div: some View { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 46) }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.lk(12, .heavy)).tracking(1.2).foregroundStyle(Color.lkMuted)
            .padding(.horizontal, 4).padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func group<C: View>(_ title: String, index: Int, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 16).padding(.vertical, 2)
                .lkCard(radius: 22)
        }
        .lkAppear(index)
    }

    private func iconTile(_ icon: String, _ tint: Color) -> some View {
        Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(LinearGradient(colors: [tint.opacity(0.26), tint.opacity(0.10)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func toggleRow(_ icon: String, _ tint: Color, _ title: String, _ hint: String?, _ isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        HStack(spacing: 14) {
            iconTile(icon, tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.lk(15, .bold)).lineLimit(2).minimumScaleFactor(0.85)
                if let hint { Text(hint).font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).lineLimit(2) }
            }
            Spacer(minLength: 8)
            if disabled { ProgressView() }
            Toggle(title, isOn: isOn).labelsHidden().tint(Color.lkAccent).disabled(disabled)
                .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
        }
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
    }

    private func navRowIcon(_ icon: String, _ tint: Color, _ title: String, trailing: String? = nil, trailingColor: Color = .lkMuted,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                iconTile(icon, tint)
                Text(title).font(.lk(15, .bold)).foregroundStyle(Color.lkText)
                Spacer(minLength: 8)
                if let trailing { Text(trailing).font(.lk(13, .semibold)).foregroundStyle(trailingColor).lineLimit(1) }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.lkMuted)
            }
            .frame(minHeight: 56).contentShape(Rectangle())
        }
        .buttonStyle(LKPressStyle(scale: 0.98))
    }

    // MARK: Профиль

    private var profileCard: some View {
        let name = store.account?.username ?? "username"
        return Button { showAccount = true } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(AngularGradient(colors: [.lkAccent, .lkPurple, .lkAccent], center: .center), lineWidth: 2.5)
                        .frame(width: 62, height: 62)
                    Text(String(name.prefix(1)).uppercased()).font(.lk(24, .heavy)).foregroundStyle(Color.lkBg)
                        .frame(width: 52, height: 52)
                        .background(LinearGradient(colors: [.lkAccent, .lkAccentDim], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(name)").font(.lk(18, .heavy)).tracking(-0.3).lineLimit(1)
                    Text(store.account?.email ?? "—").font(.lk(13, .medium)).foregroundStyle(Color.lkMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.lkMuted)
            }
            .padding(16)
            .background(LinearGradient(colors: [Color.lkAccent.opacity(0.12), Color.lkCard], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.lkAccent.opacity(0.2), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(LKPressStyle(scale: 0.98))
        .accessibilityLabel(trf("Аккаунт, %@, %@", name, store.account?.email ?? ""))
    }

    // MARK: Степень защиты

    private var scoreCard: some View {
        let items = store.securityItems
        let done = items.filter(\.done).count
        let score = store.securityScore
        let color: Color = score >= 0.8 ? .lkAccent : (score >= 0.5 ? .lkWarn : .lkDanger)
        let verdict = tr(score >= 1 ? "Защита на максимуме" : (score >= 0.8 ? "Защита хорошая" : (score >= 0.5 ? "Можно лучше" : "Защита слабая")))
        let todo = items.filter { !$0.done }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 7)
                    Circle().trim(from: 0, to: ringIn ? score : 0)
                        .stroke(AngularGradient(colors: [color.opacity(0.5), color], center: .center), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: color.opacity(0.5), radius: 6)
                    Text("\(Int((score * 100).rounded()))").font(.lk(22, .heavy)).tracking(-0.5)
                        .contentTransition(.numericText())
                }
                .frame(width: 74, height: 74)
                .animation(LKMotion.spring, value: score)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verdict).font(.lk(18, .heavy)).tracking(-0.3).foregroundStyle(color)
                    Text(verbatim: String(format: tr("Выполнено %lld из %lld"), done, items.count)).font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            if todo.isEmpty {
                Label("Всё настроено. Так держать!", systemImage: "checkmark.seal.fill")
                    .font(.lk(13, .bold)).foregroundStyle(Color.lkAccent)
                    .symbolEffect(.bounce, value: score)
            } else {
                VStack(spacing: 8) {
                    ForEach(todo.prefix(3)) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.lkWarn)
                                .frame(width: 30, height: 30).background(Color.lkWarn.opacity(0.14), in: Circle())
                            Text(item.title).font(.lk(13, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 6)
                            Button { fix(item) } label: {
                                Text("Включить").font(.lk(12, .heavy)).foregroundStyle(Color.lkBg)
                                    .padding(.horizontal, 12).frame(height: 30).background(Color.lkAccent, in: Capsule())
                            }
                            .buttonStyle(LKPressStyle(scale: 0.9))
                        }
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                    }
                }
                .animation(LKMotion.spring, value: todo.map(\.id))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lkCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(color.opacity(0.28), lineWidth: 1))
    }

    private func fix(_ item: SecurityItem) {
        Haptics.success()
        switch item.fix {
        case .mfa: Task { await setMFA(true) }
        case .backupEmail: showAccount = true
        default: withAnimation(LKMotion.spring) { store.applyFix(item.fix) }
        }
    }

    // MARK: Автоблокировка

    private var autoLockBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                iconTile("timer", .lkAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Автоблокировка").font(.lk(15, .bold))
                    Text(tr(store.autoLockMinutes == 0 ? "Кейс закрывается при выходе из приложения" : "Закрытие кейса после бездействия"))
                        .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                ForEach(locks, id: \.0) { v, label in
                    let on = store.autoLockMinutes == v
                    Button {
                        withAnimation(LKMotion.snappy) { store.autoLockMinutes = v }
                        Haptics.soft()
                    } label: {
                        Text(tr(label)).font(.lk(13, .bold))
                            .foregroundStyle(on ? Color.lkBg : Color.lkText2)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background {
                                if on {
                                    Capsule().fill(Color.lkAccent).matchedGeometryEffect(id: "lockPill", in: lockNS)
                                        .shadow(color: Color.lkAccent.opacity(0.4), radius: 6)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(4).background(Color.lkBg, in: Capsule())
            .accessibilityElement(children: .contain).accessibilityLabel("Время автоблокировки")
        }
        .padding(.vertical, 12)
    }

    // MARK: Язык

    private var languageRow: some View {
        @Bindable var s = store
        return Menu {
            Picker("Язык", selection: $s.language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            HStack(spacing: 14) {
                iconTile("globe", .lkAccent)
                Text("Язык").font(.lk(15, .bold)).foregroundStyle(Color.lkText)
                Spacer()
                Text(store.language.title).font(.lk(13, .semibold)).foregroundStyle(Color.lkMuted)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.lkMuted)
            }
            .frame(minHeight: 56).contentShape(Rectangle())
        }
    }

    private func setMFA(_ on: Bool) async {
        guard !mfaBusy else { return }
        mfaBusy = true
        defer { mfaBusy = false }
        do {
            let setup = try await store.repo.setMFA(enabled: on, method: .authenticator)
            if let fresh = await store.repo.restoreSession() {
                store.updateAccount(fresh)
            } else if var acc = store.account {
                acc.mfaEnabled = on
                store.updateAccount(acc)
            }
            if on {
                if let setup, setup.otpauthUri != nil { mfaSetup = setup }
                else { store.showToast("Двухфакторный вход включён") }
            } else {
                store.showToast("Двухфакторный вход выключен")
            }
        } catch {
            store.showError(error)
        }
    }
}


// MARK: - Аккаунт: запасной email

private struct AccountSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule().fill(Color(hex: 0x3A414B)).frame(width: 40, height: 5).frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text("@\(store.account?.username ?? "")").font(.lk(24, .heavy))
                Text(store.account?.email ?? "").font(.lk(14, .medium)).foregroundStyle(Color.lkMuted)
            }
            LKField(title: "Запасной email", error: error) {
                TextField("name@example.com", text: $email)
                    .keyboardType(.emailAddress).textContentType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .tint(Color.lkAccent)
                    .onChange(of: email) { _, _ in error = nil }
            }
            Text("Нужен, чтобы вернуть доступ к аккаунту. Оставьте поле пустым, чтобы удалить запасной email.")
                .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
            Spacer(minLength: 0)
            Button { Task { await save() } } label: {
                if saving { ProgressView().tint(Color.lkBg) } else { Text("Сохранить") }
            }
            .buttonStyle(.lkPrimary).disabled(saving)
            Button("Отмена") { dismiss() }.buttonStyle(.lkSecondary)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)
        .foregroundStyle(Color.lkText).preferredColorScheme(.dark)
        .onAppear { email = store.account?.backupEmail ?? "" }
    }

    private func save() async {
        let v = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty {
            let ok = v.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil
            guard ok else { error = "Введите корректный email"; return }
        }
        saving = true
        defer { saving = false }
        do {
            let acc = try await store.repo.updateBackupEmail(v.isEmpty ? nil : v)
            store.updateAccount(acc)
            store.showToast(v.isEmpty ? "Запасной email удалён" : "Запасной email сохранён")
            dismiss()
        } catch {
            store.showError(error)
        }
    }
}

// MARK: - 2FA: QR-код

private struct MFASetupSheet: View {
    let setup: MFASetup
    @Environment(\.dismiss) private var dismiss

    private var secret: String? {
        guard let u = setup.otpauthUri, let c = URLComponents(string: u) else { return nil }
        return c.queryItems?.first { $0.name.lowercased() == "secret" }?.value
    }

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color(hex: 0x3A414B)).frame(width: 40, height: 5)
            Text("Двухфакторный вход").font(.lk(24, .heavy))
            Text("Отсканируйте код в Google Authenticator или другом приложении.")
                .font(.lk(14, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center)
            if let uri = setup.otpauthUri, let img = Self.qr(uri) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 220, height: 220).padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel("QR-код для приложения-аутентификатора")
            }
            if let secret {
                VStack(spacing: 6) {
                    Text("ИЛИ ВВЕДИТЕ КЛЮЧ ВРУЧНУЮ").font(.lk(11, .heavy)).tracking(1.1).foregroundStyle(Color.lkMuted)
                    Text(secret).font(.lkMono(15, .semibold)).textSelection(.enabled)
                        .multilineTextAlignment(.center)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.lkWarn)
                Text("Никому не показывайте этот код. Сохраните его в надёжном месте: без него войти будет сложнее.")
                    .font(.lk(13, .semibold)).foregroundStyle(Color(hex: 0xF6C795))
            }
            .padding(12).background(Color.lkWarn.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 0)
            Button("Готово") { dismiss() }.buttonStyle(.lkPrimary)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)
        .foregroundStyle(Color.lkText).preferredColorScheme(.dark)
    }

    static func qr(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
