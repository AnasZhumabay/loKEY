// Экран «Резервная копия»: статус, место, фраза, создание, список, восстановление, честные ограничения.
import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var destination: BackupDestination = .iCloud
    @State private var pass = ""
    @State private var confirm = ""
    @State private var last: Date?
    @State private var auto = false
    @State private var backups: [BackupSummary] = []
    @State private var progress = 0.0
    @State private var running = false
    @State private var error: String?
    @State private var created: BackupSummary?
    @State private var restoring: BackupSummary?
    @State private var restorePass = ""
    @State private var report: RestoreReport?
    @State private var importing = false
    @State private var importedData: Data?
    @State private var task: Task<Void, Never>?

    private var strength: Int { SecurityRules.passphraseStrength(pass) }
    private var canCreate: Bool { pass.count >= 10 && pass == confirm && !running }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                LKTopBar(title: tr("Резервная копия"))
                statusCard.lkAppear(0)
                destinationCard.lkAppear(1)
                passphraseCard.lkAppear(2)
                createButton.lkAppear(3)
                listCard.lkAppear(4)
                autoRow.lkAppear(5)
                limitsCard.lkAppear(6)
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
        }
        .lkScreen()
        .navigationBarBackButtonHidden(true)
        .task { await refresh() }
        .sheet(item: $restoring) { s in restoreSheet(s) }
        .sheet(item: $report) { r in reportSheet(r) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { res in
            guard case .success(let url) = res else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: url) {
                importedData = d
                restoring = BackupSummary(id: "import", destination: .localFile, createdAt: Date(), sizeBytes: Int64(d.count),
                                          deviceName: "", appVersion: "", formatVersion: 1, remoteName: url.lastPathComponent)
            }
        }
    }

    // MARK: Карточки

    private var statusCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.lkTrack, lineWidth: 8)
                Circle().trim(from: 0, to: running ? progress : (last == nil ? 0 : 1))
                    .stroke(Color.lkAccent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : LKMotion.soft, value: progress)
                Image(systemName: running ? "arrow.up.circle" : "externaldrive.badge.checkmark")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.lkAccent)
            }
            .frame(width: 72, height: 72)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(running ? tr("Идёт копирование") : tr("Последняя копия")).font(.lk(13, .bold)).foregroundStyle(Color.lkMuted)
                Text(running ? "\(Int(progress * 100))%" : (last.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? tr("Ещё не создавалась")))
                    .font(.lk(18, .heavy)).foregroundStyle(Color.lkText)
            }
            Spacer()
        }
        .padding(18).lkCard()
        .accessibilityElement(children: .combine)
        .accessibilityValue(running ? "\(Int(progress * 100)) %" : "")
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Куда сохранить")).font(.lk(13, .bold)).foregroundStyle(Color.lkText2)
            HStack(spacing: 8) {
                ForEach(BackupDestination.allCases) { d in
                    Button { withAnimation(LKMotion.snappy) { destination = d } } label: {
                        VStack(spacing: 6) {
                            Image(systemName: icon(d)).font(.system(size: 20, weight: .semibold))
                            Text(title(d)).font(.lk(13, .bold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .foregroundStyle(destination == d ? Color.lkBg : Color.lkText2)
                        .background(destination == d ? Color.lkAccent : Color.lkCard2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(LKPressStyle())
                    .accessibilityLabel(tr(title(d)))
                    .accessibilityAddTraits(destination == d ? .isSelected : [])
                }
            }
        }
        .padding(18).lkCard()
    }

    private var passphraseCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            LKField(title: tr("Фраза для копии")) { SecureField(tr("Не менее 10 символов"), text: $pass).textContentType(.newPassword) }
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(i < strength ? meterColor : Color.lkTrack).frame(height: 5)
                }
            }
            .animation(reduceMotion ? nil : LKMotion.snappy, value: strength)
            .accessibilityElement().accessibilityLabel(tr("Надёжность фразы")).accessibilityValue("\(strength) / 4")
            if !pass.isEmpty && pass.count < 10 {
                Label(tr("Фраза слишком короткая: нужно не менее 10 символов"), systemImage: "exclamationmark.triangle")
                    .font(.lk(13, .semibold)).foregroundStyle(Color.lkWarn)
            } else if !pass.isEmpty && strength < 2 {
                Label(tr("Слабая фраза: добавьте длину, цифры и символы"), systemImage: "exclamationmark.triangle")
                    .font(.lk(13, .semibold)).foregroundStyle(Color.lkWarn)
            }
            LKField(title: tr("Повторите фразу"), error: (!confirm.isEmpty && confirm != pass) ? tr("Фразы не совпадают") : nil) {
                SecureField("", text: $confirm).textContentType(.newPassword)
            }
        }
        .padding(18).lkCard()
    }

    private var meterColor: Color { strength <= 1 ? .lkDanger : (strength == 2 ? .lkWarn : .lkAccent) }

    private var createButton: some View {
        VStack(spacing: 10) {
            if let error {
                Label(tr(error), systemImage: "xmark.octagon").font(.lk(13, .semibold)).foregroundStyle(Color.lkDanger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let c = created, let url = c.fileURL {
                ShareLink(item: url) { Label(tr("Поделиться файлом"), systemImage: "square.and.arrow.up") }
                    .buttonStyle(.lkSecondary)
            }
            Button {
                if running { task?.cancel() } else { start() }
            } label: {
                Text(running ? tr("Отмена") : tr("Создать копию")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.lkPrimary)
            .disabled(!running && !canCreate)
        }
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("Копии")).font(.lk(13, .bold)).foregroundStyle(Color.lkText2)
                Spacer()
                Button(tr("Восстановить из файла")) { importing = true }.font(.lk(13, .bold)).foregroundStyle(Color.lkAccent)
            }
            if backups.isEmpty {
                Text(tr("Копий пока нет")).font(.lk(14)).foregroundStyle(Color.lkMuted).padding(.vertical, 6)
            }
            ForEach(backups) { b in
                HStack(spacing: 12) {
                    Image(systemName: icon(b.destination)).foregroundStyle(Color.lkAccent).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.lk(15, .bold))
                        Text("\(title(b.destination)) · \(ByteCountFormatter.string(fromByteCount: b.sizeBytes, countStyle: .file))")
                            .font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted)
                    }
                    Spacer()
                    Button { restorePass = ""; error = nil; restoring = b } label: { Image(systemName: "arrow.counterclockwise") }
                        .frame(width: 44, height: 44).accessibilityLabel(tr("Восстановить"))
                    Button(role: .destructive) { Task { await remove(b) } } label: { Image(systemName: "trash") }
                        .frame(width: 44, height: 44).accessibilityLabel(tr("Удалить"))
                }
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(18).lkCard()
        .animation(reduceMotion ? nil : LKMotion.spring, value: backups)
    }

    private var autoRow: some View {
        Toggle(isOn: Binding(get: { auto }, set: { v in auto = v; Task { await store.backup.setAutoBackup(v) } })) {
            Text(tr("Автокопия")).font(.lk(15, .bold))
        }
        .tint(Color.lkAccent).padding(18).lkCard()
    }

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tr("Что важно знать"), systemImage: "info.circle").font(.lk(14, .heavy)).foregroundStyle(Color.lkText)
            ForEach(["Копия содержит только файлы открытых кейсов, перешифрованные вашей фразой. Закрытые кейсы в неё не попадают.",
                     "Потерянную фразу восстановить нельзя: мы её не храним.",
                     "При восстановлении создаются новые кейсы с новыми ключами; сохраните их и 12 слов заново.",
                     "Надёжность зависит от фразы: чем длиннее, тем лучше."], id: \.self) { t in
                Text(tr(t)).font(.lk(13)).foregroundStyle(Color.lkText2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18).lkCard()
    }

    // MARK: Листы

    private func restoreSheet(_ s: BackupSummary) -> some View {
        VStack(spacing: 16) {
            Text(tr("Фраза восстановления копии")).font(.lk(18, .heavy)).padding(.top, 24)
            LKField(title: tr("Фраза для копии"), error: error) { SecureField("", text: $restorePass) }
            Button {
                start(restore: s)
            } label: { Text(running ? "\(Int(progress * 100))%" : tr("Восстановить")).frame(maxWidth: .infinity) }
                .buttonStyle(.lkPrimary).disabled(restorePass.isEmpty || running)
            ProgressView(value: progress).tint(Color.lkAccent).opacity(running ? 1 : 0)
            Spacer()
        }
        .padding(.horizontal, 20).lkScreen().presentationDetents([.medium])
    }

    private func reportSheet(_ r: RestoreReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("Отчёт о восстановлении"), systemImage: "checkmark.seal").font(.lk(18, .heavy)).padding(.top, 24)
            Text(String(format: tr("Кейсов: %d"), r.restoredCases)).font(.lk(15, .bold))
            Text(String(format: tr("Файлов: %d"), r.restoredFiles)).font(.lk(15, .bold))
            Text(String(format: tr("Пропущено: %d"), r.skippedFiles.count + r.skippedLockedCases.count)).font(.lk(15, .bold))
            ForEach(r.warnings, id: \.self) { w in Label(tr(w), systemImage: "exclamationmark.triangle").font(.lk(13)).foregroundStyle(Color.lkWarn) }
            Spacer()
            Button { report = nil } label: { Text(tr("Готово")).frame(maxWidth: .infinity) }.buttonStyle(.lkPrimary)
        }
        .padding(.horizontal, 20).lkScreen().presentationDetents([.medium, .large])
    }

    // MARK: Действия

    private func start() {
        error = nil; created = nil; running = true; progress = 0
        let d = destination, p = pass
        task = Task {
            do {
                let s = try await store.backup.createBackup(destination: d, passphrase: p) { v in Task { @MainActor in progress = v } }
                created = s; pass = ""; confirm = ""
                await refresh()
            } catch let e as BackupError { error = e.message } catch is CancellationError { error = BackupError.cancelled.message } catch let other { _ = other; error = tr("Не удалось выполнить операцию") }
            running = false
        }
    }

    private func start(restore s: BackupSummary) {
        error = nil; running = true; progress = 0
        let p = restorePass, data = importedData
        task = Task {
            do {
                let prog: @Sendable (Double) -> Void = { v in Task { @MainActor in progress = v } }
                let r: RestoreReport
                if s.id == "import", let data { r = try await store.backup.restore(archive: data, passphrase: p, progress: prog) }
                else { r = try await store.backup.restore(s, passphrase: p, progress: prog) }
                restoring = nil; importedData = nil; restorePass = ""
                report = r
            } catch let e as BackupError { error = e.message } catch let other { _ = other; error = tr("Не удалось выполнить операцию") }
            running = false
        }
    }

    private func remove(_ b: BackupSummary) async {
        do { try await store.backup.delete(b) } catch let e as BackupError { error = e.message } catch let other { _ = other; error = tr("Не удалось выполнить операцию") }
        await refresh()
    }

    private func refresh() async {
        last = await store.backup.lastBackupDate
        auto = await store.backup.autoBackupEnabled
        backups = await store.backup.listBackups()
    }

    private func icon(_ d: BackupDestination) -> String {
        switch d { case .iCloud: return "icloud"; case .server: return "server.rack"; case .localFile: return "doc.zipper" }
    }
    private func title(_ d: BackupDestination) -> String {
        switch d { case .iCloud: return "iCloud"; case .server: return tr("Сервер"); case .localFile: return tr("Файл") }
    }
}

extension RestoreReport: Identifiable { var id: String { newCaseIDs.joined() + "\(restoredFiles)" } }
