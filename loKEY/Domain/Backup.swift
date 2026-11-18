// Опциональная зашифрованная резервная копия (фича 11). UI знает только этот протокол.
import Foundation

enum BackupDestination: String, CaseIterable, Codable, Sendable, Identifiable {
    case iCloud, server, localFile
    var id: String { rawValue }
}

struct BackupSummary: Identifiable, Equatable, Sendable {
    /// «icloud:имя», «server:id», «local:имя» — уникален между источниками.
    var id: String
    var destination: BackupDestination
    var createdAt: Date
    var sizeBytes: Int64
    var deviceName: String
    var appVersion: String
    var formatVersion: Int
    /// Имя файла (iCloud / локально) или id на сервере.
    var remoteName: String
    var sha256: String?
    /// Только для локального файла, созданного сейчас: URL для шторки «Поделиться».
    var fileURL: URL? = nil
}

struct RestoreReport: Equatable, Sendable {
    var restoredCases: Int
    var restoredFiles: Int
    /// Названия кейсов, которые были закрыты при создании копии и в ней отсутствуют.
    var skippedLockedCases: [String]
    /// Файлы, которые не удалось восстановить (имя).
    var skippedFiles: [String]
    var warnings: [String]
    /// Новые кейсы получили НОВЫЕ ключи: их нужно сохранить заново.
    var newCaseIDs: [String]
}

enum BackupError: Error, Equatable, Sendable {
    case weakPassphrase
    case iCloudUnavailable
    case serverUnavailable
    case wrongPassphraseOrCorrupted
    case unsupportedVersion(Int)
    case notABackup
    case nothingToBackUp
    case cancelled
    /// Режим приманки: резервные копии недоступны (ничего не читается и не пишется).
    case unavailable
    case io(String)

    var message: String {
        switch self {
        case .unavailable: return tr("Недоступно")
        case .weakPassphrase: return tr("Фраза слишком короткая: нужно не менее 10 символов")
        case .iCloudUnavailable: return tr("iCloud недоступен. Войдите в iCloud или выберите другое место")
        case .serverUnavailable: return tr("Сервер резервных копий недоступен")
        case .wrongPassphraseOrCorrupted: return tr("Неверная фраза или файл повреждён")
        case .unsupportedVersion(let v): return tr("Эта копия создана более новой версией (формат \(v))")
        case .notABackup: return tr("Это не файл резервной копии loKEY")
        case .nothingToBackUp: return tr("Нет открытых кейсов: откройте хотя бы один")
        case .cancelled: return tr("Отменено")
        case .io(let s): return s
        }
    }
}

protocol BackupService: Sendable {
    func createBackup(destination: BackupDestination, passphrase: String,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> BackupSummary
    /// Объединяет iCloud, сервер и локальную папку; недоступные источники пропускаются.
    func listBackups() async -> [BackupSummary]
    func restore(_ summary: BackupSummary, passphrase: String,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> RestoreReport
    /// Восстановление из файла, выбранного в «Файлах».
    func restore(archive: Data, passphrase: String,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> RestoreReport
    func delete(_ summary: BackupSummary) async throws
    var lastBackupDate: Date? { get async }
    var autoBackupEnabled: Bool { get async }
    func setAutoBackup(_ enabled: Bool) async
}
