// Приманка для режима «под принуждением».
// Правдоподобное, но безобидное содержимое: создаётся ТОЛЬКО в памяти. Реальные ключи, кейсы и файлы
// не загружаются и не расшифровываются. Любые правки живут в памяти до выхода из аккаунта / перезапуска.
import Foundation

final class DecoyVault {
    private struct Item { var file: VaultFile; var data: Data; var previous: [(FileVersion, Data)] = [] }

    private var cases: [VaultCase] = []
    private var unlockedIDs: Set<String> = []
    private var items: [String: Item] = [:]          // fileID → файл

    init(now: Date = Date()) {
        seed(now: now)
    }

    // MARK: Наполнение
    private func newID() -> String { UUID().uuidString.lowercased() }

    private func seed(now: Date) {
        let plan: [(String, CaseIcon, SecurityLevel, [(String, FileKind, String)])] = [
            ("Рецепты", .home, .standard, [
                ("Борщ", .note, "Свёкла, капуста, картофель, морковь, говядина. Варить около полутора часов, подавать со сметаной."),
                ("Шарлотка", .note, "Яблоки, 3 яйца, стакан сахара, стакан муки. Духовка 180°, 40 минут."),
                ("Плов", .note, "Рис, морковь, лук, баранина или говядина, зира. Томить под крышкой без помешивания.")]),
            ("Рабочее", .work, .standard, [
                ("План на неделю", .note, "Понедельник — созвон по проекту. Среда — отчёт. Пятница — разбор задач."),
                ("Список встреч", .note, "Согласовать сроки, отправить договор, забронировать переговорную."),
                ("Черновик отчёта", .pdf, "")])
        ]
        for (i, (name, icon, level, files)) in plan.enumerated() {
            let cid = newID()
            let created = now.addingTimeInterval(-Double(86_400 * (20 + i * 9)))
            var bytes: Int64 = 0
            for (j, (fname, kind, text)) in files.enumerated() {
                let data = kind == .pdf ? DemoContent.pdf(title: fname, subtitle: "Черновик") : Data(text.utf8)
                let fid = newID()
                let f = VaultFile(id: fid, caseID: cid, name: fname, kind: kind, bytes: Int64(data.count),
                                  note: nil, favorite: false, offline: false,
                                  createdAt: created.addingTimeInterval(Double(j * 3_600)), deletedAt: nil, ocr: nil)
                items[fid] = Item(file: f, data: data)
                bytes += Int64(data.count)
            }
            cases.append(VaultCase(id: cid, name: name, icon: icon, level: level, favorite: false, fileCount: files.count,
                                   bytes: bytes, isUnlocked: true, updatedAt: now.addingTimeInterval(-Double(86_400 * (2 + i * 4))),
                                   isRecoverable: true))
            unlockedIDs.insert(cid)
        }
    }

    // MARK: Кейсы
    private func refreshed(_ c: VaultCase) -> VaultCase {
        var c = c
        let fs = items.values.filter { $0.file.caseID == c.id && $0.file.deletedAt == nil }
        c.fileCount = fs.count
        c.bytes = fs.reduce(0) { $0 + $1.file.bytes }
        c.isUnlocked = unlockedIDs.contains(c.id)
        return c
    }
    private func index(_ id: String) throws -> Int {
        guard let i = cases.firstIndex(where: { $0.id == id }) else { throw VaultError.server("Кейс не найден") }
        return i
    }
    private func requireOpen(_ id: String) throws {
        _ = try index(id)
        guard unlockedIDs.contains(id) else { throw VaultError.notUnlocked }
    }

    func listCases() -> [VaultCase] { cases.map(refreshed) }

    func createCase(name: String, icon: CaseIcon, level: SecurityLevel) throws -> NewCaseResult {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw VaultError.validation("Введите название кейса") }
        let secret = KeyFormat.generateSecret()
        let id = newID()
        let c = VaultCase(id: id, name: t, icon: icon, level: level, favorite: false, fileCount: 0, bytes: 0,
                          isUnlocked: true, updatedAt: Date(), isRecoverable: true)
        cases.insert(c, at: 0); unlockedIDs.insert(id)
        return NewCaseResult(vaultCase: c, keyString: KeyFormat.format(secret), keyFileName: KeyFormat.keyFileName(for: t),
                             keyFileData: KeyFormat.keyFileData(caseID: id, secret: secret), recoveryWords: RecoveryWords.generate())
    }

    func updateCase(id: String, name: String?, icon: CaseIcon?, level: SecurityLevel?, favorite: Bool?) throws -> VaultCase {
        let i = try index(id)
        if let name {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw VaultError.validation("Введите название кейса") }
            cases[i].name = t
        }
        if let icon { cases[i].icon = icon }
        if let level { cases[i].level = level }
        if let favorite { cases[i].favorite = favorite }
        cases[i].updatedAt = Date()
        return refreshed(cases[i])
    }

    /// Любой верный по формату способ открывает приманку: так «неудачная» попытка не выдаёт подмену.
    func unlock(id: String) throws { _ = try index(id); unlockedIDs.insert(id) }
    func lock(id: String) { unlockedIDs.remove(id) }
    func lockAll() { unlockedIDs.removeAll() }

    func exportKey(caseID: String) throws -> ExportedKey {
        try requireOpen(caseID)
        let secret = KeyFormat.generateSecret()
        let name = cases[try index(caseID)].name
        return ExportedKey(keyString: KeyFormat.format(secret), fileName: KeyFormat.keyFileName(for: name),
                           fileData: KeyFormat.keyFileData(caseID: caseID, secret: secret))
    }

    func purge(id: String) throws {
        let i = try index(id)
        cases.remove(at: i); unlockedIDs.remove(id)
        items = items.filter { $0.value.file.caseID != id }
    }

    // MARK: Файлы
    func listFiles(caseID: String) throws -> [VaultFile] {
        try requireOpen(caseID)
        return items.values.map(\.file).filter { $0.caseID == caseID && $0.deletedAt == nil }.sorted { $0.createdAt > $1.createdAt }
    }
    func openCasesWithFiles() -> [(VaultCase, [VaultFile])] {
        cases.filter { unlockedIDs.contains($0.id) }.map { c in
            (refreshed(c), items.values.map(\.file).filter { $0.caseID == c.id && $0.deletedAt == nil })
        }
    }
    func favoriteFiles() -> [VaultFile] {
        items.values.map(\.file).filter { $0.favorite && $0.deletedAt == nil && unlockedIDs.contains($0.caseID) }
    }
    func addFile(caseID: String, name: String, kind: FileKind, data: Data, note: String?, ocrText: String?) throws -> VaultFile {
        try requireOpen(caseID)
        let f = VaultFile(id: newID(), caseID: caseID, name: name, kind: kind, bytes: Int64(data.count), note: note,
                          favorite: false, offline: false, createdAt: Date(), deletedAt: nil, ocr: ocrText)
        items[f.id] = Item(file: f, data: data)
        return f
    }
    private func item(_ id: String) throws -> Item {
        guard let it = items[id] else { throw VaultError.server("Не найдено") }
        return it
    }
    func openFile(id: String) throws -> Data {
        let it = try item(id)
        try requireOpen(it.file.caseID)
        return it.data
    }
    func updateFile(id: String, name: String?, note: String?, favorite: Bool?, offline: Bool?) throws -> VaultFile {
        var it = try item(id)
        try requireOpen(it.file.caseID)
        if let name { it.file.name = name }
        if let note { it.file.note = note.isEmpty ? nil : note }
        if let favorite { it.file.favorite = favorite }
        if let offline { it.file.offline = offline }
        items[id] = it
        return it.file
    }
    func moveFiles(ids: [String], toCaseID: String) throws {
        try requireOpen(toCaseID)
        for id in ids {
            var it = try item(id)
            try requireOpen(it.file.caseID)
            it.file.caseID = toCaseID
            items[id] = it
        }
    }
    func trashFiles(ids: [String]) throws {
        for id in ids { if var it = items[id] { it.file.deletedAt = Date(); items[id] = it } }
    }
    func listTrash() -> [VaultFile] { items.values.map(\.file).filter { $0.deletedAt != nil } }
    func restoreFile(id: String) throws {
        var it = try item(id); it.file.deletedAt = nil; items[id] = it
    }
    func purgeFile(id: String) throws { items[id] = nil }

    // MARK: Версии (в приманке — одна версия плюс заменённые в этой сессии)
    func listVersions(fileID: String) throws -> [FileVersion] {
        let it = try item(fileID)
        try requireOpen(it.file.caseID)
        let cur = FileVersion(id: "current", name: it.file.name, kind: it.file.kind, bytes: it.file.bytes, createdAt: it.file.createdAt, isCurrent: true)
        return [cur] + it.previous.map(\.0)
    }
    func replaceFileContent(fileID: String, data: Data) throws -> VaultFile {
        var it = try item(fileID)
        try requireOpen(it.file.caseID)
        let old = FileVersion(id: newID(), name: it.file.name, kind: it.file.kind, bytes: it.file.bytes, createdAt: it.file.createdAt, isCurrent: false)
        it.previous.insert((old, it.data), at: 0)
        it.data = data; it.file.bytes = Int64(data.count); it.file.createdAt = Date()
        items[fileID] = it
        return it.file
    }
    func openVersion(fileID: String, versionID: String) throws -> Data {
        let it = try item(fileID)
        try requireOpen(it.file.caseID)
        if versionID == "current" { return it.data }
        guard let v = it.previous.first(where: { $0.0.id == versionID }) else { throw VaultError.server("Версия не найдена") }
        return v.1
    }
    func restoreVersion(fileID: String, versionID: String) throws -> VaultFile {
        var it = try item(fileID)
        try requireOpen(it.file.caseID)
        guard let v = it.previous.first(where: { $0.0.id == versionID }) else { return it.file }
        it.data = v.1; it.file.bytes = Int64(v.1.count)
        items[fileID] = it
        return it.file
    }

    // MARK: Сводки
    func storageUsage() -> StorageUsage {
        let per = cases.map { c in CaseStorage(caseID: c.id, name: c.name, level: c.level, bytes: refreshed(c).bytes) }
        return StorageUsage(usedBytes: per.reduce(0) { $0 + $1.bytes }, limitBytes: AppConfig.storageLimitBytes, perCase: per)
    }
    func auditLog(limit: Int) -> [AuditEvent] {
        let ev = cases.flatMap { c in
            [AuditEvent(id: newID(), kind: .caseUnlocked, caseName: c.name, deviceName: "Этот iPhone", at: c.updatedAt),
             AuditEvent(id: newID(), kind: .caseCreated, caseName: c.name, deviceName: "Этот iPhone", at: c.updatedAt.addingTimeInterval(-86_400 * 3))]
        }
        return Array(ev.sorted { $0.at > $1.at }.prefix(max(0, limit)))
    }
}
