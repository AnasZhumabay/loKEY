import SwiftUI

/// Сроки документов: список по дате с цветом срочности, кольцом-обратным отсчётом, переключателем и правкой.
/// Работает и как sheet, и как push.
struct RemindersView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var items: [DocumentReminder] = []
    @State private var auth: ReminderAuthState = .notDetermined
    @State private var scanning = false
    @State private var scanNote: String?
    @State private var editing: DocumentReminder?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if auth != .granted { permissionCard.lkAppear(0) }
                Button { Task { await scan() } } label: {
                    HStack(spacing: 10) {
                        if scanning { ProgressView().tint(Color.lkBg) } else { Image(systemName: "text.magnifyingglass") }
                        Text("Найти в документах")
                    }
                    .font(.lk(15, .bold)).foregroundStyle(Color.lkBg)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.lkAccent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(LKPressStyle(scale: 0.97)).disabled(scanning).lkAppear(1)
                .accessibilityHint("Ищет даты окончания в открытых кейсах. Закрытые кейсы не просматриваются.")
                if let scanNote {
                    Text(scanNote).font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).padding(.horizontal, 4)
                }
                if items.isEmpty && loaded { emptyState.lkAppear(2) }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, r in
                    row(r).lkAppear(min(i + 2, 8))
                }
                Text("Напоминания хранятся только на этом iPhone в зашифрованном виде. В уведомлении нет названий документов.")
                    .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).padding(.horizontal, 4)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 60)
        }
        .scrollIndicators(.hidden)
        .lkScreen(glow: .lkWarn)
        .task { await reload() }
        .sheet(item: $editing) { r in
            ReminderEditSheet(reminder: r, isNew: !items.contains(where: { $0.id == r.id })) { saved in
                Task { await store.reminders.update(saved); await reload() }
            } onDelete: { id in
                Task { await store.reminders.remove(id: id); await reload() }
            }
            .presentationDetents([.large]).presentationBackground(Color.lkCard)
        }
    }

    // MARK: Блоки

    private var header: some View {
        HStack {
            Text("Сроки документов").font(.lk(28, .heavy)).tracking(-0.8).accessibilityAddTraits(.isHeader)
            Spacer()
            Button { editing = DocumentReminder(fileName: "", expiresOn: Date().addingTimeInterval(86_400 * 365)) } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .bold)).frame(width: 44, height: 44)
                    .background(Color.lkCard, in: Circle())
            }
            .buttonStyle(LKPressStyle()).accessibilityLabel("Добавить срок вручную")
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 44, height: 44)
                    .background(Color.lkCard, in: Circle())
            }
            .buttonStyle(LKPressStyle()).accessibilityLabel("Закрыть")
        }
        .frame(minHeight: 48)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tr(auth == .denied ? "Уведомления выключены" : "Нужно разрешение на уведомления"), systemImage: "bell.badge")
                .font(.lk(15, .bold)).foregroundStyle(Color.lkWarn)
            Text(auth == .denied
                 ? "Включите уведомления для loKEY в настройках iPhone, иначе напоминания не придут."
                 : "Напомним за 30, 7 и 1 день до конца срока в 9:00.")
                .font(.lk(13, .medium)).foregroundStyle(Color.lkText2)
            Button {
                if auth == .denied {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                } else {
                    Task { _ = await store.reminders.requestAuthorization(); await reload() }
                }
            } label: {
                Text(auth == .denied ? "Открыть настройки" : "Разрешить уведомления")
                    .font(.lk(14, .bold)).foregroundStyle(Color.lkBg).padding(.horizontal, 16)
                    .frame(minHeight: 44).background(Color.lkWarn, in: Capsule())
            }
            .buttonStyle(LKPressStyle())
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .lkCard(radius: 20, fill: Color.lkWarn.opacity(0.08), stroke: Color.lkWarn.opacity(0.3))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 34)).foregroundStyle(Color.lkMuted)
            Text("Сроков пока нет").font(.lk(16, .bold))
            Text("Откройте кейс с документами и нажмите «Найти в документах» или добавьте срок вручную.")
                .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity).lkCard(radius: 20)
        .accessibilityElement(children: .combine)
    }

    private func row(_ r: DocumentReminder) -> some View {
        let days = r.daysLeft(now: Date())
        let tint = Self.urgencyColor(days)
        return HStack(spacing: 14) {
            CountdownRing(days: days, tint: tint, animate: !reduceMotion)
            Button { editing = r } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.fileName.isEmpty ? r.kind.title : r.fileName).font(.lk(15, .bold)).lineLimit(2)
                        .foregroundStyle(Color.lkText)
                    Text(subtitle(r, days)).font(.lk(12, .semibold)).foregroundStyle(tint).lineLimit(2)
                    if !r.caseName.isEmpty {
                        Text(r.caseName).font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Изменить срок")
            Toggle("Напоминать", isOn: Binding(get: { r.enabled }, set: { on in
                var u = r; u.enabled = on
                Task { await store.reminders.update(u); await reload() }
            }))
            .labelsHidden().tint(Color.lkAccent).frame(minWidth: 52, minHeight: 44)
            .accessibilityLabel(trf("Напоминать о сроке: %@", r.fileName.isEmpty ? tr(r.kind.title) : r.fileName))
        }
        .padding(14).lkCard(radius: 20)
        .opacity(r.enabled ? 1 : 0.6)
    }

    private func subtitle(_ r: DocumentReminder, _ days: Int) -> String {
        let date = r.expiresOn.formatted(.dateTime.day().month(.abbreviated).year())
        let left: String
        if days < 0 { left = LKBundle.string("просрочен") }
        else if days == 0 { left = LKBundle.string("истекает сегодня") }
        else { left = String(format: LKBundle.string("осталось %lld дн."), days) }
        return "\(left) · \(date)"
    }

    static func urgencyColor(_ days: Int) -> Color {
        if days < 0 { return .lkDanger }
        if days <= 7 { return .lkDanger }
        if days <= 30 { return .lkWarn }
        return .lkAccent
    }

    // MARK: Действия

    private func reload() async {
        items = await store.reminders.list()
        auth = await store.reminders.authorizationState()
        loaded = true
    }

    private func scan() async {
        scanning = true; scanNote = nil
        let found = await store.reminders.scan()
        await reload()
        scanning = false
        let locked = store.cases.filter { !$0.isUnlocked }.count
        var note = found.isEmpty ? tr("Новых сроков не нашли.") : trf("Найдено сроков: %lld.", found.count)
        if locked > 0 { note += " " + tr("Закрытые кейсы не просматриваются: откройте их и повторите.") }
        scanNote = note
        found.isEmpty ? Haptics.soft() : Haptics.success()
    }
}

/// Кольцо с числом дней. При «уменьшении движения» рисуется сразу, без анимации.
private struct CountdownRing: View {
    let days: Int
    let tint: Color
    let animate: Bool
    @State private var shown = false

    private var fraction: Double {
        if days < 0 { return 1 }
        return max(0.04, 1 - min(Double(days), 365) / 365)
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.lkTrack, lineWidth: 5)
            Circle().trim(from: 0, to: (shown || !animate) ? fraction : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text(days < 0 ? "!" : "\(days)").font(.lk(days >= 100 ? 14 : 17, .heavy)).foregroundStyle(tint)
                if days >= 0 { Text("дн.").font(.lk(9, .bold)).foregroundStyle(Color.lkMuted) }
            }
        }
        .frame(width: 52, height: 52)
        .onAppear { if animate { withAnimation(.easeOut(duration: 0.9)) { shown = true } } }
        .accessibilityHidden(true)
    }
}

/// Правка срока: вид документа, дата вручную, за сколько дней напомнить.
private struct ReminderEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var reminder: DocumentReminder
    let isNew: Bool
    let onSave: (DocumentReminder) -> Void
    let onDelete: (String) -> Void
    @State private var confirmDelete = false
    private let options = [30, 14, 7, 3, 1]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Capsule().fill(Color(hex: 0x3A414B)).frame(width: 40, height: 5).frame(maxWidth: .infinity)
                Text(isNew ? "Новый срок" : "Изменить срок").font(.lk(22, .heavy)).accessibilityAddTraits(.isHeader)

                field("Название") {
                    TextField("Например, загранпаспорт", text: $reminder.fileName)
                        .textFieldStyle(.plain).frame(minHeight: 44)
                }
                field("Вид документа") {
                    Picker("Вид документа", selection: $reminder.kind) {
                        ForEach(ReminderKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).tint(Color.lkAccent).frame(minHeight: 44, alignment: .leading)
                }
                field("Действителен до") {
                    DatePicker("Действителен до", selection: $reminder.expiresOn, displayedComponents: .date)
                        .labelsHidden().tint(Color.lkAccent).frame(minHeight: 44, alignment: .leading)
                }
                field("Напомнить за") {
                    HStack(spacing: 8) {
                        ForEach(options, id: \.self) { n in
                            let on = reminder.notifyDaysBefore.contains(n)
                            Button {
                                if on { reminder.notifyDaysBefore.removeAll { $0 == n } } else { reminder.notifyDaysBefore.append(n) }
                            } label: {
                                Text(verbatim: trf("%lld дн.", n)).font(.lk(13, .bold))
                                    .foregroundStyle(on ? Color.lkBg : Color.lkText2)
                                    .frame(minWidth: 52, minHeight: 44)
                                    .background(on ? Color.lkAccent : Color.lkRaised, in: Capsule())
                            }
                            .buttonStyle(LKPressStyle())
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
                Button {
                    var r = reminder
                    r.source = .manual
                    r.fileName = r.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(r); dismiss()
                } label: {
                    Text("Сохранить").font(.lk(16, .bold)).foregroundStyle(Color.lkBg)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.lkAccent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(LKPressStyle(scale: 0.97))
                if !isNew {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text("Удалить напоминание").font(.lk(15, .bold)).foregroundStyle(Color.lkDanger)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
            }
            .padding(20)
        }
        .preferredColorScheme(.dark).foregroundStyle(Color.lkText)
        .confirmationDialog("Удалить напоминание?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { onDelete(reminder.id); dismiss() }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.lk(12, .heavy)).tracking(1).foregroundStyle(Color.lkMuted)
            content().padding(.horizontal, 14).frame(maxWidth: .infinity, alignment: .leading)
                .lkCard(radius: 16, fill: Color.lkCard2)
        }
    }
}

/// Карточка-вход «Сроки» (для Главной или Настроек): ближайший срок и переход на экран.
struct RemindersEntryCard: View {
    @Environment(AppStore.self) private var store
    @State private var next: DocumentReminder?
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.lkWarn)
                    .frame(width: 40, height: 40).background(Color.lkWarn.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Сроки").font(.lk(15, .bold))
                    Text(next.map { "\($0.kind.title) · \($0.daysLeft(now: Date())) дн." } ?? "Напоминания о документах")
                        .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.lkMuted)
            }
            .padding(14).frame(minHeight: 64).lkCard(radius: 20).contentShape(Rectangle())
        }
        .buttonStyle(LKPressStyle(scale: 0.98))
        .accessibilityLabel("Сроки документов")
        .task { next = await store.reminders.list().first { $0.enabled && $0.daysLeft(now: Date()) >= 0 } }
        .sheet(isPresented: $show, onDismiss: { Task { next = await store.reminders.list().first { $0.enabled && $0.daysLeft(now: Date()) >= 0 } } }) {
            RemindersView().environment(store).presentationDetents([.large]).presentationBackground(Color.lkBg)
        }
    }
}
