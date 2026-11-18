// Чистый разбор дат окончания срока в тексте (имя файла, заметка, OCR). Без побочных эффектов.
import Foundation

enum ExpiryDateParser {
    struct Found: Equatable { var date: Date; var hasKeyword: Bool }

    static let expiryKeywords = [
        "действителен до", "действительна до", "действителен по", "действительно до", "срок действия", "годен до", "годна до",
        "дата окончания", "окончание срока", "истекает", "valid until", "valid thru", "valid through", "valid to",
        "date of expiry", "expiry", "expires", "expiration", "exp.", "exp date"
    ]
    /// Даты рядом с этими словами — не срок (выдача, рождение).
    static let negativeKeywords = ["выдан", "дата выдачи", "рожден", "date of issue", "issued", "birth", "дата рождения"]

    static func gregorian(_ tz: TimeZone = .current) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c
    }

    /// Дата допустима, если в [сегодня − 1 год; сегодня + 30 лет].
    static func isSane(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard let lo = calendar.date(byAdding: .year, value: -1, to: now),
              let hi = calendar.date(byAdding: .year, value: 30, to: now) else { return false }
        let d = calendar.startOfDay(for: date)
        return d >= calendar.startOfDay(for: lo) && d <= calendar.startOfDay(for: hi)
    }

    private static let ymd = try? NSRegularExpression(pattern: #"(?<!\d)(\d{4})-(\d{1,2})-(\d{1,2})(?!\d)"#)
    private static let dmy = try? NSRegularExpression(pattern: #"(?<![\d.])(\d{1,2})[./\-](\d{1,2})[./\-](\d{4}|\d{2})(?!\d)"#)

    private static func makeDate(_ y: Int, _ m: Int, _ d: Int, _ cal: Calendar) -> Date? {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 0
        guard let date = cal.date(from: c) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        return (back.year == y && back.month == m && back.day == d) ? date : nil
    }

    /// Все даты в тексте (без проверки диапазона) с позициями.
    static func allDates(in text: String, calendar: Calendar) -> [(date: Date, range: Range<String.Index>)] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [(Date, Range<String.Index>)] = []
        var taken: [NSRange] = []
        func num(_ m: NSTextCheckingResult, _ i: Int) -> Int? { Int(ns.substring(with: m.range(at: i))) }
        for m in ymd?.matches(in: text, range: full) ?? [] {
            guard let y = num(m, 1), let mo = num(m, 2), let d = num(m, 3), let date = makeDate(y, mo, d, calendar),
                  let r = Range(m.range, in: text) else { continue }
            out.append((date, r)); taken.append(m.range)
        }
        for m in dmy?.matches(in: text, range: full) ?? [] {
            if taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
            guard let d = num(m, 1), let mo = num(m, 2), var y = num(m, 3), let r = Range(m.range, in: text) else { continue }
            if ns.substring(with: m.range(at: 3)).count == 2 { y += 2000 }
            if let date = makeDate(y, mo, d, calendar) { out.append((date, r)) }
        }
        return out.sorted { $0.1.lowerBound < $1.1.lowerBound }
    }

    private static func lastIndex(of words: [String], in s: String) -> Int? {
        words.compactMap { w in s.range(of: w, options: .backwards).map { s.distance(from: s.startIndex, to: $0.lowerBound) } }.max()
    }

    /// Даты в допустимом диапазоне; `hasKeyword` — перед датой (≤ 45 символов) стоит слово про срок действия.
    static func candidates(in text: String, now: Date, calendar: Calendar = gregorian()) -> [Found] {
        let lower = text.lowercased()
        var res: [Found] = []
        for (date, range) in allDates(in: lower, calendar: calendar) where isSane(date, now: now, calendar: calendar) {
            let start = lower.index(range.lowerBound, offsetBy: -45, limitedBy: lower.startIndex) ?? lower.startIndex
            let window = String(lower[start..<range.lowerBound])
            let pos = lastIndex(of: expiryKeywords, in: window)
            let neg = lastIndex(of: negativeKeywords, in: window)
            let ok = pos.map { p in neg.map { p > $0 } ?? true } ?? false
            res.append(Found(date: date, hasKeyword: ok))
        }
        return res
    }

    /// Лучший кандидат: дата со словом про срок (самая поздняя, если их несколько: «с … по …»). Без слова — nil.
    static func expiry(in text: String, now: Date, calendar: Calendar = gregorian()) -> Date? {
        candidates(in: text, now: now, calendar: calendar).filter(\.hasKeyword).map(\.date).max()
    }
}
