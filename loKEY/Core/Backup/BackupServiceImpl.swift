// Реализация BackupService. Формат архива — см. BackupArchive.swift и Docs/_backup_format.md.
// Секреты (фраза, ключи, содержимое) в логи не пишутся; расшифрованные данные живут только в памяти.
import Foundation

final class BackupServiceImpl: BackupService, @unchecked Sendable {
    static let fileExtension = "lokeybackup"

    private let repo: VaultRepository
    private let backupAPI: BackupAPI
    private let events: SecurityEventAPI
    private let cloud: CloudBackupStore
    private let local: CloudBackupStore
    private let rounds: Int
    private let appVersion: String
    private let deviceName: String
    private let defaults: UserDefaults

    private let lastKey = "lokey.backup.last"
    private let autoKey = "lokey.backup.auto"

    init(repo: VaultRepository, backupAPI: BackupAPI, events: SecurityEventAPI, cloud: CloudBackupStore,
         local: CloudBackupStore = LocalFolderBackupStore(),
         kdfRounds: Int = BackupArchive.minimumRounds,
         appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
         deviceName: String = "iPhone",
         defaults: UserDefaults = .standard) {
        self.repo = repo; self.backupAPI = backupAPI; self.events = events; self.cloud = cloud
        self.local = local; self.rounds = kdfRounds; self.appVersion = appVersion
        self.deviceName = deviceName; self.defaults = defaults
    }

    var lastBackupDate: Date? { get async { await repo.isDecoy ? nil : defaults.object(forKey: lastKey) as? Date } }
    var autoBackupEnabled: Bool { get async { defaults.bool(forKey: autoKey) } }
    func setAutoBackup(_ enabled: Bool) async { if await repo.isDecoy { return }; defaults.set(enabled, forKey: autoKey) }

    // MARK: Создание

    func createBackup(destination: BackupDestination, passphrase: String,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> BackupSummary {
        if await repo.isDecoy { throw BackupError.unavailable }
        guard passphrase.count >= 10 else { throw BackupError.weakPassphrase }
        if destination == .iCloud, !cloud.isAvailable { throw BackupError.iCloudUnavailable }
        let tracker = ProgressTracker(progress)
        tracker.report(0.02)

        let cases = try await repo.listCases()
        let open = cases.filter(\.isUnlocked)
        let skipped = cases.filter { !$0.isUnlocked }.map(\.name)
        guard !open.isEmpty else { throw BackupError.nothingToBackUp }

        var fileList: [VaultFile] = []
        for c in open {
            try Task.checkCancellation()
            fileList += try await repo.listFiles(caseID: c.id).filter { $0.deletedAt == nil }
        }
        let rounds = self.rounds
        var writer = try await Task.detached { try BackupArchive.Writer(passphrase: passphrase, rounds: rounds) }.value
        tracker.report(0.10)

        var entries: [BackupManifest.FileEntry] = []
        var blobs: [Data] = []
        for (i, f) in fileList.enumerated() {
            try Task.checkCancellation()
            let plain = try await repo.openFile(id: f.id)
            entries.append(.init(id: f.id, caseId: f.caseID, name: f.name, kind: f.kind.rawValue, note: f.note,
                                 ocr: f.ocr, favorite: f.favorite, plainBytes: Int64(plain.count),
                                 sha256: BackupArchive.sha256Hex(plain)))
            blobs.append(plain)
            tracker.report(0.10 + 0.60 * Double(i + 1) / Double(max(fileList.count, 1)))
        }
        let created = Date()
        let manifest = BackupManifest(
            formatVersion: BackupArchive.currentVersion, createdAt: created, appVersion: appVersion, device: deviceName,
            cases: open.map { .init(id: $0.id, name: $0.name, icon: $0.icon.rawValue, level: $0.level.rawValue, favorite: $0.favorite) },
            files: entries, skippedLockedCases: skipped)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let manifestData = try? enc.encode(manifest) else { throw BackupError.io("manifest") }
        try writer.append(manifestData)
        for (i, b) in blobs.enumerated() {
            try Task.checkCancellation()
            try writer.append(b)
            tracker.report(0.70 + 0.15 * Double(i + 1) / Double(max(blobs.count, 1)))
        }
        let archive = writer.data
        let sha = BackupArchive.sha256Hex(archive)
        let stamp = Self.fileStamp(created)
        let name = "loKEY-\(stamp).\(Self.fileExtension)"
        var summary = BackupSummary(id: "", destination: destination, createdAt: created, sizeBytes: Int64(archive.count),
                                    deviceName: deviceName, appVersion: appVersion, formatVersion: BackupArchive.currentVersion,
                                    remoteName: name, sha256: sha)
        try Task.checkCancellation()
        switch destination {
        case .iCloud:
            do { try await cloud.write(name: name, data: archive) } catch { throw Self.map(error) }
            summary.id = "icloud:\(name)"
        case .localFile:
            do { try await local.write(name: name, data: archive) } catch { throw Self.map(error) }
            summary.id = "local:\(name)"
            if let store = local as? LocalFolderBackupStore { summary.fileURL = store.directory.appendingPathComponent(name) }
        case .server:
            let info = BackupInfoDTO(id: UUID().uuidString, createdAt: created, sizeBytes: Int64(archive.count), sha256: sha,
                                     deviceName: deviceName, appVersion: appVersion, formatVersion: BackupArchive.currentVersion)
            do {
                try await backupAPI.upload(info: info, data: archive, sha256: sha) { p in tracker.report(0.85 + 0.15 * p) }
            } catch { throw BackupError.serverUnavailable }
            summary.id = "server:\(info.id)"; summary.remoteName = info.id
        }
        tracker.report(1)
        defaults.set(created, forKey: lastKey)
        try? await events.report(SecurityEventDTO(kind: .backupCreated, caseId: nil, at: created, deviceName: nil))
        return summary
    }

    // MARK: Список / удаление

    func listBackups() async -> [BackupSummary] {
        if await repo.isDecoy { return [] }
        var out: [BackupSummary] = []
        if cloud.isAvailable, let files = try? await cloud.list() {
            out += files.filter { $0.name.hasSuffix(".\(Self.fileExtension)") }.map { Self.summary($0, .iCloud, device: deviceName, app: appVersion) }
        }
        if let files = try? await local.list() {
            out += files.filter { $0.name.hasSuffix(".\(Self.fileExtension)") }.map { Self.summary($0, .localFile, device: deviceName, app: appVersion) }
        }
        if let infos = try? await backupAPI.listBackups() {
            out += infos.map {
                BackupSummary(id: "server:\($0.id)", destination: .server, createdAt: $0.createdAt, sizeBytes: $0.sizeBytes,
                              deviceName: $0.deviceName, appVersion: $0.appVersion, formatVersion: $0.formatVersion,
                              remoteName: $0.id, sha256: $0.sha256)
            }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ summary: BackupSummary) async throws {
        if await repo.isDecoy { throw BackupError.unavailable }
        do {
            switch summary.destination {
            case .iCloud: try await cloud.delete(name: summary.remoteName)
            case .localFile: try await local.delete(name: summary.remoteName)
            case .server: try await backupAPI.delete(id: summary.remoteName)
            }
        } catch { throw Self.map(error) }
    }

    // MARK: Восстановление

    func restore(_ summary: BackupSummary, passphrase: String,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> RestoreReport {
        if await repo.isDecoy { throw BackupError.unavailable }
        let data: Data
        do {
            switch summary.destination {
            case .iCloud:
                guard cloud.isAvailable else { throw BackupError.iCloudUnavailable }
                data = try await cloud.read(name: summary.remoteName)
            case .localFile: data = try await local.read(name: summary.remoteName)
            case .server:
                data = try await backupAPI.download(id: summary.remoteName)
                if let expected = summary.sha256, BackupArchive.sha256Hex(data) != expected { throw BackupError.wrongPassphraseOrCorrupted }
            }
        } catch let e as BackupError { throw e } catch { throw Self.map(error) }
        return try await restore(archive: data, passphrase: passphrase, progress: progress)
    }

    func restore(archive: Data, passphrase: String,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> RestoreReport {
        if await repo.isDecoy { throw BackupError.unavailable }
        let tracker = ProgressTracker(progress)
        tracker.report(0.02)
        var reader = try await Task.detached { try BackupArchive.Reader(data: archive, passphrase: passphrase) }.value
        tracker.report(0.15)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let manifest = try? dec.decode(BackupManifest.self, from: try reader.next()) else { throw BackupError.wrongPassphraseOrCorrupted }
        guard manifest.formatVersion <= BackupArchive.currentVersion else { throw BackupError.unsupportedVersion(manifest.formatVersion) }

        var report = RestoreReport(restoredCases: 0, restoredFiles: 0, skippedLockedCases: manifest.skippedLockedCases,
                                   skippedFiles: [], warnings: [], newCaseIDs: [])
        var map: [String: String] = [:]
        for c in manifest.cases {
            try Task.checkCancellation()
            let icon = CaseIcon(rawValue: c.icon) ?? .document
            let level = SecurityLevel(rawValue: c.level) ?? .standard
            do {
                let r = try await repo.createCase(name: c.name + tr(" (из копии)"), icon: icon, level: level)
                map[c.id] = r.vaultCase.id
                report.newCaseIDs.append(r.vaultCase.id)
                report.restoredCases += 1
            } catch { report.warnings.append(tr("Кейс не создан: ") + c.name) }
        }
        let total = max(manifest.files.count, 1)
        for (i, f) in manifest.files.enumerated() {
            try Task.checkCancellation()
            let plain = try reader.next()   // ошибка GCM = подмена/повреждение → прерываем
            defer { tracker.report(0.15 + 0.85 * Double(i + 1) / Double(total)) }
            guard let newCase = map[f.caseId] else { report.skippedFiles.append(f.name); continue }
            guard BackupArchive.sha256Hex(plain) == f.sha256 else {
                report.skippedFiles.append(f.name); report.warnings.append(tr("Контрольная сумма не сошлась: ") + f.name); continue
            }
            do {
                _ = try await repo.addFile(caseID: newCase, name: f.name, kind: FileKind(rawValue: f.kind) ?? .other,
                                           data: plain, note: f.note, ocrText: f.ocr, progress: { _ in })
                report.restoredFiles += 1
            } catch { report.skippedFiles.append(f.name) }
        }
        if reader.hasMore { report.warnings.append(tr("В конце архива есть лишние данные")) }
        if !manifest.skippedLockedCases.isEmpty { report.warnings.append(tr("Закрытые кейсы не вошли в копию")) }
        report.warnings.append(tr("Новые кейсы получили новые ключи: сохраните их заново"))
        tracker.report(1)
        try? await events.report(SecurityEventDTO(kind: .backupRestored, caseId: nil, at: Date(), deviceName: nil))
        return report
    }

    // MARK: Помощники

    private static func fileStamp(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d) + "-" + UUID().uuidString.prefix(4).lowercased()
    }
    private static func summary(_ f: CloudBackupFile, _ d: BackupDestination, device: String, app: String) -> BackupSummary {
        BackupSummary(id: "\(d == .iCloud ? "icloud" : "local"):\(f.name)", destination: d, createdAt: f.modifiedAt,
                      sizeBytes: f.sizeBytes, deviceName: device, appVersion: app,
                      formatVersion: BackupArchive.currentVersion, remoteName: f.name, sha256: nil)
    }
    private static func map(_ e: Error) -> BackupError {
        if let b = e as? BackupError { return b }
        if e is CancellationError { return .cancelled }
        if let c = e as? CloudBackupError {
            switch c {
            case .unavailable: return .iCloudUnavailable
            case .notFound: return .notABackup
            case .invalidName: return .io(tr("Недопустимое имя файла"))
            case .io(let s): return .io(s)
            }
        }
        return .io(tr("Не удалось выполнить операцию"))
    }
}

/// Монотонный прогресс 0…1 (не откатывается назад, не выходит за границы).
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0
    private let sink: @Sendable (Double) -> Void
    init(_ sink: @escaping @Sendable (Double) -> Void) { self.sink = sink }
    func report(_ v: Double) {
        lock.lock()
        let nv = min(1, max(last, v))
        let changed = nv > last || last == 0
        last = nv
        lock.unlock()
        if changed { sink(nv) }
    }
}
