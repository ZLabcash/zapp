import Foundation
import ZFlipBridge

/// Swift face of the Rust bridge (`bridge/src/ffi.rs`).
enum Bridge {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func call(_ body: (UnsafeMutablePointer<ZflipBuffer>) -> Int32) throws -> Data {
        var out = ZflipBuffer(ptr: nil, len: 0)
        let code = body(&out)
        defer { zflip_free(out) }
        let bytes = out.ptr.map { Data(bytes: $0, count: out.len) } ?? Data()
        guard code == 0 else { throw Failure(message: String(decoding: bytes, as: UTF8.self)) }
        return bytes
    }

    /// 24 words from 32 bytes of entropy.
    static func mnemonicNew(entropy: [UInt8]) throws -> String {
        let bytes = try entropy.withUnsafeBufferPointer { e in try call { out in zflip_mnemonic_new(e.baseAddress, out) } }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The 64-byte seed of a recovery phrase; throws if a word or the checksum is wrong.
    static func mnemonicSeed(_ phrase: String) throws -> [UInt8] {
        do {
            return [UInt8](try call { out in zflip_mnemonic_seed(phrase, out) })
        } catch {
            throw Failure(message: String(localized: "These words aren't a valid recovery phrase. Check each word and their order."))
        }
    }

    static func seedFingerprint(_ seed: [UInt8]) throws -> [UInt8] {
        [UInt8](try seed.withUnsafeBufferPointer { s in try call { out in zflip_seed_fingerprint(s.baseAddress, s.count, out) } })
    }

    /// Lowercase words separated by single spaces.
    static func normalized(_ phrase: String) -> String {
        phrase.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The unified address at diversifier index `index`: the Flipper's "Address #index".
    static func address(ufvk: String, index: UInt32) throws -> String {
        let bytes = try call { out in zflip_address(ufvk, index, out) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The compact request the Flipper checks and signs.
    static func signRequest(pczt: Data, ufvk: String) throws -> Data {
        try pczt.withUnsafeBytes { p in
            try call { out in
                zflip_sign_request(p.bindMemory(to: UInt8.self).baseAddress, p.count, ufvk, out)
            }
        }
    }

    /// The PCZT with the Flipper's spend authorization signatures applied.
    static func applySignatures(pczt: Data, signatures: Data) throws -> Data {
        try pczt.withUnsafeBytes { p in
            try signatures.withUnsafeBytes { s in
                try call { out in
                    zflip_apply_signatures(
                        p.bindMemory(to: UInt8.self).baseAddress, p.count,
                        s.bindMemory(to: UInt8.self).baseAddress, s.count,
                        out
                    )
                }
            }
        }
    }
}
