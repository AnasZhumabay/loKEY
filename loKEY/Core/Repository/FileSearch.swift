// Поиск по расшифрованным метаданным ОТКРЫТЫХ кейсов: имя файла, заметка, распознанный текст (OCR).
// Работает только на устройстве; закрытые кейсы не трогает.
import Foundation

enum FileSearch {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    private static func match(_ text: String, _ q: String) -> Range<String.Index>? {
        text.range(of: q, options: options)
    }

    /// Фрагмент текста ±`radius` символов вокруг совпадения. Переводы строк схлопываются в пробелы.
    static func snippet(in text: String, query q: String, radius: Int = 40) -> String? {
        guard let r = match(text, q) else { return nil }
        let start = text.index(r.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let body = String(text[start..<end])
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }

    /// `sources` — открытые кейсы и их файлы (уже расшифрованные). Имя раньше заметки, заметка раньше OCR.
    static func hits(query: String, sources: [(VaultCase, [VaultFile])]) -> [FileSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var ranked: [(rank: Int, hit: FileSearchHit)] = []
        for (c, files) in sources {
            for f in files where f.deletedAt == nil {
                let inName = match(f.name, q) != nil
                let inNote = f.note.map { match($0, q) != nil } ?? false
                let inOCR = f.ocr.map { match($0, q) != nil } ?? false
                guard inName || inNote || inOCR else { continue }
                let text = (inNote ? f.note : nil) ?? (inOCR ? f.ocr : nil)
                let snip = text.flatMap { snippet(in: $0, query: q) }
                let rank = inName ? 0 : (inNote ? 1 : 2)
                ranked.append((rank, FileSearchHit(id: f.id, fileId: f.id, caseId: c.id, caseName: c.name, fileName: f.name,
                                                   snippet: snip, matchedInOCR: !inName && !inNote && inOCR, caseIsUnlocked: c.isUnlocked)))
            }
        }
        return ranked.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.hit.caseName != $1.hit.caseName { return $0.hit.caseName < $1.hit.caseName }
            return $0.hit.fileName < $1.hit.fileName
        }.map(\.hit)
    }
}
