import Foundation
import CryptoKit

/// Открытое содержимое конверта (до шифрования / после расшифровки).
struct ChatPayload: Codable {
    var v: Int = 1
    var t: String
    /// Время жизни сообщения, сек. (исчезающие сообщения)
    var ttl: Double?
    var an: String?
    var ad: Data?
    /// Тип: nil — обычное сообщение/стикер; "edit", "del", "react", "theme", "ttl" (смена таймера чата, `ttl` = 0 — выкл.) — служебные (тоже внутри шифртекста).
    var k: String?
    /// id сообщения, к которому относится служебное действие
    var r: String?
    /// ответ на сообщение: id и короткая цитата
    var rp: String?
    var rt: String?
    var e: String?
    /// id стикера
    var s: String?
    /// id темы
    var th: String?
    /// «Не пересылать» (аддитивное поле, старые клиенты его игнорируют). Вежливая клиентская пометка: приёмник скрывает
    /// «Переслать»/«Сохранить в галерею» и показывает замок. Модифицированный клиент или скриншот это обходят.
    var nf: Bool?
}

enum ChatInviteCodec {
    static func encode(id: String, username: String, key: Data) -> String {
        var c = URLComponents(); c.scheme = "lokey"; c.host = "add"
        c.queryItems = [.init(name: "id", value: id), .init(name: "u", value: username), .init(name: "k", value: b64url(key))]
        return c.string ?? ""
    }
    static func decode(_ s: String) -> (id: String, username: String, key: Data)? {
        guard let c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme == "lokey", c.host == "add",
              let id = c.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty,
              let u = c.queryItems?.first(where: { $0.name == "u" })?.value,
              let k = c.queryItems?.first(where: { $0.name == "k" })?.value, let key = fromB64url(k), key.count == 32 else { return nil }
        return (id, u, key)
    }
    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func fromB64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}


/// QR сверки кода безопасности: `lokey://verify?a=<id автора QR>&b=<id собеседника>&h=<хэш кода безопасности>`.
/// Хэш — SHA-256 от цифр кода безопасности (он одинаков у обоих), поэтому сами цифры в QR не раскрываются.
enum ChatVerifyCodec {
    struct Parsed: Equatable, Sendable { var a: String; var b: String; var h: String }
    enum Result: Equatable, Sendable { case match, mismatch, wrongContact }

    static func hash(safetyNumber: String) -> String {
        let digits = safetyNumber.filter(\.isNumber)
        return ChatInviteCodec.b64url(Data(SHA256.hash(data: Data(("lokey.verify.v1|" + digits).utf8))))
    }

    static func encode(myID: String, theirID: String, safetyNumber: String) -> String {
        var c = URLComponents(); c.scheme = "lokey"; c.host = "verify"
        c.queryItems = [.init(name: "a", value: myID), .init(name: "b", value: theirID), .init(name: "h", value: hash(safetyNumber: safetyNumber))]
        return c.string ?? ""
    }

    static func decode(_ s: String) -> Parsed? {
        guard let c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme == "lokey", c.host == "verify",
              let a = c.queryItems?.first(where: { $0.name == "a" })?.value, !a.isEmpty,
              let b = c.queryItems?.first(where: { $0.name == "b" })?.value, !b.isEmpty,
              let h = c.queryItems?.first(where: { $0.name == "h" })?.value, !h.isEmpty else { return nil }
        return Parsed(a: a, b: b, h: h)
    }

    /// Сканируем QR собеседника: у него `a` = его id, `b` = мой id.
    static func compare(_ scanned: Parsed, myID: String, theirID: String, safetyNumber: String) -> Result {
        guard scanned.a == theirID, scanned.b == myID else { return .wrongContact }
        return scanned.h == hash(safetyNumber: safetyNumber) ? .match : .mismatch
    }
}
