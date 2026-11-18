import SwiftUI

/// «Под принуждением»: PIN-приманка и экстренное стирание ключа кейса.
/// Точка входа для экрана настроек: `PanicSettingsView()` (push через NavigationLink или sheet — работает и так, и так).
struct PanicSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var duressOn = false
    @State private var pin = ""
    @State private var pin2 = ""
    @State private var pinError: String?
    @State private var editingPIN = false
    @State private var saving = false
    @State private var wipe: WipePolicy = .off
    @State private var askWipeConfirm = false
    @State private var askDuressOff = false
    @State private var loaded = false
    @FocusState private var focus: Field?
    private enum Field { case pin, pin2 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                LKIconButton(systemName: "chevron.left", label: "Назад") { dismiss() }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header.lkAppear(0)
                    duressCard.lkAppear(1)
                    wipeCard.lkAppear(2)
                    limitsCard.lkAppear(3)
                }
                .padding(.horizontal, 20).padding(.vertical, 12).padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .lkScreen(glow: .lkWarn, strength: 0.14)
        .task { await load() }
        .confirmationDialog("Включить экстренное стирание?", isPresented: $askWipeConfirm, titleVisibility: .visible) {
            Button("Включить", role: .destructive) { setWipe(enabled: true) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(verbatim: trf("После %lld неверных попыток подряд ключ кейса будет удалён с этого iPhone. Копия на сервере и восстановление по 12 словам останутся. Если у вас нет ключа-файла или 12 слов, открыть кейс будет нельзя.", wipe.clamped.maxAttempts))
        }
        .confirmationDialog("Выключить режим «под принуждением»?", isPresented: $askDuressOff, titleVisibility: .visible) {
            Button("Выключить", role: .destructive) { disableDuress() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("PIN будет удалён с этого iPhone.")
        }
    }

    // MARK: Заголовок

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Под принуждением").font(.lk(30, .heavy)).accessibilityAddTraits(.isHeader)
            Text("Два необязательных режима на случай, когда телефон пытаются открыть силой или подбирают ключ. Оба выключены, пока вы их не включите.")
                .font(.lk(15, .medium)).foregroundStyle(Color.lkText2)
        }
    }

    // MARK: PIN-приманка

    private var duressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                icon("person.fill.questionmark", tint: .lkPurple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PIN-приманка").font(.lk(18, .heavy))
                    Text(duressOn ? LocalizedStringKey("Включена") : LocalizedStringKey("Выключена"))
                        .font(.lk(13, .bold)).foregroundStyle(duressOn ? Color.lkAccent : Color.lkMuted)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)

            Text("Задайте отдельный 6-значный PIN. Если ввести его на экране открытия кейса вместо ключа, loKEY покажет отдельный набор безобидных кейсов вместо настоящих. Настоящие ключи и файлы при этом не расшифровываются, а всё, что вы там измените, не сохранится. Режим остаётся включённым и после перезапуска приложения.")
                .font(.lk(14, .medium)).foregroundStyle(Color.lkText2)

            if editingPIN || !duressOn {
                pinFields
            }

            HStack(spacing: 10) {
                if duressOn && !editingPIN {
                    Button("Сменить PIN") { withAnim { editingPIN = true }; focus = .pin }
                        .buttonStyle(.lkSecondary)
                    Button("Выключить") { askDuressOff = true }
                        .buttonStyle(.lkSecondary)
                } else {
                    Button { Task { await savePIN() } } label: {
                        if saving { ProgressView().tint(Color.lkBg) } else { Text(duressOn ? "Сохранить новый PIN" : "Включить") }
                    }
                    .buttonStyle(.lkPrimary)
                    .disabled(pin.count != SecurityRules.duressPINLength || pin2.count != SecurityRules.duressPINLength || saving)
                    if duressOn {
                        Button("Отмена") { withAnim { editingPIN = false }; pin = ""; pin2 = ""; pinError = nil }
                            .buttonStyle(.lkSecondary)
                    }
                }
            }
        }
        .padding(18).lkCard(radius: 22)
    }

    private var pinFields: some View {
        VStack(spacing: 12) {
            LKField(title: "PIN «под принуждением» (6 цифр)", error: pinError) {
                SecureField("••••••", text: $pin)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .focused($focus, equals: .pin)
                    .onChange(of: pin) { _, new in
                        let d = String(new.filter { $0.isASCII && $0.isNumber }.prefix(SecurityRules.duressPINLength))
                        if d != new { pin = d }
                        pinError = nil
                        if d.count == SecurityRules.duressPINLength { focus = .pin2 }
                    }
            }
            LKField(title: "Повторите PIN") {
                SecureField("••••••", text: $pin2)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .focused($focus, equals: .pin2)
                    .onChange(of: pin2) { _, new in
                        let d = String(new.filter { $0.isASCII && $0.isNumber }.prefix(SecurityRules.duressPINLength))
                        if d != new { pin2 = d }
                        pinError = nil
                    }
            }
            Text("PIN хранится в Keychain только как соль и хэш. Выберите такой, который вы не используете больше нигде.")
                .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Экстренное стирание

    private var wipeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                icon("key.slash", tint: .lkDanger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Экстренное стирание ключа").font(.lk(18, .heavy))
                    Text(verbatim: wipe.enabled ? trf("Включено: %lld попыток", wipe.clamped.maxAttempts) : tr("Выключено"))
                        .font(.lk(13, .bold)).foregroundStyle(wipe.enabled ? Color.lkWarn : Color.lkMuted)
                }
                Spacer()
                Toggle("Экстренное стирание ключа", isOn: Binding(
                    get: { wipe.enabled },
                    set: { on in on ? (askWipeConfirm = true) : setWipe(enabled: false) }))
                    .labelsHidden().tint(Color.lkWarn)
            }

            Text("После заданного числа неверных попыток подряд loKEY удаляет с этого iPhone ключ кейса и расшифрованные данные из памяти. Без этой настройки кейс просто закрывается на 5 минут.")
                .font(.lk(14, .medium)).foregroundStyle(Color.lkText2)

            if wipe.enabled {
                HStack {
                    Text("Неверных попыток до стирания").font(.lk(14, .semibold))
                    Spacer()
                    Stepper(value: Binding(get: { wipe.clamped.maxAttempts },
                                           set: { setAttempts($0) }), in: WipePolicy.allowedRange) {
                        Text("\(wipe.clamped.maxAttempts)").font(.lk(20, .heavy)).monospacedDigit()
                    }
                    .fixedSize()
                    .accessibilityLabel("Число неверных попыток до стирания")
                    .accessibilityValue("\(wipe.clamped.maxAttempts)")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Label("Копия на сервере и восстановление по 12 словам остаются. Стирается только то, что хранится на этом телефоне. Счётчик попыток не сбрасывается перезапуском приложения.",
                  systemImage: "info.circle")
                .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
        }
        .padding(18).lkCard(radius: 22)
    }

    // MARK: Честные ограничения

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Что эти режимы не умеют").font(.lk(16, .heavy))
            limit("Человека, которого заставляют, могут заставить открыть что угодно, в том числе настоящие кейсы. Приманка лишь даёт ещё один вариант.")
            limit("Приманка защищает от просмотра экрана, а не от криминалистического разбора устройства: специалист с доступом к телефону может увидеть, что в приложении есть режим «под принуждением».")
            limit("Приманка остаётся включённой после перезапуска. Выйти из неё можно только через «Выйти» и вход с настоящим паролем; настоящие данные при этом не стираются.")
            limit("PIN вводится на экране открытия кейса, где настоящий список кейсов уже виден. Кто смотрит на экран, может заметить, что список изменился.")
            limit("Если снять код-пароль устройства, iOS удалит защищённые секреты кейсов с этого телефона. Кейсы тогда открываются по ключу-файлу или 12 словам: сохраните их заранее.")
            limit("Если телефон открыт кодом-паролем устройства, защита loKEY одна из нескольких линий. Сильный код-пароль важнее любой настройки здесь.")
            limit("Стирание ключа не стирает копию на сервере и не мешает тому, у кого есть ключ-файл или 12 слов. Не включайте его, если эти способы восстановления у вас не сохранены.")
            limit("Ни один режим не даёт полной гарантии. Мы не обещаем «абсолютную защиту».")
        }
        .padding(18).lkCard(radius: 22)
        .accessibilityElement(children: .contain)
    }

    private func limit(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.lkWarn).padding(.top, 2).accessibilityHidden(true)
            Text(text).font(.lk(13, .medium)).foregroundStyle(Color.lkText2)
        }
    }

    private func icon(_ name: String, tint: Color) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 40, height: 40).background(tint.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }

    // MARK: Действия

    private func withAnim(_ body: () -> Void) {
        if reduceMotion { body() } else { withAnimation(LKMotion.snappy, body) }
    }

    private func load() async {
        duressOn = await store.repo.duressEnabled
        wipe = await store.repo.wipePolicy
        loaded = true
    }

    private func savePIN() async {
        guard pin == pin2 else { pinError = "PIN не совпадают"; Haptics.error(); return }
        saving = true
        defer { saving = false }
        do {
            try await store.repo.setDuressPIN(pin)
            Haptics.success()
            pin = ""; pin2 = ""; pinError = nil
            focus = nil
            withAnim { duressOn = true; editingPIN = false }
            store.showToast("Режим «под принуждением» включён")
        } catch {
            pinError = (error as? VaultError)?.message ?? "Не удалось сохранить PIN"
            Haptics.error()
        }
    }

    private func disableDuress() {
        Task {
            do {
                try await store.repo.setDuressPIN(nil)
                withAnim { duressOn = false; editingPIN = false }
                Haptics.success()
                store.showToast("Режим «под принуждением» выключен")
            } catch { store.showError(error) }
        }
    }

    private func setWipe(enabled: Bool) {
        var p = wipe; p.enabled = enabled
        apply(p)
        if enabled { Haptics.warning() } else { Haptics.soft() }
    }

    private func setAttempts(_ n: Int) {
        var p = wipe; p.maxAttempts = n
        apply(p)
    }

    private func apply(_ p: WipePolicy) {
        withAnim { wipe = p.clamped }
        Task { await store.repo.setWipePolicy(p.clamped) }
    }
}
