// ═══════════════════════════════════════════════════════════════════════════
//  SEAM · CloudBackupStore — клиентский бэкап (iCloud Drive или локальная папка).
//  Бэкенд не нужен. Данные ожидаются уже зашифрованными (приложение кладёт шифртекст).
//  ICloudDriveBackupStore не падает без entitlement: isAvailable == false, методы бросают .unavailable.
// ═══════════════════════════════════════════════════════════════════════════
import Foundation

enum CloudBackupError: Error, Equatable, Sendable {
    case unavailable, notFound, invalidName, io(String)
}

struct CloudBackupFile: Equatable, Sendable {
    var name: String
    var sizeBytes: Int64
    var modifiedAt: Date
}

protocol CloudBackupStore: Sendable {
    var isAvailable: Bool { get }
    func write(name: String, data: Data) async throws
    func read(name: String) async throws -> Data
    func list() async throws -> [CloudBackupFile]
    func delete(name: String) async throws
}

/// Общая файловая логика для каталога (локального или iCloud).
private enum FolderOps {
    static func validate(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != "..", !name.hasPrefix(".") else { throw CloudBackupError.invalidName }
    }
    static func write(dir: URL, name: String, data: Data) throws {
        try validate(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(name), options: [.atomic])
        } catch { throw CloudBackupError.io(error.localizedDescription) }
    }
    static func read(dir: URL, name: String) throws -> Data {
        try validate(name)
        let u = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: u.path) else { throw CloudBackupError.notFound }
        do { return try Data(contentsOf: u) } catch { throw CloudBackupError.io(error.localizedDescription) }
    }
    static func list(dir: URL) throws -> [CloudBackupFile] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return CloudBackupFile(name: u.lastPathComponent, sizeBytes: Int64(v?.fileSize ?? 0), modifiedAt: v?.contentModificationDate ?? .distantPast)
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }
    static func delete(dir: URL, name: String) throws {
        try validate(name)
        let u = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: u.path) else { throw CloudBackupError.notFound }
        do { try FileManager.default.removeItem(at: u) } catch { throw CloudBackupError.io(error.localizedDescription) }
    }
}

/// Локальная папка (по умолчанию Documents/Backups) — работает всегда, годится для тестов.
struct LocalFolderBackupStore: CloudBackupStore {
    let directory: URL
    init(directory: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? docs.appendingPathComponent("Backups", isDirectory: true)
    }
    var isAvailable: Bool { true }
    func write(name: String, data: Data) async throws { try FolderOps.write(dir: directory, name: name, data: data) }
    func read(name: String) async throws -> Data { try FolderOps.read(dir: directory, name: name) }
    func list() async throws -> [CloudBackupFile] { try FolderOps.list(dir: directory) }
    func delete(name: String) async throws { try FolderOps.delete(dir: directory, name: name) }
}

/// iCloud Drive через ubiquity-контейнер. Без entitlement/входа в iCloud контейнер = nil → `.unavailable`.
struct ICloudDriveBackupStore: CloudBackupStore {
    let containerIdentifier: String?
    init(containerIdentifier: String? = nil) { self.containerIdentifier = containerIdentifier }

    /// Каталог Documents/Backups в контейнере или nil. Вызов может быть медленным — не из main.
    private func directory() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("Backups", isDirectory: true)
    }
    /// Быстрая проверка: вход в iCloud есть (не гарантирует наличие entitlement — это проверяют методы).
    var isAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    private func dirOrThrow() throws -> URL {
        guard isAvailable, let d = directory() else { throw CloudBackupError.unavailable }
        return d
    }
    func write(name: String, data: Data) async throws { try FolderOps.write(dir: try dirOrThrow(), name: name, data: data) }
    func read(name: String) async throws -> Data { try FolderOps.read(dir: try dirOrThrow(), name: name) }
    func list() async throws -> [CloudBackupFile] { try FolderOps.list(dir: try dirOrThrow()) }
    func delete(name: String) async throws { try FolderOps.delete(dir: try dirOrThrow(), name: name) }
}
