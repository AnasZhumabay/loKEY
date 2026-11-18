import SwiftUI

struct JournalView: View {
    @Environment(AppStore.self) private var store

    private enum LoadState { case loading, loaded, failed(String) }
    private enum JFilter: String, CaseIterable { case all = "Все", logins = "Входы", cases = "Кейсы", files = "Файлы", errors = "Ошибки" }

    @State private var events: [AuditEvent] = []
    @State private var state: LoadState = .loading
    @State private var filter: JFilter = .all

    private func matches(_ k: AuditKind, _ f: JFilter) -> Bool {
        switch f {
        case .all: return true
        case .logins: return [.login, .logout, .loginFailed, .mfaChanged].contains(k)
        case .cases: return [.caseCreated, .caseUnlocked, .caseLocked, .caseDeleted, .keyRecovered].contains(k)
        case .files: return [.fileAdded, .fileTrashed, .fileRestored].contains(k)
        case .errors: return [.loginFailed, .unlockFailed].contains(k)
        }
    }

    private var filtered: [AuditEvent] { events.filter { matches($0.kind, filter) } }

    /// Подряд идущие однотипные события сливаются в одну строку: «Файлы добавлены ×4».
    struct Entry: Identifiable {
        var id: String { events[0].id }
        var events: [AuditEvent]
        var first: AuditEvent { events[0] }
        var count: Int { events.count }
    }

    private static let mergeable: Set<AuditKind> = [.fileAdded, .fileTrashed, .fileRestored, .unlockFailed, .loginFailed]

    private var days: [(Date, [Entry])] {
        let cal = Calendar.current
        let g = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.at) }
        return g.keys.sorted(by: >).map { day in
            var out: [Entry] = []
            for e in g[day, default: []].sorted(by: { $0.at > $1.at }) {
                if let last = out.last, Self.mergeable.contains(e.kind), last.first.kind == e.kind,
                   last.first.caseName == e.caseName, last.first.deviceName == e.deviceName {
                    out[out.count - 1].events.append(e)
                } else { out.append(Entry(events: [e])) }
            }
            return (day, out)
        }
    }

    /// Самое частое устройство: подпись «Этот iPhone» под каждой строкой — шум, показываем только чужие.
    private var mainDevice: String? {
        Dictionary(grouping: events, by: \.deviceName).max { $0.value.count < $1.value.count }?.key
    }

    private var weekEvents: [AuditEvent] {
        let from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        return events.filter { $0.at >= from }
    }
    private var failedCount: Int { weekEvents.filter { [.loginFailed, .unlockFailed].contains($0.kind) }.count }
    private var unlockCount: Int { weekEvents.filter { $0.kind == .caseUnlocked }.count }
    private var loginCount: Int { weekEvents.filter { $0.kind == .login }.count }

    private func count(_ f: JFilter) -> Int { events.filter { matches($0.kind, f) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Журнал").font(.lk(30, .heavy)).tracking(-0.9)
                .frame(height: 44, alignment: .leading).padding(.horizontal, 16).padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(JFilter.allCases, id: \.self) { f in
                        let n = count(f)
                        LKChip(title: f.rawValue, count: f == .all || n == 0 ? nil : n, selected: filter == f) {
                            withAnimation(LKMotion.snappy) { filter = f }
                        }
                    }
                }.padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            content
        }
        .lkScreen()
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading where events.isEmpty:
            ScrollView { LKSkeletonRows(count: 6, height: 62) }.scrollDisabled(true)
        case .failed(let m) where events.isEmpty:
            message("exclamationmark.triangle", "Не удалось загрузить", m, "Повторить") { Task { await load() } }
        default:
            if filtered.isEmpty {
                ScrollView {
                    message("clock.arrow.circlepath", "Событий нет",
                            filter == .all ? "Здесь появятся входы, открытия кейсов и действия с файлами." : "В этой категории пока пусто.", nil) {}
                        .frame(minHeight: 400)
                }
                .refreshable { await load() }
            } else { list }
        }
    }

    private var summary: some View {
        let ok = failedCount == 0
        let tint: Color = ok ? .lkAccent : .lkWarn
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .symbolEffect(.pulse, options: .repeating, isActive: !ok)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ok ? "Всё спокойно" : "Были неудачные попытки").font(.lk(17, .heavy)).tracking(-0.3)
                    Text("За последние 7 дней").font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                stat(unlockCount, "Открытий", .lkAccent)
                stat(loginCount, "Входов", .lkText2)
                stat(failedCount, "Ошибок", failedCount == 0 ? .lkText2 : .lkDanger)
            }
        }
        .padding(16)
        .lkCard(radius: 22, stroke: ok ? .lkBorderSoft : Color.lkWarn.opacity(0.5))
    }

    private func stat(_ n: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(.lk(24, .heavy)).tracking(-0.6).foregroundStyle(color)
                .contentTransition(.numericText())
            Text(label).font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                summary.lkAppear(0)
                ForEach(Array(days.enumerated()), id: \.element.0) { di, d in
                    let (day, items) = d
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(dayTitle(day)).font(.lk(13, .bold)).foregroundStyle(Color.lkMuted)
                                .textCase(.uppercase).tracking(0.8)
                            Spacer()
                            Text("\(items.reduce(0) { $0 + $1.count })").font(.lkMono(12, .semibold)).foregroundStyle(Color.lkMuted)
                        }
                        .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, entry in
                                row(entry, isLast: i == items.count - 1)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .lkCard(radius: 22)
                    }.lkAppear(di + 1)
                }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 124)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load() }
    }

    /// Строка таймлайна: иконка на вертикальной линии, заголовок, чип кейса, время.
    private func row(_ entry: Entry, isLast: Bool) -> some View {
        let e = entry.first
        let s = style(e.kind)
        let bad = [.loginFailed, .unlockFailed].contains(e.kind)
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: s.icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(s.color)
                    .frame(width: 34, height: 34)
                    .background(s.color.opacity(0.16), in: Circle())
                if !isLast {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1.5).frame(maxHeight: .infinity)
                        .padding(.top, 4)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title(e.kind, merged: entry.count > 1)).font(.lk(15, .bold)).lineLimit(1).minimumScaleFactor(0.8)
                    if entry.count > 1 {
                        Text("×\(entry.count)").font(.lkMono(11, .bold)).foregroundStyle(s.color)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(s.color.opacity(0.14), in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    if let c = e.caseName {
                        Label(c, systemImage: "folder.fill").labelStyle(.titleAndIcon)
                            .font(.lk(12, .semibold)).foregroundStyle(Color.lkText2).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.07), in: Capsule())
                    }
                    if let d = mainDevice, e.deviceName != d {
                        Label(e.deviceName, systemImage: "iphone.gen3").labelStyle(.titleAndIcon)
                            .font(.lk(12, .semibold)).foregroundStyle(Color.lkWarn).lineLimit(1)
                    }
                }
            }
            .padding(.top, 2)
            Spacer(minLength: 8)
            Text(timeText(entry)).font(.lkMono(12, .medium)).foregroundStyle(Color.lkMuted).padding(.top, 8)
        }
        .padding(.vertical, 6).padding(.horizontal, bad ? 8 : 0)
        .background(bad ? Color.lkDanger.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func timeText(_ entry: Entry) -> String {
        let a = entry.first.at, b = entry.events.last?.at ?? a
        let f = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        return entry.count > 1 && f(a) != f(b) ? "\(f(b))–\(f(a))" : f(a)
    }

    private func style(_ k: AuditKind) -> (icon: String, color: Color) {
        switch k {
        case .login: return ("person.crop.circle.badge.checkmark", .lkText2)
        case .logout: return ("rectangle.portrait.and.arrow.right", .lkText2)
        case .loginFailed: return ("person.crop.circle.badge.exclamationmark", .lkDanger)
        case .caseCreated: return ("folder.badge.plus", .lkPurple)
        case .caseUnlocked: return ("lock.open.fill", .lkAccent)
        case .caseLocked: return ("lock.fill", .lkAccent)
        case .unlockFailed: return ("xmark.shield.fill", .lkDanger)
        case .caseDeleted: return ("trash", .lkDanger)
        case .fileAdded: return ("arrow.up.doc", .lkText2)
        case .fileTrashed: return ("trash", .lkWarn)
        case .fileRestored: return ("arrow.uturn.backward", .lkText2)
        case .keyRecovered: return ("key.fill", .lkPurple)
        case .mfaChanged: return ("lock.shield", .lkText2)
        }
    }

    private func title(_ k: AuditKind, merged: Bool) -> String {
        switch k {
        case .login: return "Вход выполнен"
        case .logout: return "Выход из аккаунта"
        case .loginFailed: return merged ? "Неудачные попытки входа" : "Неудачная попытка входа"
        case .caseCreated: return "Кейс создан"
        case .caseUnlocked: return "Кейс открыт"
        case .caseLocked: return "Кейс закрыт"
        case .unlockFailed: return merged ? "Неверные ключи" : "Неверный ключ"
        case .caseDeleted: return "Кейс удалён"
        case .fileAdded: return merged ? "Файлы добавлены" : "Файл добавлен"
        case .fileTrashed: return merged ? "Файлы удалены" : "Файл удалён"
        case .fileRestored: return merged ? "Файлы восстановлены" : "Файл восстановлен"
        case .keyRecovered: return "Доступ восстановлен"
        case .mfaChanged: return "Двухфакторная защита изменена"
        }
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Сегодня" }
        if cal.isDateInYesterday(d) { return "Вчера" }
        return d.formatted(.dateTime.day().month(.wide).locale(LKBundle.uiLocale))
    }

    private func message(_ icon: String, _ title: String, _ text: String, _ button: String?, _ action: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon).font(.system(size: 32, weight: .semibold)).foregroundStyle(Color.lkAccent)
                .frame(width: 84, height: 84).lkCard(radius: 28)
            Text(title).font(.lk(22, .heavy)).tracking(-0.4)
            Text(text).font(.lk(15, .medium)).foregroundStyle(Color(hex: 0xA9B0B8)).multilineTextAlignment(.center).lineSpacing(3)
            if let button { Button(tr(button), action: action).buttonStyle(.lkPrimary).padding(.top, 10) }
            Spacer()
        }
        .padding(.horizontal, 32).padding(.bottom, 110)
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        do {
            events = try await store.repo.auditLog(limit: 100)
            state = .loaded
        } catch {
            state = .failed((error as? VaultError)?.message ?? "Не получилось загрузить журнал. Проверьте соединение и попробуйте ещё раз.")
        }
    }
}
