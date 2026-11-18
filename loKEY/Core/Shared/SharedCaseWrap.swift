// ═══════════════════════════════════════════════════════════════════════════
//  Обёрнутый ключ общего кейса (подробно: Docs/_shared_case_format.md)
//
//  blob = version(1 байт, 0x01) ‖ AES-256-GCM.combined( nonce(12) ‖ шифртекст ‖ тег(16) )
//  plaintext = секрет кейса (20 байт)
//  wrapKey   = HKDF-SHA256(ikm: X25519(моя личность, личность контакта), salt: SHA256(caseId),
//                          info: "lokey.sharedcase.wrap.v1", 32 байта)
//  AAD       = UTF-8("caseId|inviterId|inviteeId")
//
//  У каждого участника СВОЯ обёрнутая копия. Сервер хранит blob, но общего секрета X25519 у него нет,
//  поэтому секрет кейса он не получает. Подмена caseId/отправителя/получателя ломает тег GCM.
// ═══════════════════════════════════════════════════════════════════════════
import Foundation
import CryptoKit

enum SharedCaseWrap {
    static let version: UInt8 = 1
    static let info = Data("lokey.sharedcase.wrap.v1".utf8)

    static func aad(caseId: String, inviter: String, invitee: String) -> Data {
        Data("\(caseId)|\(inviter)|\(invitee)".utf8)
    }

    static func wrapKey(sharedSecret: Data, caseId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sharedSecret),
                               salt: Data(SHA256.hash(data: Data(caseId.utf8))),
                               info: info, outputByteCount: 32)
    }

    static func wrap(secret: Data, sharedSecret: Data, caseId: String, inviter: String, invitee: String) throws -> Data {
        guard secret.count == KeyFormat.secretLength, sharedSecret.count >= 32 else { throw SharedCaseError.inviteMalformed }
        let key = wrapKey(sharedSecret: sharedSecret, caseId: caseId)
        do {
            let box = try AES.GCM.seal(secret, using: key, authenticating: aad(caseId: caseId, inviter: inviter, invitee: invitee))
            guard let combined = box.combined else { throw SharedCaseError.inviteMalformed }
            return Data([version]) + combined
        } catch { throw SharedCaseError.inviteMalformed }
    }

    static func unwrap(_ blob: Data, sharedSecret: Data, caseId: String, inviter: String, invitee: String) throws -> Data {
        guard blob.count > 1 + CryptoService.sealOverhead, blob.first == version, sharedSecret.count >= 32 else {
            throw SharedCaseError.inviteMalformed
        }
        let key = wrapKey(sharedSecret: sharedSecret, caseId: caseId)
        do {
            let box = try AES.GCM.SealedBox(combined: blob.dropFirst())
            let plain = try AES.GCM.open(box, using: key, authenticating: aad(caseId: caseId, inviter: inviter, invitee: invitee))
            guard plain.count == KeyFormat.secretLength else { throw SharedCaseError.inviteMalformed }
            return plain
        } catch let e as SharedCaseError { throw e }
        catch { throw SharedCaseError.wrongKey }
    }
}

/// Только мок-режим: у демо-собеседницы нет доступного приватного ключа, поэтому «общий секрет» выводится из id.
/// НЕ защищает ничего. Используется, только если `chat.demoInvite() != nil`.
struct DemoKeyAgreement: ChatKeyAgreement {
    let myID: String
    func sharedSecret(withContact contactID: String) async throws -> Data {
        Self.secret(myID, contactID)
    }
    static func secret(_ a: String, _ b: String) -> Data {
        let ids = [a, b].sorted().joined(separator: "|")
        return Data(SHA256.hash(data: Data(("lokey.demo.dh.v1|" + ids).utf8)))
    }
}

/// Мок-режим: то же, что `DemoKeyAgreement`, но id аккаунта читается лениво (он известен только после входа).
struct LazyDemoKeyAgreement: ChatKeyAgreement {
    let myID: @Sendable () async -> String
    func sharedSecret(withContact contactID: String) async throws -> Data {
        DemoKeyAgreement.secret(await myID(), contactID)
    }
}
