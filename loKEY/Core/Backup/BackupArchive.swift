// ═══════════════════════════════════════════════════════════════════════════
//  Формат архива .lokeybackup, версия 1 (описание: Docs/_backup_format.md)
//
//  header (открытый, он же AAD всех записей):
//    magic   "LKBK"      4 байта
//    version UInt16 BE   = 1
//    kdf     UInt8       = 1 (PBKDF2-HMAC-SHA256)
//    rounds  UInt32 BE   (≥ 600 000 в приложении; в тестах меньше)
//    salt    16 байт
//  records: повторяются [UInt32 BE длина][AES-256-GCM combined (nonce+ct+tag)]
//    запись 0 — JSON-манифест; записи 1…N — содержимое файлов по порядку манифеста.
//  AAD записи = header ‖ UInt32 BE индекс записи (защита от перестановки/подмены).
//  Ключ = PBKDF2(passphrase, salt, rounds) → 32 байта. Пароль и ключ не хранятся.
//
//  Что внутри: хранилище не отдаёт сырой шифртекст, поэтому содержимое файлов,
//  расшифрованное в памяти ТОЛЬКО у открытых кейсов, перешифровывается ключом из фразы.
//  Ключи кейсов в архив не попадают. Закрытые кейсы пропускаются (перечислены по имени).
// ═══════════════════════════════════════════════════════════════════════════
import Foundation
import CryptoKit
import CommonCrypto

struct BackupManifest: Codable, Equatable, Sendable {
    struct CaseEntry: Codable, Equatable, Sendable {
        var id: String, name: String, icon: String, level: String, favorite: Bool
    }
    struct FileEntry: Codable, Equatable, Sendable {
        var id: String, caseId: String, name: String, kind: String
        var note: String?, ocr: String?, favorite: Bool, plainBytes: Int64, sha256: String
    }
    var formatVersion: Int
    var createdAt: Date
    var appVersion: String
    var device: String
    var cases: [CaseEntry]
    var files: [FileEntry]
    var skippedLockedCases: [String]
}

enum BackupArchive {
    static let magic = Data("LKBK".utf8)
    static let currentVersion = 1
    static let saltLength = 16
    static let headerLength = 4 + 2 + 1 + 4 + 16
    static let minimumRounds = 600_000
    static let maxRecord = 512 * 1024 * 1024

    struct Header: Equatable, Sendable {
        var version: Int, rounds: Int, salt: Data
        var bytes: Data {
            var d = BackupArchive.magic
            d.append(UInt8(version >> 8)); d.append(UInt8(version & 0xff))
            d.append(1)
            d.append(contentsOf: be32(UInt32(rounds)))
            d.append(salt)
            return d
        }
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

    static func parseHeader(_ data: Data) throws -> Header {
        guard data.count >= headerLength, data.prefix(4) == magic else { throw BackupError.notABackup }
        let b = [UInt8](data.prefix(headerLength))
        let version = Int(b[4]) << 8 | Int(b[5])
        guard version >= 1 else { throw BackupError.notABackup }
        guard version <= currentVersion else { throw BackupError.unsupportedVersion(version) }
        guard b[6] == 1 else { throw BackupError.notABackup }
        let rounds = Int(b[7]) << 24 | Int(b[8]) << 16 | Int(b[9]) << 8 | Int(b[10])
        guard rounds >= 1, rounds <= 10_000_000 else { throw BackupError.notABackup }
        return Header(version: version, rounds: rounds, salt: Data(b[11..<27]))
    }

    static func deriveKey(passphrase: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pass = passphrase.precomposedStringWithCanonicalMapping
        let saltBytes = [UInt8](salt)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass, pass.utf8.count,
                                          saltBytes, saltBytes.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, 32)
        guard status == kCCSuccess else { throw BackupError.io("kdf") }
        defer { for i in out.indices { out[i] = 0 } }
        return SymmetricKey(data: out)
    }

    static func aad(_ header: Data, index: Int) -> Data {
        var d = header
        d.append(contentsOf: be32(UInt32(index)))
        return d
    }

    /// Накопитель архива: добавляет записи по одной.
    struct Writer {
        let header: Header
        let key: SymmetricKey
        private(set) var data: Data
        private(set) var count = 0
        init(passphrase: String, rounds: Int) throws {
            let salt = Data((0..<BackupArchive.saltLength).map { _ in UInt8.random(in: 0...255) })
            header = Header(version: BackupArchive.currentVersion, rounds: rounds, salt: salt)
            key = try BackupArchive.deriveKey(passphrase: passphrase, salt: salt, rounds: rounds)
            data = header.bytes
        }
        mutating func append(_ plain: Data) throws {
            guard let box = try? AES.GCM.seal(plain, using: key, authenticating: BackupArchive.aad(header.bytes, index: count)),
                  let combined = box.combined else { throw BackupError.io("seal") }
            data.append(contentsOf: BackupArchive.be32(UInt32(combined.count)))
            data.append(combined)
            count += 1
        }
    }

    struct Reader {
        let header: Header
        let key: SymmetricKey
        private let data: Data
        private var offset: Int
        private(set) var index = 0
        init(data: Data, passphrase: String) throws {
            header = try BackupArchive.parseHeader(data)
            key = try BackupArchive.deriveKey(passphrase: passphrase, salt: header.salt, rounds: header.rounds)
            self.data = data
            offset = BackupArchive.headerLength
        }
        var hasMore: Bool { offset < data.count }
        mutating func next() throws -> Data {
            guard offset + 4 <= data.count else { throw BackupError.wrongPassphraseOrCorrupted }
            let b = [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + 4])
            let len = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            offset += 4
            guard len > 0, len <= BackupArchive.maxRecord, offset + len <= data.count else { throw BackupError.wrongPassphraseOrCorrupted }
            let chunk = data[data.startIndex + offset ..< data.startIndex + offset + len]
            offset += len
            guard let box = try? AES.GCM.SealedBox(combined: chunk),
                  let plain = try? AES.GCM.open(box, using: key, authenticating: BackupArchive.aad(header.bytes, index: index))
            else { throw BackupError.wrongPassphraseOrCorrupted }
            index += 1
            return plain
        }
    }

    static func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// Оценка надёжности фразы 0…4 (для индикатора). Не гарантия стойкости.
    static func strength(_ s: String) -> Int { SecurityRules.passphraseStrength(s) }
}
