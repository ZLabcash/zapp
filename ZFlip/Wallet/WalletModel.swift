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
    /// Received from others, not yet spendable (10 confirmations).
    @Published private(set) var pending = Zatoshi.zero
    /// Change coming back from this wallet's own payments: already ours, spendable after a few
    /// confirmations. Counted in the balance shown, never as "incoming".
    @Published private(set) var change = Zatoshi.zero
    /// What the wallet owns now: spendable plus its own change on the way back.
    var owned: Zatoshi { balance + change }
    @Published private(set) var syncProgress: Float = 0
    @Published private(set) var synced = false
    @Published private(set) var syncError: String?
    /// The chain tip, and the height scanned contiguously from the birthday.
    @Published private(set) var tipHeight = 0
    @Published private(set) var scannedHeight = 0
    /// One line of Activity: what the views need from a transaction.
    struct ActivityItem: Identifiable, Equatable {
        let id: Data
        let sent: Bool
        /// For a payment: what the recipients got (the fee apart). Otherwise what came in.
        let zatoshi: Int64
        var fee: Int64? = nil
        let minedHeight: Int?
        let expired: Bool
        let blockTime: TimeInterval?
        let url: URL?
        /// As explorers show it (byte-reversed hex).
        var txid: String { id.reversed().map { String(format: "%02x", $0) }.joined() }
        /// The decrypted text messages of this transaction.
        var memos: [String] = []
    }

    /// The SDK's transactions by id, to ask it for recipients and memos.
    private var overviews: [Data: ZcashTransaction.Overview] = [:]

    /// This wallet's transactions, newest first.
    @Published private(set) var activity: [ActivityItem] = []
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
        if let scene = Demo.scene {
            applyDemo(scene)
            return
        }
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
        change = .zero
        activity = []
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

    /// A fixed state for filming (see `Demo`): no sync, no Flipper, nothing saved.
    private func applyDemo(_ scene: String) {
        pairing = Pairing(flipperID: UUID(), flipperName: "Flipper", network: 0, ufvk: Demo.ufvk,
                          seedFingerprint: Demo.seedFingerprint, account: 0, birthday: 3_390_000, addressIndex: scene == "receive-next" ? 8 : 7)
        synced = true
        syncProgress = 1
        tipHeight = 3_513_402
        scannedHeight = 3_513_402
        let locked = scene == "home-locked" || scene == "settings-idle"
        flipperState = locked ? .idle : scene == "settings-connecting" ? .approve : .ready
        let after = scene.hasPrefix("after")
        balance = Zatoshi(after ? 14_990_000 : 20_000_000)
        pending = .zero
        change = .zero
        let url = Self.explorerURL(txid: Demo.txid)
        let received = ActivityItem(id: Data([1]), sent: false, zatoshi: 20_000_000, minedHeight: 3_512_960, expired: false,
                                    blockTime: 1_791_640_800, url: url, memos: ["For the Flipper wallet test"])
        let sent = ActivityItem(id: Data([2]), sent: true, zatoshi: 5_000_000, fee: 10_000, minedHeight: 3_513_400, expired: false,
                                blockTime: nil, url: url, memos: ["lunch, thanks!"])
        activity = after ? [sent, received] : [received]
        switch scene {
        case "send-confirm": sendStep = .confirmOnFlipper
        case "send-broadcast": sendStep = .broadcasting
        case "send-sent": sendStep = .sent(Demo.txid)
        default: break
        }
    }

    /// Opens the saved wallet at launch.
    func resume() async {
        guard Demo.scene == nil else { return }
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
    /// the Flipper). Waits as long as it takes for ZFlip to appear.
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
        let server = network.networkType == .testnet ? "testnet.zec.rocks:443" : Self.server
        let parts = server.split(separator: ":")
        let endpoint = LightWalletEndpoint(address: String(parts.first ?? "zec.rocks"),
                                           port: parts.count > 1 ? Int(parts[1]) ?? 443 : 443)
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
            change = b.ironwoodBalance.changePendingConfirmation + b.orchardBalance.changePendingConfirmation
            pending = b.ironwoodBalance.valuePendingSpendability + b.orchardBalance.valuePendingSpendability
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
            var items: [ActivityItem] = []
            for tx in all.sorted(by: { ($0.minedHeight ?? .max, $0.index ?? 0) > ($1.minedHeight ?? .max, $1.index ?? 0) }) {
                let fee = tx.isSentTransaction ? tx.fee?.amount : nil
                let memos = ((try? await synchronizer.getMemos(for: tx)) ?? []).compactMap { $0.toString() }.filter { !$0.isEmpty }
                items.append(ActivityItem(id: tx.rawID, sent: tx.isSentTransaction, zatoshi: abs(tx.value.amount) - (fee ?? 0),
                                          fee: fee, minedHeight: tx.minedHeight, expired: tx.isExpiredUmined == true,
                                          blockTime: tx.blockTime, url: Self.zscanURL(tx), memos: memos))
            }
            self.overviews = Dictionary(all.map { ($0.rawID, $0) }, uniquingKeysWith: { a, _ in a })
            self.activity = items
        }
    }

    /// Who a payment went to (not this wallet's own change).
    func recipients(of item: ActivityItem) async -> [String] {
        if Demo.scene != nil { return item.sent ? [Demo.friend] : [] }
        guard let synchronizer, let tx = overviews[item.id] else { return [] }
        return await synchronizer.getRecipients(for: tx).compactMap {
            if case .address(let r) = $0 { return r.stringEncoded }
            return nil
        }
    }

    /// Confirmations of a mined transaction (nil while in the mempool).
    func confirmations(_ tx: ActivityItem) -> Int? {
        guard let mined = tx.minedHeight, tipHeight >= mined else { return nil }
        return tipHeight - mined + 1
    }

    // MARK: Server and explorer

    /// Mainnet lightwalletd servers to choose from ("host:port").
    static let servers = ["zec.rocks:443", "na.zec.rocks:443", "eu.zec.rocks:443", "ap.zec.rocks:443", "sa.zec.rocks:443"]
    static var server: String {
        UserDefaults.standard.string(forKey: "zapp.server") ?? servers[0]
    }

    /// Restarts the sync on another server (the wallet's data stays).
    func switchServer(to server: String) async {
        let clean = server.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != Self.server else { return }
        UserDefaults.standard.set(clean.contains(":") ? clean : clean + ":443", forKey: "zapp.server")
        synchronizer?.stop()
        synchronizer = nil
        accountUUID = nil
        syncCancellables.removeAll()
        synced = false
        syncError = nil
        await resume()
    }

    /// Transaction pages: "{txid}" is replaced by the transaction id.
    static let explorers: [(name: String, template: String)] = [
        ("ZScan", "https://zscan.cash/tx/{txid}"),
        ("Blockchair", "https://blockchair.com/zcash/transaction/{txid}"),
        ("3xpl", "https://3xpl.com/zcash/transaction/{txid}"),
    ]
    static var explorer: String {
        UserDefaults.standard.string(forKey: "zapp.explorer") ?? explorers[0].template
    }

    /// The transaction on the chosen explorer (txids are shown byte-reversed).
    static func explorerURL(txid: String) -> URL? {
        let template = explorer.contains("{txid}") ? explorer : explorer + "{txid}"
        return URL(string: template.replacingOccurrences(of: "{txid}", with: txid))
    }

    static func zscanURL(_ tx: ZcashTransaction.Overview) -> URL? {
        explorerURL(txid: tx.rawID.reversed().map { String(format: "%02x", $0) }.joined())
    }

    // MARK: Sending

    func validate(address: String) -> Bool {
        (try? Recipient(address, network: networkType)) != nil
    }

    /// Builds the transaction, has the Flipper check and sign it, proves and broadcasts.
    /// One payment: an address and an amount.
    struct Payment: Equatable {
        var address: String
        var zatoshi: Int64
        /// Its own encrypted message (shielded recipients only).
        var memo: String = ""
    }

    /// Most recipients in one transaction. Each adds ~1 KB to what the Flipper must hold in
    /// its RAM to check the transaction; 5 is what has been checked to fit so far.
    static let maxRecipients = 5

    /// The proposal for paying `payments` in one transaction: a plain transfer for one, a
    /// ZIP 321 payment request for several (each recipient gets the memo, if shielded).
    private func propose(_ payments: [Payment], synchronizer: SDKSynchronizer, account: AccountUUID) async throws -> Proposal {
        if payments.count == 1, let p = payments.first {
            return try await synchronizer.proposeTransfer(
                accountUUID: account,
                recipient: try Recipient(p.address, network: networkType),
                amount: Zatoshi(p.zatoshi),
                memo: p.memo.isEmpty ? nil : try Memo(string: p.memo)
            )
        }
        return try await synchronizer.proposefulfillingPaymentURI(Self.paymentURI(payments), accountUUID: account)
    }

    /// ZIP 321: zcash:?address=…&amount=…&memo=…&address.1=…&amount.1=…
    static func paymentURI(_ payments: [Payment]) -> String {
        var params: [String] = []
        for (i, p) in payments.enumerated() {
            let suffix = i == 0 ? "" : ".\(i)"
            params.append("address\(suffix)=\(p.address)")
            params.append("amount\(suffix)=\(decimalZEC(p.zatoshi))")
            if !p.memo.isEmpty, !p.address.hasPrefix("t") {
                let memo64 = Data(p.memo.utf8).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                params.append("memo\(suffix)=\(memo64)")
            }
        }
        return "zcash:?" + params.joined(separator: "&")
    }

    /// 12345 zatoshis → "0.00012345" (no trailing zeros, no exponent).
    static func decimalZEC(_ z: Int64) -> String {
        var frac = String(format: "%08lld", z % 100_000_000)
        while frac.hasSuffix("0") { frac.removeLast() }
        return "\(z / 100_000_000)" + (frac.isEmpty ? "" : ".\(frac)")
    }

    func send(to address: String, zatoshi: Int64, memo: String) async {
        await send([Payment(address: address, zatoshi: zatoshi, memo: memo)])
    }

    /// Builds the transaction, has the Flipper check and sign it (one signature, however many
    /// recipients), proves and broadcasts.
    func send(_ payments: [Payment]) async {
        guard let synchronizer, let accountUUID, let pairing else { return }
        sendStep = .preparing
        do {
            let proposal = try await propose(payments, synchronizer: synchronizer, account: accountUUID)
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
            sendStep = .failed(Self.explain(error, zatoshi: payments.reduce(0) { $0 + $1.zatoshi }))
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
        await proposalFee([Payment(address: address, zatoshi: zatoshi)])
    }

    func proposalFee(_ payments: [Payment]) async -> Zatoshi? {
        guard let synchronizer, let accountUUID, payments.allSatisfy({ validate(address: $0.address) }) else { return nil }
        let proposal = try? await propose(payments.map { Payment(address: $0.address, zatoshi: $0.zatoshi) }, synchronizer: synchronizer, account: accountUUID)
        return proposal?.totalFeeRequired()
    }
}

extension Zatoshi {
    /// The amount alone ("1.2345"), for next to the ZEC symbol.
    var zecAmount: String {
        String(zecString.dropLast(4))
    }

    /// "1.2345 ZEC" style: at most 5 decimals (0.00001 ZEC), trailing zeros trimmed.
    var zecString: String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 5
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
