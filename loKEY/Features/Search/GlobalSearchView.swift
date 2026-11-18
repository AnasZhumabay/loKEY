import SwiftUI

/// Глобальный поиск: по названиям кейсов и по файлам ОТКРЫТЫХ кейсов (имя, заметка, распознанный текст).
/// Закрытые кейсы расшифровать нельзя, поэтому они не участвуют в поиске. Об этом сказано в интерфейсе.
struct GlobalSearchView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var hits: [FileSearchHit] = []
    @State private var skipped = 0
    @State private var loading = false
    @State private var searched = false
    @State private var recents: [(file: VaultFile, caseName: String)] = []
    @FocusState private var focused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private struct HitGroup: Identifiable {
        let id: String
        let name: String
        let hits: [FileSearchHit]
    }

    private var groups: [HitGroup] {
        var order: [String] = []
        var map: [String: [FileSearchHit]] = [:]
        for h in hits {
            if map[h.caseId] == nil { order.append(h.caseId) }
            map[h.caseId, default: []].append(h)
        }
        return order.compactMap { id in
            guard let list = map[id], let first = list.first else { return nil }
            return HitGroup(id: id, name: first.caseName, hits: list)
        }
    }

    private var caseMatches: [VaultCase] {
        guard !trimmed.isEmpty else { return [] }
        return store.cases.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    lockedNote
                    if trimmed.isEmpty {
                        idleContent
                    } else {
                        resultsContent
                    }
                }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .lkScreen()
        .task { focused = true; await loadRecents() }
        .task(id: query) { await runSearch() }
    }

    // MARK: Шапка

    private var topBar: some View {
        HStack(spacing: 10) {
            LKIconButton(systemName: "chevron.left", label: "Назад") { router.pop() }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.lkMuted)
                TextField("", text: $query, prompt: Text("Поиск по кейсам и файлам").foregroundColor(.lkMuted))
                    .font(.lk(16, .medium)).focused($focused).submitLabel(.search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("globalSearchField")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.lkMuted).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Очистить")
                }
            }
            .padding(.leading, 14).padding(.trailing, query.isEmpty ? 14 : 0).frame(height: 48)
            .lkCard(radius: 16, stroke: Color.white.opacity(0.1))
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
    }

    private var lockedNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.lkMuted).padding(.top, 2)
            Text("Поиск идёт только по открытым кейсам: содержимое закрытых зашифровано и не читается.")
                .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Пустой запрос

    @ViewBuilder private var idleContent: some View {
        if recents.isEmpty {
            stateView(icon: "magnifyingglass",
                      title: "Ищите по названию, заметке или тексту документа",
                      subtitle: store.unlockedCases.isEmpty ? "Откройте кейс, чтобы искать по его файлам." : "Например: паспорт, договор, номер счёта.")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("НЕДАВНИЕ ФАЙЛЫ").font(.lk(11, .heavy)).tracking(1).foregroundStyle(Color.lkMuted)
                VStack(spacing: 0) {
                    ForEach(Array(recents.enumerated()), id: \.element.file.id) { i, r in
                        Button { router.push(.file(fileID: r.file.id, caseID: r.file.caseID)) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: r.file.kind.systemName).font(.system(size: 14, weight: .semibold)).foregroundStyle(r.file.kind.tint)
                                    .frame(width: 36, height: 36).background(r.file.kind.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: r.file.name).font(.lk(14, .bold)).foregroundStyle(Color.lkText).lineLimit(1)
                                    Text(verbatim: r.caseName).font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).lineLimit(1)
                                }
                                Spacer()
                            }
                            .frame(minHeight: 52).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .lkAppear(i)
                        if i < recents.count - 1 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 48) }
                    }
                }
                .padding(.horizontal, 12).lkCard(radius: 20)
            }
        }
    }

    // MARK: Результаты

    @ViewBuilder private var resultsContent: some View {
        if !caseMatches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("КЕЙСЫ").font(.lk(11, .heavy)).tracking(1).foregroundStyle(Color.lkMuted)
                VStack(spacing: 0) {
                    ForEach(Array(caseMatches.enumerated()), id: \.element.id) { i, c in
                        Button {
                            c.isUnlocked ? router.push(.vaultCase(caseID: c.id)) : router.push(.unlock(caseID: c.id))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: c.icon.systemName).font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(c.isUnlocked ? Color.lkAccent : Color.lkText2)
                                    .frame(width: 36, height: 36).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Text(highlighted(c.name, font: .lk(15, .bold), color: .lkText)).lineLimit(1)
                                Spacer()
                                Image(systemName: c.isUnlocked ? "chevron.right" : "lock.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.lkMuted)
                            }
                            .frame(minHeight: 52).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.name + ", " + tr(c.isUnlocked ? "открыт" : "закрыт"))
                        if i < caseMatches.count - 1 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 48) }
                    }
                }
                .padding(.horizontal, 12).lkCard(radius: 20)
            }
        }

        if loading && hits.isEmpty {
            LKSkeletonRows(count: 3, height: 64).accessibilityLabel("Ищем…")
        } else if searched && hits.isEmpty && caseMatches.isEmpty {
            stateView(icon: "doc.text.magnifyingglass", title: "Ничего не найдено",
                      subtitle: store.unlockedCases.isEmpty ? "Откройте кейс, чтобы искать по его файлам." : "Попробуйте другое слово или часть слова.")
        }

        ForEach(Array(groups.enumerated()), id: \.element.id) { gi, g in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.open").font(.system(size: 11, weight: .bold))
                    Text(verbatim: g.name.uppercased()).lineLimit(1)
                    Text(verbatim: "\(g.hits.count)").opacity(0.7)
                }
                .font(.lk(11, .heavy)).tracking(1).foregroundStyle(Color.lkMuted)
                VStack(spacing: 0) {
                    ForEach(Array(g.hits.enumerated()), id: \.element.id) { i, h in
                        hitRow(h)
                        if i < g.hits.count - 1 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 48) }
                    }
                }
                .padding(.horizontal, 12).lkCard(radius: 20)
            }
            .lkAppear(gi)
        }

        if searched && skipped > 0 {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.lkWarn)
                Text(verbatim: skippedText(skipped)).font(.lk(13, .medium)).foregroundStyle(Color.lkText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.lkWarn.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.lkWarn.opacity(0.3), lineWidth: 1))
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        }
    }

    private func hitRow(_ h: FileSearchHit) -> some View {
        Button {
            h.caseIsUnlocked ? router.push(.file(fileID: h.fileId, caseID: h.caseId)) : router.push(.unlock(caseID: h.caseId))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: h.matchedInOCR ? "text.viewfinder" : "doc")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.lkAccent)
                    .frame(width: 36, height: 36).background(Color.lkAccent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(highlighted(h.fileName, font: .lk(14, .bold), color: .lkText)).lineLimit(1)
                    if let s = h.snippet, !s.isEmpty {
                        Text(highlighted(s, font: .lk(12, .medium), color: .lkText2)).lineLimit(3).multilineTextAlignment(.leading)
                    }
                    if h.matchedInOCR {
                        Label("в тексте документа", systemImage: "text.viewfinder")
                            .font(.lk(11, .bold)).foregroundStyle(Color.lkAccent)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Color.lkAccent.opacity(0.14), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8).frame(minHeight: 52, alignment: .topLeading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(h.fileName + ", " + h.caseName + (h.matchedInOCR ? ", " + tr("в тексте документа") : ""))
    }

    private func stateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30, weight: .semibold)).foregroundStyle(Color.lkAccent)
                .frame(width: 72, height: 72).background(Color.lkAccent.opacity(0.12), in: Circle())
            Text(title).font(.lk(17, .heavy)).multilineTextAlignment(.center)
            Text(subtitle).font(.lk(14, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 40).padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: Логика

    private func skippedText(_ n: Int) -> String {
        let a = n % 100, b = n % 10
        let key: String
        if a >= 11 && a <= 14 { key = "%d закрытых кейсов не проверены — откройте их, чтобы искать" }
        else if b == 1 { key = "%d закрытый кейс не проверен — откройте его, чтобы искать" }
        else if b >= 2 && b <= 4 { key = "%d закрытых кейса не проверены — откройте их, чтобы искать" }
        else { key = "%d закрытых кейсов не проверены — откройте их, чтобы искать" }
        return String(format: tr(key), n)
    }

    /// Подсвечивает совпадения запроса (без учёта регистра и диакритики).
    private func highlighted(_ text: String, font: Font, color: Color) -> AttributedString {
        var a = AttributedString(text)
        a.font = font
        a.foregroundColor = color
        let q = trimmed
        guard !q.isEmpty else { return a }
        var from = text.startIndex
        while from < text.endIndex,
              let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            if let ar = Range(r, in: a) {
                a[ar].foregroundColor = .lkAccent
                a[ar].backgroundColor = Color.lkAccent.opacity(0.16)
            }
            from = r.upperBound
        }
        return a
    }

    private func runSearch() async {
        let q = trimmed
        guard !q.isEmpty else {
            hits = []; skipped = 0; loading = false; searched = false
            return
        }
        loading = true
        try? await Task.sleep(for: .milliseconds(250))   // debounce
        guard !Task.isCancelled else { return }
        let found = await store.repo.searchAll(query: q)
        let skippedCount = await store.repo.searchSkippedLockedCount()
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : LKMotion.snappy) {
            hits = found
            skipped = skippedCount
            loading = false
            searched = true
        }
    }

    private func loadRecents() async {
        var out: [(VaultFile, String)] = []
        for c in store.unlockedCases {
            if let fs = try? await store.repo.listFiles(caseID: c.id) { out += fs.map { ($0, c.name) } }
        }
        let top = out.sorted { $0.0.createdAt > $1.0.createdAt }.prefix(8)
        recents = top.map { (file: $0.0, caseName: $0.1) }
    }
}
