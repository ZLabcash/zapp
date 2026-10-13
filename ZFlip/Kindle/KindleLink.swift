import CryptoKit
import Foundation
import Network

/// The parts of a link to a signing device the wallet uses, whatever carries it (Bluetooth
/// to a Flipper, Wi-Fi to a Kindle). The frames are zfirm's on both.
@MainActor
protocol SignerLink: AnyObject {
    var isConnected: Bool { get }
    func request(_ kind: FlipperProtocol.Kind, _ payload: Data, timeout: TimeInterval) async throws -> FlipperProtocol.Frame
    func disconnect()
}

extension SignerLink {
    func request(_ kind: FlipperProtocol.Kind, _ payload: Data = Data()) async throws -> FlipperProtocol.Frame {
        try await request(kind, payload, timeout: 300)
    }
}

extension FlipperLink: SignerLink {}

/// Where a paired KindleWallet is, and the key that proves it's the one (saved with its wallet).
struct KindleEndpoint: Codable, Equatable {
    /// The last IPv4 address it answered on.
    var host: String
    var port: UInt16
    /// K: the Kindle's static X25519 public key (32 bytes).
    var key: Data
    var name: String

    static let defaultPort: UInt16 = 7700

    /// `zfirm-kindle:?h=<ipv4>:7700&k=<K>&p=<PSK>&n=<name>`, shown on the Kindle to pair. The
    /// PSK is only good while that screen is open.
    static func parse(_ text: String) -> (endpoint: KindleEndpoint, psk: Data)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("zfirm-kindle:"),
              let query = trimmed.split(separator: "?", maxSplits: 1).dropFirst().first,
              let items = URLComponents(string: "x://x?" + query)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let h = value("h"), let key = value("k").flatMap(Data.init(base64URL:)), key.count == 32,
              let psk = value("p").flatMap(Data.init(base64URL:)), psk.count == 16 else { return nil }
        let parts = h.split(separator: ":")
        guard let host = parts.first.map(String.init), IPv4Address(host) != nil else { return nil }
        let port = parts.count > 1 ? UInt16(parts[1]) ?? defaultPort : defaultPort
        let name = value("n").flatMap { $0.isEmpty ? nil : $0 } ?? "Kindle"
        return (KindleEndpoint(host: host, port: port, key: key, name: name), psk)
    }
}

enum KindleError: LocalizedError {
    case notConnected
    case notFound
    case noWiFi
    case timeout
    case handshake
    case badRecord

    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "Connect, then scan the QR code on your Kindle (Zcash, Phone link) and Allow on it.")
        case .notFound: return String(localized: "Kindle not found on this Wi-Fi. Open KindleWallet on it, on the same network as this phone.")
        case .noWiFi: return String(localized: "Join the same Wi-Fi as your Kindle to connect.")
        case .timeout: return String(localized: "The Kindle did not answer in time.")
        case .handshake, .badRecord: return String(localized: "The Kindle refused the connection. Pair it again from its QR code.")
        }
    }
}

/// The Wi-Fi link to KindleWallet on a Kindle: TCP to port 7700, encrypted end to end
/// (KindleCrypto). Inside, the same frames as the Flipper's, so the wallet drives both alike.
@MainActor
final class KindleLink: ObservableObject, SignerLink {
    enum State: Equatable {
        case idle
        case connecting(String)
        case connected(String)
    }

    @Published private(set) var state = State.idle
    /// Set while the Kindle shows a prompt and waits for its user (STATUS frames).
    @Published private(set) var awaitingUser = false
    /// Called when the Kindle reports the receiving address it shows.
    var onAddress: ((UInt32, String) -> Void)?

    private var channel: KindleChannel?
    /// Bumped by every connect and disconnect: an older attempt that finishes late
    /// closes what it found instead of taking over.
    private var generation = 0
    private var decoder = FlipperProtocol.Decoder()
    private var waiting: CheckedContinuation<FlipperProtocol.Frame, Error>?

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Connects to `endpoint` (with the QR code's `psk` when pairing). Succeeds only once the
    /// Kindle answered inside the encrypted channel, which only the holder of its key can.
    func connect(_ endpoint: KindleEndpoint, psk: Data = KindleCrypto.zeroPSK, timeout: TimeInterval = 20) async throws {
        disconnect()
        let attempt = generation
        state = .connecting(endpoint.name)
        do {
            try adopt(try await KindleChannel.open(endpoint.host, endpoint, psk: psk, timeout: timeout), endpoint, attempt)
        } catch {
            if attempt == generation, case .connecting = state { state = .idle }
            throw error
        }
    }

    /// Connects to a paired Kindle: at its last address, else wherever on this Wi-Fi it
    /// answers (spec §4: the phone's /24, port 7700). Returns the address it answered on.
    func reconnect(_ endpoint: KindleEndpoint) async throws -> String {
        disconnect()
        let attempt = generation
        state = .connecting(endpoint.name)
        do {
            if let channel = try? await KindleChannel.open(endpoint.host, endpoint, psk: KindleCrypto.zeroPSK, timeout: 5) {
                try adopt(channel, endpoint, attempt)
                return endpoint.host
            }
            guard attempt == generation else { throw KindleError.notConnected }
            guard let hosts = LocalNetwork.subnetHosts() else { throw KindleError.noWiFi }
            guard let (host, channel) = await Self.sweep(hosts.filter { $0 != endpoint.host }, endpoint) else {
                throw KindleError.notFound
            }
            try adopt(channel, endpoint, attempt)
            return host
        } catch {
            if attempt == generation, case .connecting = state { state = .idle }
            throw error
        }
    }

    /// Tries every host, 48 at a time; the first to complete the handshake with the stored
    /// key wins (no other device can).
    private static func sweep(_ hosts: [String], _ endpoint: KindleEndpoint) async -> (String, KindleChannel)? {
        await withTaskGroup(of: (String, KindleChannel)?.self) { group in
            var pending = hosts.makeIterator()
            func next() -> Bool {
                guard let host = pending.next() else { return false }
                group.addTask { @MainActor in
                    guard let channel = try? await KindleChannel.open(host, endpoint, psk: KindleCrypto.zeroPSK, timeout: 2) else { return nil }
                    return (host, channel)
                }
                return true
            }
            for _ in 0..<48 where next() {}
            var found: (String, KindleChannel)?
            while let result = await group.next() {
                if let result {
                    if found == nil {
                        found = result
                        group.cancelAll()
                    } else {
                        result.1.close()
                    }
                } else if found == nil {
                    _ = next()
                }
            }
            return found
        }
    }

    private func adopt(_ channel: KindleChannel, _ endpoint: KindleEndpoint, _ attempt: Int) throws {
        guard attempt == generation else {
            channel.close()
            throw KindleError.notConnected
        }
        self.channel = channel
        decoder = FlipperProtocol.Decoder()
        channel.onPlaintext = { [weak self, weak channel] data in
            guard let self, self.channel === channel else { return }
            self.received(data)
        }
        channel.onClose = { [weak self, weak channel] in
            guard let self, self.channel === channel else { return }
            self.reset()
        }
        state = .connected(endpoint.name)
    }

    func disconnect() {
        generation += 1
        channel?.close()
        reset()
    }

    /// Sends a frame and waits for the Kindle's answer (STATUS frames only update
    /// `awaitingUser`). `timeout` covers the user deciding on the Kindle.
    func request(_ kind: FlipperProtocol.Kind, _ payload: Data, timeout: TimeInterval) async throws -> FlipperProtocol.Frame {
        guard let channel else { throw KindleError.notConnected }
        waiting?.resume(throwing: KindleError.notConnected)
        waiting = nil
        try await channel.send(FlipperProtocol.encode(kind, payload))
        let timer = Task { @MainActor [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.waiting?.resume(throwing: KindleError.timeout)
            self?.waiting = nil
        }
        defer { timer.cancel() }
        let reply = try await withCheckedThrowingContinuation { waiting = $0 }
        awaitingUser = false
        if reply.kind == FlipperProtocol.Kind.error.rawValue {
            throw FlipperError.rejected(Self.decodeError(reply.payload))
        }
        return reply
    }

    /// `ERROR`: code 1 is the user saying no on the Kindle.
    private static func decodeError(_ data: Data) -> String {
        if data.first == 1 { return String(localized: "Rejected on the Kindle") }
        return FlipperProtocol.decodeError(data)
    }

    private func reset() {
        channel = nil
        state = .idle
        awaitingUser = false
        decoder = FlipperProtocol.Decoder()
        waiting?.resume(throwing: KindleError.notConnected)
        waiting = nil
    }

    private func received(_ data: Data) {
        do {
            for frame in try decoder.push(data) {
                if frame.kind == FlipperProtocol.Kind.status.rawValue {
                    awaitingUser = frame.payload.first == FlipperProtocol.Status.awaitingUser.rawValue
                    continue
                }
                // Sent unprompted whenever the user changes address on the Kindle.
                if frame.kind == FlipperProtocol.Kind.address.rawValue {
                    if let (index, text) = FlipperProtocol.decodeAddress(frame.payload) { onAddress?(index, text) }
                    continue
                }
                waiting?.resume(returning: frame)
                waiting = nil
            }
        } catch {
            waiting?.resume(throwing: error)
            waiting = nil
        }
    }
}

/// One encrypted TCP connection to a KindleWallet: the handshake, then records both ways.
@MainActor
final class KindleChannel {
    var onPlaintext: ((Data) -> Void)?
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private var sealer: KindleCrypto.Sealer?
    private var opener: KindleCrypto.Opener?
    /// Bytes read before the keys exist (the Kindle's half of the handshake).
    private var raw = Data()
    private var ready = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Error>?
    private var condition: (() -> Bool)?

    private init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.prohibitedInterfaceTypes = [.cellular]
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 7700, using: parameters)
    }

    /// Connects, runs the handshake and checks the Kindle answers a PING in the channel.
    /// Gives up after `timeout` seconds, or when the calling task is cancelled.
    static func open(_ host: String, _ endpoint: KindleEndpoint, psk: Data, timeout: TimeInterval) async throws -> KindleChannel {
        let channel = KindleChannel(host: host, port: endpoint.port)
        let timer = Task { @MainActor in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            channel.fail(KindleError.timeout)
        }
        defer { timer.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await channel.handshake(kindleKey: endpoint.key, psk: psk)
                try await channel.ping()
            } onCancel: {
                Task { @MainActor in channel.fail(CancellationError()) }
            }
        } catch {
            channel.close()
            throw error
        }
        return channel
    }

    private func handshake(kindleKey: Data, psk: Data) async throws {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(state) }
        }
        connection.start(queue: .main)
        // Waiting (no route yet, or the Local Network prompt on screen) is not a failure:
        // the timeout ends it.
        try await wait { [unowned self] in ready }
        receive()
        let phone = try LinkKey.phone()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        try await write(KindleCrypto.clientHello(ephemeral: ephemeral.publicKey.rawRepresentation, phone: phone.publicKey.rawRepresentation))
        try await wait { [unowned self] in raw.count >= 33 }
        guard raw.count == 33 else { throw KindleError.handshake }
        let kindleEphemeral = try KindleCrypto.serverHello(raw)
        let keys = try KindleCrypto.derive(ephemeral: ephemeral, phone: phone, kindle: kindleKey,
                                           kindleEphemeral: kindleEphemeral, psk: psk)
        sealer = KindleCrypto.Sealer(key: keys.send)
        opener = KindleCrypto.Opener(key: keys.receive)
        raw = Data()
    }

    /// The first record: a PING. A PONG back proves the Kindle derived the same keys.
    private func ping() async throws {
        var decoder = FlipperProtocol.Decoder()
        var pong = false
        var bad: Error?
        onPlaintext = { data in
            do {
                let frames = try decoder.push(data)
                if frames.contains(where: { $0.kind == FlipperProtocol.Kind.pong.rawValue }) { pong = true }
            } catch {
                bad = error
            }
        }
        defer { onPlaintext = nil }
        try await send(FlipperProtocol.encode(.ping))
        try await wait { pong || bad != nil }
        if let bad { throw bad }
    }

    func send(_ plaintext: Data) async throws {
        guard var sealer else { throw KindleError.notConnected }
        let records = try sealer.seal(plaintext)
        self.sealer = sealer
        try await write(records)
    }

    func close() {
        fail(KindleError.notConnected)
    }

    private func write(_ data: Data) async throws {
        if let failure { throw failure }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.failure == nil else { return }
                if let data, !data.isEmpty { self.arrived(data) }
                if self.failure != nil { return }
                if let error { self.fail(error); return }
                if complete { self.fail(KindleError.notConnected); return }
                self.receive()
            }
        }
    }

    private func arrived(_ data: Data) {
        guard var opener else {
            raw.append(data)
            poke()
            return
        }
        do {
            let plaintexts = try opener.push(data)
            self.opener = opener
            for p in plaintexts { onPlaintext?(p) }
            poke()
        } catch {
            fail(error)
        }
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            poke()
        case .failed(let error):
            fail(error)
        case .cancelled:
            fail(KindleError.notConnected)
        default:
            break
        }
    }

    /// Suspends until `done()` holds (checked whenever something arrives) or the channel fails.
    private func wait(_ done: @escaping () -> Bool) async throws {
        if let failure { throw failure }
        if done() { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiter = c
            condition = done
        }
    }

    private func poke() {
        guard let condition, condition() else { return }
        let waiter = self.waiter
        self.waiter = nil
        self.condition = nil
        waiter?.resume()
    }

    /// Closes for good: whoever waits gets `error`, the owner hears `onClose` once.
    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        connection.stateUpdateHandler = nil
        connection.cancel()
        let waiter = self.waiter
        self.waiter = nil
        condition = nil
        waiter?.resume(throwing: error)
        onClose?()
        onClose = nil
    }
}

/// This phone's long-lived link key P (one per install, the same for every Kindle). The
/// Kindle keeps its public half in its list of paired phones.
enum LinkKey {
    private static let service = "cash.zscan.zapp.kindle-link"

    static func phone() throws -> Curve25519.KeyAgreement.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "P",
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "P",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key.rawRepresentation,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return key
    }
}

/// The phone's own Wi-Fi network, to look for a Kindle whose address changed.
enum LocalNetwork {
    /// Every other host of this phone's Wi-Fi /24 (x.y.z.1 to .254), or nil without Wi-Fi.
    static func subnetHosts() -> [String]? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var own: [UInt8]?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard String(cString: ifa.ifa_name) == "en0", let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            own = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr.s_addr) { Array($0) }
            }
        }
        guard let own, own.count == 4, own[0] != 169 else { return nil }
        return (1...254).filter { $0 != Int(own[3]) }.map { "\(own[0]).\(own[1]).\(own[2]).\($0)" }
    }
}
