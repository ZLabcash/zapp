import Combine
import Foundation
import ZcashLightClientKit

/// The watch-only Zcash wallet backed by the Flipper's viewing key.
///
/// The phone syncs, builds transactions as PCZTs and proves them; it never holds a
/// spending key. Spends are signed by the Flipper after its user checks them there.
@MainActor
final class WalletModel: ObservableObject {
    /// What the Flipper told us when it was paired (persisted).
    struct Pairing: Codable, Equatable {
        var flipperID: UUID
        var flipperName: String
        var network: UInt8
        var ufvk: String
        var seedFingerprint: [UInt8]
        var account: UInt32
        var birthday: Int
        /// The receiving address index last shown on the Flipper.
        var addressIndex: UInt32?
    }

    /// The link to the paired Flipper, as the Home screen shows it.
    enum FlipperState: Equatable {
        case idle
        case connecting
        case approve
        case ready
        /// The Flipper holds another wallet than the one on this iPhone.
        case otherWallet(String)
        case failed(String)
    }

    enum SendStep: Equatable {
        case idle
        case preparing
        case confirmOnFlipper
        case broadcasting
        case sent(String)
        case failed(String)
    }

    @Published private(set) var pairing: Pairing?
    @Published private(set) var balance = Zatoshi.zero
    @Published private(set) var pending = Zatoshi.zero
    @Published private(set) var syncProgress: Float = 0
    @Published private(set) var synced = false
    @Published private(set) var syncError: String?
    /// The chain tip, and the height scanned contiguously from the birthday.
    @Published private(set) var tipHeight = 0
    @Published private(set) var scannedHeight = 0
    /// This wallet's transactions, newest first.
    @Published private(set) var transactions: [ZcashTransaction.Overview] = []
    private var lastTransactionsRefresh = Date.distantPast
    @Published private(set) var address: String?
    @Published var sendStep = SendStep.idle
    @Published private(set) var flipperState = FlipperState.idle
    /// Bluetooth permission refused: only Settings can grant it now.
    @Published private(set) var bluetoothDenied = false
    /// The Flipper accepted this connection's HELLO (it will take sign requests).
    var flipperReady: Bool { flipperState == .ready }
    /// Amounts show only while the Flipper is connected: a glance at the phone
    /// alone gives nothing away. (Privacy from onlookers, not security: the viewing
    /// key is on the phone.)
    var showsAmounts: Bool { flipperReady }
    /// INFO from a Flipper holding another wallet, kept to adopt it on request.
    private var otherWallet: (info: FlipperProtocol.Info, id: UUID)?

    let link: FlipperLink
    private var synchronizer: SDKSynchronizer?
    private var accountUUID: AccountUUID?
    private var cancellables = Set<AnyCancellable>()
    /// The synchronizer's subscriptions (reset when the wallet is replaced).
    private var syncCancellables = Set<AnyCancellable>()

    private static let pairingKey = "zflip.pairing"
    /// 2026-10-01: no ZFlip wallet is older. A Flipper whose clock was never set
    /// stamps its wallet years in the past, which would mean scanning the whole chain.
    private static let zflipEpoch = Date(timeIntervalSince1970: 1_790_812_800)
    /// NU5 (June 2022): the Orchard pool, the oldest a ZFlip wallet can hold funds in.
    private static let nu5Date = Date(timeIntervalSince1970: 1_654_041_600)

    private static func nu5Height(_ network: NetworkType) -> Int {
        network == .testnet ? 1_842_420 : 1_687_104
    }

    init(link: FlipperLink) {
        self.link = link
        link.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .connected:
                    break
                case .connecting:
                    if case .otherWallet = self.flipperState { break }
                    self.flipperState = .connecting
                default:
                    if case .otherWallet = self.flipperState { break }
                    if case .failed = self.flipperState { break }
                    self.flipperState = .idle
                }
            }
            .store(in: &cancellables)
        link.$awaitingFlipper
            .receive(on: DispatchQueue.main)
            .sink { [weak self] waiting in
                if waiting, let self, self.flipperState != .ready { self.flipperState = .approve }
            }
            .store(in: &cancellables)
        link.onAddress = { [weak self] index, text in self?.flipperShows(index, text) }
        if let data = UserDefaults.standard.data(forKey: Self.pairingKey),
           let saved = try? JSONDecoder().decode(Pairing.self, from: data) {
            pairing = saved
        }
    }

    var networkType: NetworkType {
        pairing?.network == 1 ? .testnet : .mainnet
    }

    // MARK: Pairing

    /// Asks the connected Flipper for its viewing key (the user approves on the Flipper).
    func requestInfo() async throws -> FlipperProtocol.Info {
        let reply = try await link.request(.hello)
        guard reply.kind == FlipperProtocol.Kind.info.rawValue else {
            throw FlipperError.protocolError("Unexpected reply from the Flipper")
        }
        let info = try FlipperProtocol.Info(reply.payload)
        if let pairing, info.ufvk != pairing.ufvk {
            otherWallet = (info, pairing.flipperID)
            flipperState = .otherWallet(info.deviceName)
            throw FlipperError.rejected("This Flipper holds another wallet.")
        }
        flipperState = .ready
        if pairing != nil {
            remember(index: info.addressIndex)
            await repairBirthday(info)
        }
        return info
    }

    /// Creates the watch-only wallet for a Flipper. `restoredFrom` is the date to
    /// scan from when the Flipper's seed was restored rather than created on it.
    func createWallet(info: FlipperProtocol.Info, flipperID: UUID, restoredFrom: Date?) async throws {
        await tearDown()
        let network = ZcashNetworkBuilder.network(for: info.network == 1 ? .testnet : .mainnet)
        let synchronizer = try makeSynchronizer(network: network)
        let birthday = Self.birthday(for: info, restoredFrom: restoredFrom, synchronizer: synchronizer)
        let pairing = Pairing(
            flipperID: flipperID,
            flipperName: info.deviceName,
            network: info.network,
            ufvk: info.ufvk,
            seedFingerprint: info.seedFingerprint,
            account: info.account,
            birthday: birthday,
            addressIndex: info.addressIndex
        )
        try await open(pairing, synchronizer: synchronizer, importing: true)
        UserDefaults.standard.set(try JSONEncoder().encode(pairing), forKey: Self.pairingKey)
        self.pairing = pairing
        flipperState = .ready
    }

    /// Where to start scanning: the wallet's creation day (less a day of margin),
    /// never before ZFlip existed for a wallet made on a Flipper, never before NU5.
    private static func birthday(for info: FlipperProtocol.Info, restoredFrom: Date?, synchronizer: SDKSynchronizer) -> Int {
        let since: Date
        if info.createdAt > 0 {
            since = max(Date(timeIntervalSince1970: TimeInterval(info.createdAt)), zflipEpoch)
        } else {
            since = max(restoredFrom ?? nu5Date, nu5Date)
        }
        let estimate = synchronizer.estimateBirthdayHeight(for: since.addingTimeInterval(-86_400))
        return max(estimate, nu5Height(info.network == 1 ? .testnet : .mainnet))
    }

    /// Stops and erases the current watch-only wallet (the keys stay on the Flipper).
    private func tearDown() async {
        synchronizer?.stop()
        if let synchronizer {
            _ = try? await synchronizer.wipe().values.first(where: { _ in true })
        }
        synchronizer = nil
        accountUUID = nil
        syncCancellables.removeAll()
        address = nil
        balance = .zero
        pending = .zero
        transactions = []
        tipHeight = 0
        scannedHeight = 0
        synced = false
        syncProgress = 0
    }

    /// A wallet paired with a wrong birthday (a Flipper clock that was never set):
    /// rebuilt from the right one, which this Flipper's INFO gives.
    private func repairBirthday(_ info: FlipperProtocol.Info) async {
        guard let pairing, let synchronizer, info.createdAt > 0 else { return }
        let expected = Self.birthday(for: info, restoredFrom: nil, synchronizer: synchronizer)
        guard pairing.birthday + 1_000 < expected else { return }
        print("[zapp] birthday \(pairing.birthday) -> \(expected): rebuilding the wallet")
        try? await createWallet(info: info, flipperID: pairing.flipperID, restoredFrom: nil)
    }

    /// Opens the saved wallet at launch.
    func resume() async {
        guard var pairing, synchronizer == nil else { return }
        do {
            let network = ZcashNetworkBuilder.network(for: networkType)
            // Pairings made before the birthday fix, from a Flipper whose clock was never
            // set, start before NU5 (or exactly at it, from a first repair). No such wallet
            // predates ZFlip: start from ZFlip's first day instead, on a fresh database.
            if pairing.birthday <= Self.nu5Height(networkType) {
                try? FileManager.default.removeItem(at: try Self.dataDirectory(networkType))
                let synchronizer = try makeSynchronizer(network: network)
                pairing.birthday = synchronizer.estimateBirthdayHeight(for: Self.zflipEpoch.addingTimeInterval(-86_400))
                self.pairing = pairing
                UserDefaults.standard.set(try JSONEncoder().encode(pairing), forKey: Self.pairingKey)
                print("[zapp] birthday reset to \(pairing.birthday)")
                try await open(pairing, synchronizer: synchronizer, importing: true)
                return
            }
            try await open(pairing, synchronizer: try makeSynchronizer(network: network), importing: false)
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Connects to the paired Flipper and opens a session (the user presses OK on
    /// the Flipper). Waits as long as it takes for ZFlip Sign to appear.
    /// "Connect to Flipper": connects and opens a session (OK on the Flipper).
    func connectFlipper() async {
        guard let pairing, !flipperReady else { return }
        if case .connecting = link.state { return }
        flipperState = .connecting
        bluetoothDenied = false
        do {
            if !link.isConnected {
                try await link.connect(pairing.flipperID, timeout: 20)
            }
            _ = try await requestInfo()
        } catch FlipperError.timeout {
            flipperState = .failed("Flipper not found. Open ZFlip on it and unlock it.")
        } catch FlipperError.bluetoothDenied {
            bluetoothDenied = true
            flipperState = .failed(FlipperError.bluetoothDenied.localizedDescription)
        } catch {
            if case .otherWallet = flipperState { return }
            flipperState = .failed(error.localizedDescription)
        }
    }

    func disconnectFlipper() {
        link.disconnect()
        flipperState = .idle
    }

    /// Replaces this iPhone's watch-only wallet with the one on the connected Flipper.
    func adoptFlipperWallet() async {
        guard let (info, id) = otherWallet else { return }
        otherWallet = nil
        do {
            try await createWallet(info: info, flipperID: id, restoredFrom: nil)
            flipperState = .ready
        } catch {
            flipperState = .failed(error.localizedDescription)
        }
    }

    /// The Flipper switched to address `index`: follow it, once checked against our
    /// own derivation from the viewing key.
    private func flipperShows(_ index: UInt32, _ text: String) {
        guard let ufvk = pairing?.ufvk, (try? Bridge.address(ufvk: ufvk, index: index)) == text else { return }
        remember(index: index)
    }

    private func remember(index: UInt32) {
        guard var p = pairing, p.addressIndex != index else { return }
        p.addressIndex = index
        pairing = p
        if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: Self.pairingKey) }
    }

    /// The receiving address the Flipper shows (or showed last).
    var receiveIndex: UInt32 { pairing?.addressIndex ?? 0 }

    /// The diversified address at `index` (index 0 is the wallet's default).
    func address(at index: UInt32) -> String? {
        guard let ufvk = pairing?.ufvk else { return nil }
        return try? Bridge.address(ufvk: ufvk, index: index)
    }

    func forget() async {
        await tearDown()
        flipperState = .idle
        UserDefaults.standard.removeObject(forKey: Self.pairingKey)
        pairing = nil
        address = nil
        balance = .zero
        link.disconnect()
    }

    private static func dataDirectory(_ network: NetworkType) throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ZFlip-\(network == .testnet ? "test" : "main")", isDirectory: true)
    }

    private func makeSynchronizer(network: ZcashNetwork) throws -> SDKSynchronizer {
        let base = try Self.dataDirectory(network.networkType)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let endpoint = network.networkType == .testnet
            ? LightWalletEndpoint(address: "testnet.zec.rocks", port: 443)
            : LightWalletEndpoint(address: "zec.rocks", port: 443)
        let initializer = Initializer(
            cacheDbURL: nil,
            fsBlockDbRoot: base.appendingPathComponent("fs_cache", isDirectory: true),
            generalStorageURL: base.appendingPathComponent("general", isDirectory: true),
            dataDbURL: base.appendingPathComponent("data.db"),
            torDirURL: base.appendingPathComponent("tor", isDirectory: true),
            endpoint: endpoint,
            network: network,
            spendParamsURL: base.appendingPathComponent("sapling-spend.params"),
            outputParamsURL: base.appendingPathComponent("sapling-output.params"),
            saplingParamsSourceURL: .default,
            loggingPolicy: .custom(ConsoleLogger()),
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
        return SDKSynchronizer(initializer: initializer)
    }

    private func open(_ pairing: Pairing, synchronizer: SDKSynchronizer, importing: Bool) async throws {
        _ = try await synchronizer.prepare(with: nil, walletBirthday: pairing.birthday, name: "ZFlip", keySource: "zflip")
        var account = try await synchronizer.listAccounts().first
        if account == nil || importing {
            if account == nil {
                // "spending" with the seed fingerprint and ZIP 32 index: the SDK then
                // stamps PCZT spends with the derivation path an external signer needs.
                let id = try await synchronizer.importAccount(
                    ufvk: pairing.ufvk,
                    seedFingerprint: pairing.seedFingerprint,
                    zip32AccountIndex: Zip32AccountIndex(pairing.account),
                    purpose: .spending,
                    name: pairing.flipperName,
                    keySource: "zflip",
                    birthday: pairing.birthday
                )
                account = try await synchronizer.listAccounts().first(where: { $0.id == id })
            }
        }
        guard let account else { throw FlipperError.protocolError("Could not create the wallet account") }
        self.synchronizer = synchronizer
        self.accountUUID = account.id
        address = try? await synchronizer.getUnifiedAddress(accountUUID: account.id).stringEncoded

        synchronizer.stateStream
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.update(state) }
            .store(in: &syncCancellables)
        try await synchronizer.start(retry: true)
    }

    private func update(_ state: SynchronizerState) {
        if state.latestBlockHeight > 0 { tipHeight = state.latestBlockHeight }
        if state.fullyScannedHeight > 0 { scannedHeight = state.fullyScannedHeight }
        refreshTransactions(force: false)
        if let id = accountUUID, let b = state.accountsBalances[id] {
            balance = b.ironwoodBalance.spendableValue + b.orchardBalance.spendableValue
            let total = b.ironwoodBalance.total() + b.orchardBalance.total()
            pending = total - balance
        }
        switch state.syncStatus {
        case .syncing(let progress, _):
            syncProgress = progress
            synced = false
            syncError = nil
        case .upToDate:
            syncProgress = 1
            synced = true
            syncError = nil
        case .error(let error):
            syncError = error.localizedDescription
        default:
            break
        }
    }

    /// At most every 3 seconds while syncing; at once when asked.
    func refreshTransactions(force: Bool) {
        guard let synchronizer, force || Date().timeIntervalSince(lastTransactionsRefresh) > 3 else { return }
        lastTransactionsRefresh = Date()
        Task {
            let all = await synchronizer.transactions
            self.transactions = all.sorted { ($0.minedHeight ?? .max, $0.index ?? 0) > ($1.minedHeight ?? .max, $1.index ?? 0) }
        }
    }

    /// Confirmations of a mined transaction (nil while in the mempool).
    func confirmations(_ tx: ZcashTransaction.Overview) -> Int? {
        guard let mined = tx.minedHeight, tipHeight >= mined else { return nil }
        return tipHeight - mined + 1
    }

    /// The transaction on ZScan (txids are shown byte-reversed).
    static func zscanURL(_ tx: ZcashTransaction.Overview) -> URL? {
        let hex = tx.rawID.reversed().map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://zscan.cash/tx/\(hex)")
    }

    // MARK: Sending

    func validate(address: String) -> Bool {
        (try? Recipient(address, network: networkType)) != nil
    }

    /// Builds the transaction, has the Flipper check and sign it, proves and broadcasts.
    func send(to address: String, zatoshi: Int64, memo: String) async {
        guard let synchronizer, let accountUUID, let pairing else { return }
        sendStep = .preparing
        do {
            let recipient = try Recipient(address, network: networkType)
            let memo = memo.isEmpty ? nil : try Memo(string: memo)
            let proposal = try await synchronizer.proposeTransfer(
                accountUUID: accountUUID,
                recipient: recipient,
                amount: Zatoshi(zatoshi),
                memo: memo
            )
            let pczt = try await synchronizer.createPCZTFromProposal(accountUUID: accountUUID, proposal: proposal)
            let request = try Bridge.signRequest(pczt: pczt, ufvk: pairing.ufvk)

            if !flipperReady {
                if !link.isConnected {
                    try await link.connect(pairing.flipperID)
                }
                _ = try await requestInfo()
            }
            // Prove on the phone while the user checks the transaction on the Flipper.
            async let proven = synchronizer.addProofsToPCZT(pczt: pczt)
            sendStep = .confirmOnFlipper
            let reply = try await link.request(.sign, request, timeout: 600)
            guard reply.kind == FlipperProtocol.Kind.signed.rawValue else {
                throw FlipperError.protocolError("Unexpected reply from the Flipper")
            }
            let signed = try Bridge.applySignatures(pczt: pczt, signatures: reply.payload)
            sendStep = .broadcasting
            let results = try await synchronizer.createTransactionFromPCZT(pcztWithProofs: try await proven, pcztWithSigs: signed)
            for try await result in results {
                switch result {
                case .success(let txId):
                    sendStep = .sent(txId.reversed().map { String(format: "%02x", $0) }.joined())
                case .grpcFailure(_, let error):
                    sendStep = .failed(error.localizedDescription)
                case .submitFailure(_, _, let description):
                    sendStep = .failed(description)
                case .notAttempted:
                    sendStep = .failed("The transaction was not submitted")
                }
            }
        } catch {
            sendStep = .failed(Self.explain(error, zatoshi: zatoshi))
        }
    }

    /// ZIP 317: 5,000 zatoshis per logical action, at least two. A simple shielded
    /// payment pays this.
    static let minimumFee = Zatoshi(10_000)

    /// What went wrong, in words (the SDK's errors carry the Rust message inside).
    private static func explain(_ error: Error, zatoshi: Int64) -> String {
        if case ZcashError.rustCreateToAddress(let detail) = error {
            print("[zapp] propose failed: \(detail)")
            if detail.localizedCaseInsensitiveContains("insufficient") {
                return "Not enough spendable ZEC. Sending \(Zatoshi(zatoshi).zecString) also costs a network fee of at least \(minimumFee.zecString), and received funds become spendable after 10 confirmations."
            }
            return "Could not prepare the transaction: \(detail)"
        }
        return error.localizedDescription
    }

    func proposalFee(to address: String, zatoshi: Int64) async -> Zatoshi? {
        guard let synchronizer, let accountUUID, let recipient = try? Recipient(address, network: networkType) else {
            return nil
        }
        let proposal = try? await synchronizer.proposeTransfer(
            accountUUID: accountUUID, recipient: recipient, amount: Zatoshi(zatoshi), memo: nil
        )
        return proposal?.totalFeeRequired()
    }
}

extension Zatoshi {
    /// The amount alone ("1.2345"), for next to the ZEC symbol.
    var zecAmount: String {
        String(zecString.dropLast(4))
    }

    /// "1.2345 ZEC" style, trimming trailing zeros.
    var zecString: String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 8
        formatter.minimumIntegerDigits = 1
        formatter.decimalSeparator = "."
        formatter.usesGroupingSeparator = false
        return (formatter.string(from: NSNumber(value: Double(amount) / 1e8)) ?? "0") + " ZEC"
    }
}

/// The SDK's log on stdout (seen with `devicectl ... --console`), info and up.
struct ConsoleLogger: ZcashLightClientKit.Logger {
    func maxLogLevel() -> OSLogger.LogLevel? { .info }
    private func out(_ level: String, _ message: String) { print("[zcash \(level)] \(message)") }
    func debug(_ message: String, file: StaticString, function: StaticString, line: Int) {}
    func info(_ message: String, file: StaticString, function: StaticString, line: Int) { out("info", message) }
    func event(_ message: String, file: StaticString, function: StaticString, line: Int) { out("event", message) }
    func warn(_ message: String, file: StaticString, function: StaticString, line: Int) { out("warn", message) }
    func error(_ message: String, file: StaticString, function: StaticString, line: Int) { out("error", message) }
    func sync(_ message: String, file: StaticString, function: StaticString, line: Int) { out("sync", message) }
}
