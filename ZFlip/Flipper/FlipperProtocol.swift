import Foundation

/// The phone <-> Flipper wire protocol (see `core/src/protocol.rs` and PROTOCOL.md).
/// A frame is `0x5A 0x01 kind len:u32le payload`; strings are u16le-length UTF-8.
enum FlipperProtocol {
    static let magic: UInt8 = 0x5A
    static let version: UInt8 = 0x01
    static let headerLength = 7

    enum Kind: UInt8 {
        case hello = 0x01
        case sign = 0x04
        case ping = 0x05
        /// Kindle only (not zfirm_core): the zkSNARKs held, to list on the Kindle.
        case nfts = 0x40
        case info = 0x81
        case address = 0x83
        case signed = 0x84
        case pong = 0x85
        case status = 0x86
        case nftsOK = 0xC0
        case error = 0xE0
    }

    enum Status: UInt8 {
        case awaitingUser = 1
        case working = 2
    }

    struct Frame {
        let kind: UInt8
        let payload: Data
    }

    static func encode(_ kind: Kind, _ payload: Data = Data()) -> Data {
        var data = Data([magic, version, kind.rawValue])
        data.append(UInt32(payload.count).littleEndianData)
        data.append(payload)
        return data
    }

    /// Reassembles frames from BLE packets of any size.
    struct Decoder {
        private var buffer = Data()

        mutating func push(_ bytes: Data) throws -> [Frame] {
            buffer.append(bytes)
            var frames: [Frame] = []
            while buffer.count >= headerLength {
                let b = [UInt8](buffer.prefix(headerLength))
                guard b[0] == magic, b[1] == version else {
                    buffer.removeAll()
                    throw FlipperError.protocolError("Bad frame from the Flipper")
                }
                let length = Int(UInt32(b[3]) | UInt32(b[4]) << 8 | UInt32(b[5]) << 16 | UInt32(b[6]) << 24)
                guard buffer.count >= headerLength + length else { break }
                let start = buffer.startIndex + headerLength
                frames.append(Frame(kind: b[2], payload: Data(buffer[start..<start + length])))
                buffer.removeFirst(headerLength + length)
            }
            return frames
        }
    }

    /// `INFO`: what the phone needs to create the watch-only account.
    struct Info: Equatable {
        let network: UInt8
        let account: UInt32
        let seedFingerprint: [UInt8]
        let ufvk: String
        /// Unix time the seed was generated on the Flipper, or 0 if it was restored.
        let createdAt: UInt32
        let deviceName: String
        /// Index of the receiving address the Flipper is showing.
        let addressIndex: UInt32

        init(_ data: Data) throws {
            var r = Reader(data)
            network = try r.u8()
            account = try r.u32()
            seedFingerprint = try r.bytes(32)
            ufvk = try r.string()
            createdAt = try r.u32()
            deviceName = try r.string()
            addressIndex = (try? r.u32()) ?? 0
        }
    }

    /// `ADDRESS`: index and unified address.
    static func decodeAddress(_ data: Data) -> (UInt32, String)? {
        var r = Reader(data)
        guard let index = try? r.u32(), let text = try? r.string() else { return nil }
        return (index, text)
    }

    /// `ERROR`: code and message.
    static func decodeError(_ data: Data) -> String {
        var r = Reader(data)
        guard let code = try? r.u8(), let message = try? r.string() else { return String(localized: "Unknown Flipper error") }
        return code == 1 ? "Rejected on the Flipper" : message
    }

    struct Reader {
        private var data: [UInt8]
        private var offset = 0

        init(_ data: Data) { self.data = [UInt8](data) }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard offset + n <= data.count else { throw FlipperError.protocolError("Truncated reply") }
            defer { offset += n }
            return Array(data[offset..<offset + n])
        }

        mutating func u8() throws -> UInt8 { try bytes(1)[0] }

        mutating func u16() throws -> UInt16 {
            let b = try bytes(2)
            return UInt16(b[0]) | UInt16(b[1]) << 8
        }

        mutating func u32() throws -> UInt32 {
            let b = try bytes(4)
            return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }

        mutating func string() throws -> String {
            let n = Int(try u16())
            guard let s = String(bytes: try bytes(n), encoding: .utf8) else {
                throw FlipperError.protocolError("Bad text in reply")
            }
            return s
        }
    }
}

enum FlipperError: LocalizedError {
    case bluetoothOff
    case bluetoothDenied
    case notConnected
    case timeout
    case rejected(String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothOff: return String(localized: "Bluetooth is off. Turn it on to connect.")
        case .bluetoothDenied: return String(localized: "ZApp may not use Bluetooth. Allow it in Settings.")
        case .notConnected: return String(localized: "The Flipper is not connected.")
        case .timeout: return String(localized: "The Flipper did not answer in time.")
        case .rejected(let message): return message
        case .protocolError(let message): return message
        }
    }
}

extension UInt32 {
    var littleEndianData: Data {
        withUnsafeBytes(of: littleEndian) { Data($0) }
    }
}

extension UInt16 {
    var littleEndianData: Data {
        withUnsafeBytes(of: littleEndian) { Data($0) }
    }
}
