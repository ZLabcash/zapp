import CryptoKit
import Foundation

/// The encryption of the KindleWallet link (shared spec v1, §3): an X25519 handshake, keys
/// from HKDF-SHA256, then ChaCha20-Poly1305 records both ways. Pure values only, so the
/// fixed transcript in kindlewallet/tests/link_vectors.json can be checked against them.
enum KindleCrypto {
    static let label = Data("zfirm-kindle-v1".utf8)
    /// After the first connection (made with the QR code's PSK), the phone always uses this.
    static let zeroPSK = Data(repeating: 0, count: 16)
    static let maxPlaintext = 16 * 1024
    static let tagLength = 16

    /// Phone -> Kindle, 65 bytes: `0x01 || E_p || P`.
    static func clientHello(ephemeral: Data, phone: Data) -> Data {
        Data([0x01]) + ephemeral + phone
    }

    /// Kindle -> phone, 33 bytes: `0x02 || E_k`. Returns E_k.
    static func serverHello(_ data: Data) throws -> Data {
        let bytes = Data(data)
        guard bytes.count == 33, bytes.first == 0x02 else { throw KindleError.handshake }
        return Data(bytes.dropFirst())
    }

    /// The handshake's outcome, seen from the phone: `send` = k_pk, `receive` = k_kp.
    struct Derived {
        let transcript: Data
        let okm: Data
        var send: SymmetricKey { SymmetricKey(data: okm.prefix(32)) }
        var receive: SymmetricKey { SymmetricKey(data: okm.suffix(32)) }
    }

    /// th = SHA256(label || E_p || P || K || E_k); okm = HKDF(salt psk, ikm dh1||dh2||dh3, info th).
    static func derive(ephemeral: Curve25519.KeyAgreement.PrivateKey, phone: Curve25519.KeyAgreement.PrivateKey,
                       kindle: Data, kindleEphemeral: Data, psk: Data) throws -> Derived {
        let k = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: kindle)
        let ek = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: kindleEphemeral)
        var ikm = Data()
        for secret in [try ephemeral.sharedSecretFromKeyAgreement(with: k),
                       try phone.sharedSecretFromKeyAgreement(with: k),
                       try ephemeral.sharedSecretFromKeyAgreement(with: ek)] {
            secret.withUnsafeBytes { ikm.append(contentsOf: $0) }
        }
        let th = Data(SHA256.hash(data: label + ephemeral.publicKey.rawRepresentation + phone.publicKey.rawRepresentation
                                  + kindle + kindleEphemeral))
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: psk, info: th, outputByteCount: 64)
        return Derived(transcript: th, okm: okm.withUnsafeBytes { Data($0) })
    }

    /// `0x00000000 || counter (u64 big-endian)`.
    static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    /// Outgoing records: `len (u16 BE, ciphertext + tag) || ciphertext || tag`, at most 16 KiB
    /// of plaintext each (the plaintext is a byte stream: frames split freely).
    struct Sealer {
        let key: SymmetricKey
        private(set) var counter: UInt64 = 0

        init(key: SymmetricKey) { self.key = key }

        mutating func seal(_ plaintext: Data) throws -> Data {
            let bytes = [UInt8](plaintext)
            var out = Data()
            var offset = 0
            repeat {
                let part = Data(bytes[offset..<min(offset + KindleCrypto.maxPlaintext, bytes.count)])
                let box = try ChaChaPoly.seal(part, using: key, nonce: try KindleCrypto.nonce(counter))
                counter += 1
                let length = box.ciphertext.count + box.tag.count
                out.append(contentsOf: [UInt8(length >> 8), UInt8(length & 0xFF)])
                out.append(box.ciphertext)
                out.append(box.tag)
                offset += part.count
            } while offset < bytes.count
            return out
        }
    }

    /// Incoming records, reassembled from TCP reads of any size. Any record that fails to
    /// open is fatal (the link closes).
    struct Opener {
        let key: SymmetricKey
        private(set) var counter: UInt64 = 0
        private var buffer = [UInt8]()

        init(key: SymmetricKey) { self.key = key }

        mutating func push(_ data: Data) throws -> [Data] {
            buffer.append(contentsOf: data)
            var out: [Data] = []
            while buffer.count >= 2 {
                let length = Int(buffer[0]) << 8 | Int(buffer[1])
                guard length >= KindleCrypto.tagLength, length <= KindleCrypto.maxPlaintext + KindleCrypto.tagLength else {
                    throw KindleError.badRecord
                }
                guard buffer.count >= 2 + length else { break }
                let body = buffer[2..<2 + length]
                let box = try ChaChaPoly.SealedBox(nonce: try KindleCrypto.nonce(counter),
                                                   ciphertext: Data(body.dropLast(KindleCrypto.tagLength)),
                                                   tag: Data(body.suffix(KindleCrypto.tagLength)))
                do {
                    out.append(try ChaChaPoly.open(box, using: key))
                } catch {
                    throw KindleError.badRecord
                }
                counter += 1
                buffer.removeFirst(2 + length)
            }
            return out
        }
    }
}

/// base64url without padding, as the pairing QR code writes keys.
extension Data {
    init?(base64URL text: String) {
        var b64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        self.init(base64Encoded: b64)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
