import Foundation

/// Чистые правила безопасности, которые нужны и UI, и ядру (UI не должен знать про Core).
enum SecurityRules {
    /// Длина PIN «под принуждением».
    static let duressPINLength = 6

    static func isDuressPINFormatValid(_ pin: String) -> Bool {
        pin.count == duressPINLength && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Оценка надёжности фразы 0…4 (для индикатора). Не гарантия стойкости.
    static func passphraseStrength(_ s: String) -> Int {
        var score = 0
        if s.count >= 10 { score += 1 }
        if s.count >= 14 { score += 1 }
        let classes = [s.contains { $0.isLowercase }, s.contains { $0.isUppercase }, s.contains { $0.isNumber }, s.contains { !$0.isLetter && !$0.isNumber }].filter { $0 }.count
        if classes >= 3 { score += 1 }
        if s.count >= 18 || (s.count >= 14 && classes >= 3) { score += 1 }
        if Set(s).count < max(4, s.count / 3) { score = min(score, 1) }
        return min(score, 4)
    }
}
