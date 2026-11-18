import Foundation

/// Секрет кейса: 20 случайных байт, показывается как Crockford Base32 (32 символа) группами 4-4-4-4-4-4-4-4.
enum KeyFormat {
    static let secretLength = 20
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generateSecret() -> Data { CryptoService.randomBytes(secretLength) }

    static func format(_ secret: Data) -> String {
        var out = ""
        var buffer = 0, bits = 0
        for b in secret {
            buffer = (buffer << 8) | Int(b); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(buffer >> bits) & 31]) }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 4).map { i in
            String(out.dropFirst(i).prefix(4))
        }.joined(separator: "-")
    }

    /// Терпимый разбор: регистр, пробелы, дефисы; O→0, I/L→1.
    static func parse(_ string: String) throws -> Data {
        let cleaned = string.uppercased().filter { !$0.isWhitespace && $0 != "-" }
            .map { c -> Character in c == "O" ? "0" : (c == "I" || c == "L") ? "1" : c }
        guard cleaned.count == 32 else { throw VaultError.invalidKeyFormat }
        var bytes = [UInt8]()
        var buffer = 0, bits = 0
        for c in cleaned {
            guard let v = alphabet.firstIndex(of: c) else { throw VaultError.invalidKeyFormat }
            buffer = (buffer << 5) | v; bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((buffer >> bits) & 255)); buffer &= (1 << bits) - 1 }
        }
        guard bytes.count == secretLength else { throw VaultError.invalidKeyFormat }
        return Data(bytes)
    }

    // MARK: .key-файл
    private struct KeyFile: Codable { var v: Int; var `case`: String; var key: String }

    static func keyFileData(caseID: String, secret: Data) -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(KeyFile(v: 1, case: caseID, key: format(secret)))) ?? Data()
    }

    static func parseKeyFile(_ data: Data) throws -> (caseID: String, secret: Data) {
        guard let f = try? JSONDecoder().decode(KeyFile.self, from: data), f.v == 1 else { throw VaultError.invalidKeyFormat }
        return (f.case, try parse(f.key))
    }

    static func keyFileName(for caseName: String) -> String {
        let slug = caseName.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return "loKEY-\(slug.isEmpty ? "key" : slug).key"
    }
}
