import SwiftUI

struct AuthView: View {
    @Environment(AppStore.self) private var store

    private enum Mode { case login, register }
    private enum Field: Hashable { case identifier, email, username, password, code }

    @State private var mode: Mode = .login
    @State private var identifier = ""
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var errors: [Field: String] = [:]
    @State private var formError: String?
    @State private var loading = false
    @State private var mfaChallenge: String?
    @State private var code = ""
    @State private var showReset = false
    @FocusState private var focus: Field?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    titleBlock.padding(.top, 36)
                    if mfaChallenge == nil { modeSwitch.padding(.top, 24) }
                    Group { if mfaChallenge == nil { form } else { mfaForm } }
                        .padding(.top, 24)
                    actions.padding(.top, 28).id("actions")
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield").foregroundStyle(Color.lkAccent)
                        Text("Сквозное шифрование · AES-256-GCM")
                    }
                    .font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted)
                    .frame(maxWidth: .infinity).padding(.top, 16)
                }
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focus) { _, f in
                if f != nil { withAnimation { proxy.scrollTo("actions", anchor: .bottom) } }
            }
        }
        .lkScreen()
        .sheet(isPresented: $showReset) {
            ResetPasswordSheet(prefill: identifier.contains("@") ? identifier : email)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Секции

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark().frame(width: 40)
            BrandWordmark(size: 24)
        }
        .frame(height: 44)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mfaChallenge != nil ? "Код подтверждения" : (mode == .login ? "С возвращением" : "Создайте аккаунт"))
                .font(.lk(34, .heavy)).tracking(-1.2).minimumScaleFactor(0.7).lineLimit(2)
            Text(mfaChallenge != nil ? "Введите 6 цифр из приложения-аутентификатора."
                 : (mode == .login ? "Войдите, чтобы открыть свои кейсы."
                    : "Аккаунт хранит список кейсов. Файлы шифруются ключами кейсов."))
                .font(.lk(16, .medium)).foregroundStyle(Color(hex: 0xA9B0B8)).lineSpacing(3)
        }
    }

    private var modeSwitch: some View {
        HStack(spacing: 4) {
            seg("Вход", .login)
            seg("Создать аккаунт", .register)
        }
        .padding(4)
        .background(Color.lkCard, in: Capsule())
        .overlay(Capsule().stroke(Color.lkBorder, lineWidth: 1))
    }

    private func seg(_ title: String, _ m: Mode) -> some View {
        Button {
            guard mode != m else { return }
            withAnimation(.easeInOut(duration: 0.2)) { mode = m }
            errors = [:]; formError = nil
        } label: {
            Text(title).font(.lk(14, mode == m ? .bold : .semibold))
                .foregroundStyle(mode == m ? Color.lkBg : Color.lkText2)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(mode == m ? Color.lkText : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == m ? .isSelected : [])
    }

    private var form: some View {
        VStack(spacing: 18) {
            if mode == .login {
                LKField(title: "Email или имя пользователя", error: errors[.identifier]) {
                    TextField("", text: $identifier, prompt: prompt("name@example.com"))
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.next).focused($focus, equals: .identifier)
                        .onSubmit { focus = .password }
                }
            } else {
                LKField(title: "Email", error: errors[.email]) {
                    TextField("", text: $email, prompt: prompt("name@example.com"))
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.next).focused($focus, equals: .email)
                        .onSubmit { focus = .username }
                }
                LKField(title: "Имя пользователя", error: errors[.username]) {
                    TextField("", text: $username, prompt: prompt("username"))
                        .textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.next).focused($focus, equals: .username)
                        .onSubmit { focus = .password }
                }
            }
            VStack(alignment: .trailing, spacing: 4) {
                LKField(title: "Пароль", error: errors[.password]) {
                    HStack(spacing: 0) {
                        Group {
                            if showPassword {
                                TextField("", text: $password, prompt: prompt(mode == .login ? "Ваш пароль" : "Минимум 8 символов"))
                            } else {
                                SecureField("", text: $password, prompt: prompt(mode == .login ? "Ваш пароль" : "Минимум 8 символов"))
                            }
                        }
                        .textContentType(mode == .login ? .password : .newPassword)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(mode == .login ? .go : .done)
                        .focused($focus, equals: .password)
                        .onSubmit { Task { await submit() } }
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.system(size: 17)).foregroundStyle(Color.lkMuted)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr(showPassword ? "Скрыть пароль" : "Показать пароль"))
                        .padding(.trailing, -12)
                    }
                }
                if mode == .login {
                    Button("Забыли пароль?") { showReset = true }
                        .font(.lk(13, .semibold)).foregroundStyle(Color.lkAccent)
                        .frame(minHeight: 44)
                }
            }
        }
    }

    private var mfaForm: some View {
        LKField(title: "6-значный код", error: errors[.code]) {
            TextField("", text: $code, prompt: prompt("000000"))
                .font(.lkMono(22, .semibold)).tracking(6)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .focused($focus, equals: .code)
                .onChange(of: code) { _, v in
                    let d = String(v.filter(\.isNumber).prefix(6))
                    if d != v { code = d }
                    errors[.code] = nil
                    if d.count == 6 && !loading { Task { await submit() } }
                }
        }
        .onAppear { focus = .code }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if let formError {
                Label(tr(formError), systemImage: "exclamationmark.triangle.fill")
                    .font(.lk(13, .semibold)).foregroundStyle(Color.lkDanger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { Task { await submit() } } label: {
                if loading { ProgressView().tint(Color.lkBg) }
                else { Text(primaryTitle) }
            }
            .buttonStyle(.lkPrimary)
            .disabled(loading)
            if mfaChallenge != nil {
                Button("Назад") {
                    mfaChallenge = nil; code = ""; errors = [:]; formError = nil
                }
                .buttonStyle(.lkSecondary)
            }
        }
    }

    private var primaryTitle: String {
        if mfaChallenge != nil { return "Подтвердить" }
        return mode == .login ? "Войти" : "Создать аккаунт"
    }

    private func prompt(_ s: String) -> Text { Text(s).foregroundColor(.lkMuted) }

    // MARK: Логика

    private func validate() -> Bool {
        errors = [:]
        if mfaChallenge != nil {
            if code.count != 6 { errors[.code] = "Введите 6 цифр" }
        } else if mode == .login {
            if identifier.trimmingCharacters(in: .whitespaces).isEmpty { errors[.identifier] = "Введите email или имя" }
            if password.isEmpty { errors[.password] = "Введите пароль" }
        } else {
            let e = email.trimmingCharacters(in: .whitespaces)
            if !(e.contains("@") && e.contains(".") && e.count >= 5) { errors[.email] = "Проверьте адрес почты" }
            if username.trimmingCharacters(in: .whitespaces).count < 3 { errors[.username] = "Минимум 3 символа" }
            if password.count < 8 { errors[.password] = "Минимум 8 символов" }
        }
        if let first = [Field.identifier, .email, .username, .password, .code].first(where: { errors[$0] != nil }) {
            focus = first
            Haptics.warning()
        }
        return errors.isEmpty
    }

    private func submit() async {
        guard !loading else { return }
        formError = nil
        guard validate() else { return }
        loading = true
        focus = nil
        defer { loading = false }
        do {
            if let ch = mfaChallenge {
                try await store.verifyMFA(challengeId: ch, code: code)
            } else if mode == .login {
                let outcome = try await store.login(identifier: identifier.trimmingCharacters(in: .whitespaces), password: password)
                if case .mfaRequired(let id) = outcome {
                    withAnimation { mfaChallenge = id }
                    code = ""
                }
            } else {
                try await store.register(email: email.trimmingCharacters(in: .whitespaces),
                                         username: username.trimmingCharacters(in: .whitespaces),
                                         password: password)
            }
        } catch {
            let msg = (error as? VaultError)?.message ?? "Что-то пошло не так"
            Haptics.error()
            if mfaChallenge != nil { errors[.code] = msg; code = "" }
            else { formError = msg }
        }
    }
}

// MARK: - Сброс пароля

private struct ResetPasswordSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let prefill: String
    @State private var email = ""
    @State private var error: String?
    @State private var loading = false
    @State private var sent = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(sent ? "Письмо отправлено" : "Сброс пароля").font(.lk(26, .heavy)).tracking(-0.6)
            Text(verbatim: sent ? trf("Если такой аккаунт есть, мы отправили на %@ ссылку для сброса пароля.", email)
                 : tr("Укажите email аккаунта — отправим ссылку для сброса пароля. Ключи кейсов это не затрагивает."))
                .font(.lk(15, .medium)).foregroundStyle(Color(hex: 0xA9B0B8)).lineSpacing(3)
            if !sent {
                LKField(title: "Email", error: error) {
                    TextField("", text: $email, prompt: Text("name@example.com").foregroundColor(.lkMuted))
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.send).focused($focused)
                        .onSubmit { Task { await send() } }
                }
            }
            Spacer(minLength: 0)
            Button {
                if sent { dismiss() } else { Task { await send() } }
            } label: {
                if loading { ProgressView().tint(Color.lkBg) } else { Text(sent ? "Готово" : "Отправить ссылку") }
            }
            .buttonStyle(.lkPrimary).disabled(loading)
        }
        .padding(24)
        .lkScreen()
        .onAppear { email = prefill; focused = true }
    }

    private func send() async {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard e.contains("@"), e.contains(".") else { error = "Проверьте адрес почты"; return }
        error = nil; loading = true
        defer { loading = false }
        do {
            try await store.repo.requestPasswordReset(email: e)
            withAnimation { sent = true }
        } catch {
            self.error = (error as? VaultError)?.message ?? "Не удалось отправить письмо"
        }
    }
}
