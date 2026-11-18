import SwiftUI

/// Устройства и сеансы: где выполнен вход, завершить один или все остальные.
struct SessionsView: View {
    @Environment(AppStore.self) private var store

    @State private var sessions: [DeviceSession] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var busyID: String?
    @State private var confirmAll = false
    @State private var revoking: DeviceSession?

    private var others: [DeviceSession] { sessions.filter { !$0.isCurrent } }

    var body: some View {
        VStack(spacing: 0) {
            LKTopBar(title: "Устройства") { Color.clear }.padding(.horizontal, 20).padding(.top, 8)
            content
        }
        .lkScreen()
        .navigationBarBackButtonHidden(true).toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .confirmationDialog("Завершить все другие сеансы?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button(trf("Завершить на %lld устр.", others.count), role: .destructive) { Task { await revokeOthers() } }
            Button("Отмена", role: .cancel) {}
        } message: { Text("На этих устройствах придётся войти заново. Ключи кейсов не затрагиваются.") }
        .confirmationDialog("Завершить сеанс?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible, presenting: revoking) { s in
            Button(trf("Завершить «%@»", s.deviceName), role: .destructive) { Task { await revoke(s) } }
            Button("Отмена", role: .cancel) {}
        }
    }

    @ViewBuilder private var content: some View {
        if loading && sessions.isEmpty {
            Spacer(); ProgressView().tint(Color.lkAccent); Spacer()
        } else if let loadError, sessions.isEmpty {
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
                    Text("Здесь все устройства, где выполнен вход в ваш аккаунт. Не узнаёте устройство — завершите сеанс и смените пароль.")
                        .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
                    VStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { i, s in
                            if i > 0 { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
                            row(s).lkAppear(i)
                        }
                    }
                    .padding(.horizontal, 16).lkCard(radius: 22)

                    if !others.isEmpty {
                        Button { confirmAll = true } label: { Text("Завершить все другие сеансы") }
                            .buttonStyle(.lkSecondary).foregroundStyle(Color.lkDanger)
                            .disabled(busyID != nil)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 40)
            }
            .refreshable { await load() }
        }
    }

    private func row(_ s: DeviceSession) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon(s)).font(.system(size: 20, weight: .semibold))
                .foregroundStyle(s.isCurrent ? Color.lkAccent : Color.lkText2)
                .frame(width: 42, height: 42)
                .background((s.isCurrent ? Color.lkAccent : Color.white).opacity(s.isCurrent ? 0.14 : 0.06),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.deviceName).font(.lk(15, .bold)).lineLimit(1)
                    if s.isCurrent {
                        Text("ЭТО УСТРОЙСТВО").font(.lk(10, .heavy)).tracking(0.5).foregroundStyle(Color.lkAccent)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.lkAccent.opacity(0.14), in: Capsule())
                    }
                }
                Text(subtitle(s)).font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).lineLimit(2)
            }
            Spacer(minLength: 8)
            if !s.isCurrent {
                if busyID == s.id { ProgressView().tint(Color.lkAccent) }
                else {
                    Button { revoking = s } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.lkDanger).frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(LKPressStyle(scale: 0.88)).accessibilityLabel(trf("Завершить сеанс %@", s.deviceName))
                }
            }
        }
        .frame(minHeight: 66)
        .accessibilityElement(children: .combine)
    }

    private func icon(_ s: DeviceSession) -> String {
        switch s.platform {
        case "web": return "safari"
        case "android": return "smartphone"
        default: return s.deviceName.lowercased().contains("ipad") ? "ipad" : "iphone"
        }
    }
    private func subtitle(_ s: DeviceSession) -> String {
        var parts: [String] = []
        if s.isCurrent { parts.append("Активен сейчас") }
        else { parts.append(trf("Был(а) %@", Self.rel.localizedString(for: s.lastActiveAt, relativeTo: Date()))) }
        if let l = s.approxLocation { parts.append(l) }
        if let v = s.appVersion { parts.append("v\(v)") }
        return parts.joined(separator: " · ")
    }
    private static var rel: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter(); f.locale = LKBundle.uiLocale; f.unitsStyle = .short; return f
    }

    private func load() async {
        loading = true; loadError = nil
        defer { loading = false }
        do { sessions = try await store.repo.listSessions() }
        catch { loadError = (error as? VaultError)?.message ?? "Не удалось загрузить устройства" }
    }
    private func revoke(_ s: DeviceSession) async {
        busyID = s.id; defer { busyID = nil }
        do {
            try await store.repo.revokeSession(id: s.id)
            withAnimation(LKMotion.spring) { sessions.removeAll { $0.id == s.id } }
            Haptics.success(); store.showToast("Сеанс завершён")
        } catch { store.showError(error) }
    }
    private func revokeOthers() async {
        busyID = "all"; defer { busyID = nil }
        do {
            try await store.repo.revokeOtherSessions()
            withAnimation(LKMotion.spring) { sessions.removeAll { !$0.isCurrent } }
            Haptics.success(); store.showToast("Другие сеансы завершены")
        } catch { store.showError(error) }
    }
}
