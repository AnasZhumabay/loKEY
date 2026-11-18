// Напоминания о сроках документов. Целиком на устройстве: даты ищутся в расшифрованных
// метаданных ОТКРЫТЫХ кейсов, напоминания лежат в зашифрованном файле, уведомления — локальные.
import Foundation

enum ReminderKind: String, Codable, CaseIterable, Sendable {
    case passport, id, license, insurance, card, other

    var title: String {
        switch self {
        case .passport: return "Паспорт"
        case .id: return "Удостоверение личности"
        case .license: return "Водительские права"
        case .insurance: return "Страховка"
        case .card: return "Банковская карта"
        case .other: return "Другой документ"
        }
    }
    var icon: String {
        switch self {
        case .passport: return "book.closed.fill"
        case .id: return "person.text.rectangle.fill"
        case .license: return "car.fill"
        case .insurance: return "cross.case.fill"
        case .card: return "creditcard.fill"
        case .other: return "doc.text.fill"
        }
    }

    /// Грубая классификация по имени файла и тексту.
    static func classify(_ text: String) -> ReminderKind {
        let t = text.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if has(["паспорт", "passport"]) { return .passport }
        if has(["водительск", "права", "driver", "licence", "license"]) { return .license }
        if has(["удостоверение", "id card", "id-card", "identity"]) { return .id }
        if has(["страхов", "полис", "insurance", "policy"]) { return .insurance }
        if has(["карта", "карты", "card"]) { return .card }
        return .other
    }
}

enum ReminderSource: String, Codable, Sendable { case auto, manual }

struct DocumentReminder: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var fileId: String?
    var caseId: String?
    var caseName: String
    var fileName: String
    var kind: ReminderKind
    var expiresOn: Date
    var source: ReminderSource
    var notifyDaysBefore: [Int]
    var enabled: Bool

    static let defaultNotifyDays = [30, 7, 1]

    init(id: String = UUID().uuidString, fileId: String? = nil, caseId: String? = nil, caseName: String = "",
         fileName: String, kind: ReminderKind = .other, expiresOn: Date, source: ReminderSource = .manual,
         notifyDaysBefore: [Int] = DocumentReminder.defaultNotifyDays, enabled: Bool = true) {
        self.id = id; self.fileId = fileId; self.caseId = caseId; self.caseName = caseName; self.fileName = fileName
        self.kind = kind; self.expiresOn = expiresOn; self.source = source
        self.notifyDaysBefore = notifyDaysBefore; self.enabled = enabled
    }

    /// Дней до срока (отрицательное — просрочен).
    func daysLeft(now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expiresOn)).day ?? 0
    }
}

enum ReminderAuthState: Sendable { case notDetermined, granted, denied }

protocol ReminderService: Sendable {
    /// Ищет даты окончания в открытых кейсах (имя файла, заметка, OCR). Возвращает найденные напоминания и сохраняет их.
    func scan() async -> [DocumentReminder]
    func list() async -> [DocumentReminder]
    func add(_ reminder: DocumentReminder) async
    func update(_ reminder: DocumentReminder) async
    func remove(id: String) async
    /// Пересоздаёт локальные уведомления (идентификаторы детерминированы, старые заменяются).
    func schedule() async
    func requestAuthorization() async -> Bool
    func authorizationState() async -> ReminderAuthState
    /// Стереть все напоминания и их уведомления (выход из аккаунта).
    func clearAll() async
    /// Режим приманки (под принуждением): напоминания не читаются, не сканируются и не планируются; уведомления снимаются.
    func setSuspended(_ suspended: Bool) async
}

extension ReminderService {
    func clearAll() async {}
    func setSuspended(_ suspended: Bool) async {}
}
