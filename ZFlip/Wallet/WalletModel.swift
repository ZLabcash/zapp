import Combine
import Foundation
import Network
import ZcashLightClientKit

/// The phone's Zcash wallets, one active at a time, all synced together (one SDK database,
/// one account each).
///
/// - A Flipper wallet is watch-only here: the phone syncs, builds transactions as PCZTs and
///   proves them; the Flipper checks and signs.
/// - A phone wallet keeps its recovery phrase in the Keychain (Face ID) and signs here.
@MainActor
final class WalletModel: ObservableObject {
    /// One wallet (persisted). The name stays `Pairing` from when the app had one Flipper:
    /// a Flipper wallet is still one, a phone wallet has `kind == .phone`.
    struct Pairing: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case flipper, phone, multisig }

        /// Wallets saved before multi-wallet support have none: their id is the Flipper's.
        var walletID: UUID?
        var kind: Kind?
        var name: String?
        var flipperID: UUID
        var flipperName: String
        var network: UInt8
        var ufvk: String
        var seedFingerprint: [UInt8]
        var account: UInt32
        var birthday: Int
        /// The receiving address index last shown on the Flipper (or here, for a phone wallet).
        var addressIndex: UInt32?

        var id: UUID { walletID ?? flipperID }
        var isFlipper: Bool { (kind ?? .flipper) == .flipper }
        var isPhone: Bool { kind == .phone }
        var displayName: String { name ?? flipperName }
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
        /// Signed by the Flipper with no network: kept in Activity until broadcast or discarded.
        case signedOffline
        case sent(String)
        case failed(String)
    }

    /// The active wallet, and all of them.
    @Published private(set) var pairing: Pairing?
    @Published private(set) var wallets: [Pairing] = []
    /// Each wallet's balance (spendable + own change), for the wallet list.
    @Published private(set) var balances: [UUID: Zatoshi] = [:]
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

    /// A transaction the Flipper signed while there was no network. It stays here, out of the
    /// SDK's database (which would resubmit it on its own), until the user broadcasts or
    /// discards it.
    struct PendingBroadcast: Codable, Identifiable, Equatable {
        var id = UUID()
        var created: Date
        var payments: [Payment]
        /// Past this height the network refuses it (it was built to expire 40 blocks on).
        var expiryHeight: Int
        var proofs: Data
        var sigs: Data
        /// Saved since multi-wallet: whose payment it is, its fee, who signed it, and the
        /// height it was signed at (for the time left when the phone has no network).
        var walletID: UUID?
        var fee: Int64?
        var signer: String?
        var signedHeight: Int?
        var total: Int64 { payments.reduce(0) { $0 + $1.zatoshi } }
        /// About when it expires (75 s a block from signing), for when no new block is seen.
        var deadline: Date {
            created.addingTimeInterval(Double(expiryHeight - (signedHeight ?? expiryHeight - 40)) * 75)
        }
    }

    /// The active wallet's signed payments waiting for a decision.
    var pendingHere: [PendingBroadcast] {
        pendingBroadcasts.filter { $0.walletID == nil || $0.walletID == pairing?.id }
    }

    @Published private(set) var pendingBroadcasts: [PendingBroadcast] = []
    /// Settings: broadcast as soon as the Flipper signs (on), or keep every signed payment
    /// for the user to broadcast or discard (off).
    static let autoBroadcastKey = "zapp.autoBroadcast"
    /// The phone has a route to the internet (NWPathMonitor).
    @Published private(set) var online = true
    private let pathMonitor = NWPathMonitor()

    func expired(_ p: PendingBroadcast) -> Bool {
        (tipHeight > 0 && tipHeight >= p.expiryHeight) || Date() > p.deadline.addingTimeInterval(10 * 60)
    }

    /// Roughly how long until it expires: from the chain when blocks keep coming, else from
    /// the clock (offline, the last height seen goes stale).
    func minutesLeft(_ p: PendingBroadcast) -> Int? {
        let byClock = Int(p.deadline.timeIntervalSinceNow / 60)
        guard tipHeight > 0, online else { return max(0, byClock) }
        return max(0, min((p.expiryHeight - tipHeight) * 75 / 60, byClock + 10))
    }

    /// Seconds left to broadcast, by the clock, pulled in if the chain is ahead of it.
    func secondsLeft(_ p: PendingBroadcast) -> Int {
        let byClock = Int(p.deadline.timeIntervalSinceNow)
        guard tipHeight > 0, online else { return max(0, byClock) }
        return max(0, min(byClock, (p.expiryHeight - tipHeight) * 75))
    }

    /// Share of its broadcast window still left (1 just signed, 0 expired).
    func windowLeft(_ p: PendingBroadcast) -> Double {
        let total = p.deadline.timeIntervalSince(p.created)
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(secondsLeft(p)) / total))
    }

    /// Whether the lightwalletd server answers now (an internet route isn't enough:
    /// a Wi-Fi without internet, a captive portal…).
    func serverReachable() async -> Bool {
        guard online, let synchronizer else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await synchronizer.latestHeight()) != nil }
            group.addTask {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static func pendingFile(_ network: NetworkType) throws -> URL {
        try dataDirectory(network).deletingLastPathComponent()
            .appendingPathComponent("zapp-pending-\(network == .testnet ? "test" : "main").json")
    }

    private func savePending() {
        guard let url = try? Self.pendingFile(networkType) else { return }
        try? JSONEncoder().encode(pendingBroadcasts).write(to: url, options: [.atomic, .completeFileProtection])
    }

    private func loadPending() {
        guard let url = try? Self.pendingFile(networkType), let data = try? Data(contentsOf: url) else { return }
        pendingBroadcasts = (try? JSONDecoder().decode([PendingBroadcast].self, from: data)) ?? []
    }

    /// Hands a signed transaction to the network. Returns an error to show, or nil once sent.
    func broadcast(_ pending: PendingBroadcast) async -> String? {
        guard let synchronizer else { return String(localized: "The wallet isn't open yet.") }
        if expired(pending) { return String(localized: "It expired: the network won't take it any more. Discard it and send again.") }
        guard await serverReachable() else { return String(localized: "The Zcash network can't be reached. It stays saved here: try again when you're back online.") }
        do {
            let error = try await submit(proofs: pending.proofs, sigs: pending.sigs, synchronizer: synchronizer)
            // Created means stored by the SDK, which keeps retrying it: it no longer waits here.
            pendingBroadcasts.removeAll { $0.id == pending.id }
            savePending()
            refreshTransactions(force: true)
            return error
        } catch {
            return error.localizedDescription
        }
    }

    func discard(_ pending: PendingBroadcast) {
        pendingBroadcasts.removeAll { $0.id == pending.id }
        savePending()
    }

    /// Stores and submits a signed, proven transaction; returns the network's error if any.
    private func submit(proofs: Pczt, sigs: Pczt, synchronizer: SDKSynchronizer) async throws -> String? {
        let results = try await synchronizer.createTransactionFromPCZT(pcztWithProofs: proofs, pcztWithSigs: sigs)
        var error: String?
        for try await result in results {
            switch result {
            case .success(let txId):
                sendStep = sendStep == .idle ? .idle : .sent(txId.reversed().map { String(format: "%02x", $0) }.joined())
            case .grpcFailure(_, let e):
                error = "Couldn't reach the network (\(e.localizedDescription)). The wallet will retry on its own."
            case .submitFailure(_, _, let description):
                error = description
            case .notAttempted:
                error = "The transaction was not submitted."
            }
        }
        return error
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
    /// The Flipper wallet whose Flipper is connected with a session open. The link stays up
    /// while switching wallets (only leaving the app closes it), so switching back is instant.
    @Published private(set) var linkedWallet: UUID?
    /// Amounts show only while the Flipper is connected: a glance at the phone
    /// alone gives nothing away. (Privacy from onlookers, not security: the viewing
    /// key is on the phone.)
    var showsAmounts: Bool { pairing?.isPhone == true || flipperReady }
    /// This wallet can sign now: a phone wallet always (Face ID), a Flipper wallet when connected.
    var canSign: Bool { pairing?.isPhone == true || flipperReady }
    /// INFO from a Flipper holding another wallet, kept to adopt it on request.
    private var otherWallet: (info: FlipperProtocol.Info, id: UUID)?

    let link: FlipperLink
    private var synchronizer: SDKSynchronizer?
    private var accountUUID: AccountUUID?
    private var cancellables = Set<AnyCancellable>()
    /// The synchronizer's subscriptions (reset when the wallet is replaced).
    private var syncCancellables = Set<AnyCancellable>()

    private static let pairingKey = "zflip.pairing"
    private static let walletsKey = "zapp.wallets"
    private static let activeKey = "zapp.activeWallet"
    /// SDK account of each wallet, found or imported when the database opens.
    private var accounts: [UUID: AccountUUID] = [:]
    private var lastState: SynchronizerState?
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
                    self.linkedWallet = nil
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
        loadWallets()
        loadPending()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.online = up }
        }
        pathMonitor.start(queue: DispatchQueue(label: "zapp.network"))
    }

    var networkType: NetworkType {
        pairing?.network == 1 ? .testnet : .mainnet
    }

    // MARK: Pairing

    /// Asks the connected Flipper for its viewing key (the user approves on the Flipper).
    /// The Flipper's INFO. `adding`: it's being added as a wallet (Add a wallet → Connect a
    /// device), so whatever wallet it holds is welcome; otherwise it must hold the active one.
    func requestInfo(adding: Bool = false) async throws -> FlipperProtocol.Info {
        let reply = try await link.request(.hello)
        guard reply.kind == FlipperProtocol.Kind.info.rawValue else {
            throw FlipperError.protocolError("Unexpected reply from the Flipper")
        }
        let info = try FlipperProtocol.Info(reply.payload)
        if adding { return info }
        if let pairing, info.ufvk != pairing.ufvk {
            // A wallet this phone already has: switch to it.
            if let known = wallets.first(where: { $0.ufvk == info.ufvk }) {
                try await activate(known.id)
            } else {
                otherWallet = (info, pairing.flipperID)
                flipperState = .otherWallet(info.deviceName)
                throw FlipperError.rejected(String(localized: "This Flipper holds another wallet."))
            }
        }
        flipperState = .ready
        linkedWallet = pairing?.id
        if pairing != nil {
            remember(index: info.addressIndex)
            await repairBirthday(info)
        }
        return info
    }

    /// Creates the watch-only wallet for a Flipper. `restoredFrom` is the date to
    /// scan from when the Flipper's seed was restored rather than created on it.
    func createWallet(info: FlipperProtocol.Info, flipperID: UUID, restoredFrom: Date?) async throws {
        let synchronizer = try await database()
        let birthday = Self.birthday(for: info, restoredFrom: restoredFrom, synchronizer: synchronizer)
        // A Flipper wallet this phone already has: switch to it, keeping its history.
        if var known = wallets.first(where: { $0.isFlipper && $0.ufvk == info.ufvk }) {
            known.flipperID = flipperID
            known.flipperName = info.deviceName
            store(known)
            try await activate(known.id, keepingLink: true)
            flipperState = .ready
            linkedWallet = pairing?.id
            remember(index: info.addressIndex)
            return
        }
        let pairing = Pairing(
            walletID: UUID(),
            kind: .flipper,
            name: info.deviceName,
            flipperID: flipperID,
            flipperName: info.deviceName,
            network: info.network,
            ufvk: info.ufvk,
            seedFingerprint: info.seedFingerprint,
            account: info.account,
            birthday: birthday,
            addressIndex: info.addressIndex
        )
        try await add(pairing, keepingLink: true)
        flipperState = .ready
        linkedWallet = self.pairing?.id
    }

    // MARK: Wallets

    private func loadWallets() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.walletsKey), let list = try? JSONDecoder().decode([Pairing].self, from: data) {
            wallets = list
        } else if let data = d.data(forKey: Self.pairingKey), let legacy = try? JSONDecoder().decode(Pairing.self, from: data) {
            wallets = [legacy] // the single Flipper wallet of earlier versions
        }
        let active = d.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        pairing = wallets.first { $0.id == active } ?? wallets.first
        saveWallets()
    }

    private func saveWallets() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(wallets), forKey: Self.walletsKey)
        d.set(pairing?.id.uuidString, forKey: Self.activeKey)
        d.removeObject(forKey: Self.pairingKey)
    }

    private func store(_ wallet: Pairing) {
        if let i = wallets.firstIndex(where: { $0.id == wallet.id }) { wallets[i] = wallet } else { wallets.append(wallet) }
        if pairing?.id == wallet.id { pairing = wallet }
        saveWallets()
    }

    /// The shared database, opened (and syncing) if it isn't yet.
    private func database() async throws -> SDKSynchronizer {
        if let synchronizer { return synchronizer }
        let network = ZcashNetworkBuilder.network(for: networkType)
        let synchronizer = try makeSynchronizer(network: network)
        let birthday = wallets.map(\.birthday).min() ?? synchronizer.estimateBirthdayHeight(for: Date())
        _ = try await synchronizer.prepare(with: nil, walletBirthday: birthday, name: "ZApp", keySource: "zapp")
        self.synchronizer = synchronizer
        synchronizer.stateStream
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.update(state) }
            .store(in: &syncCancellables)
        try await synchronizer.start(retry: true)
        return synchronizer
    }

    /// This wallet's SDK account: found by its viewing key, or imported.
    private func account(for wallet: Pairing, in synchronizer: SDKSynchronizer) async throws -> AccountUUID {
        if let id = accounts[wallet.id] { return id }
        if let found = try await synchronizer.listAccounts().first(where: { $0.ufvk?.stringEncoded == wallet.ufvk }) {
            accounts[wallet.id] = found.id
            return found.id
        }
        // "spending" with the seed fingerprint and ZIP 32 index: the SDK then stamps PCZT
        // spends with the derivation path an external signer needs.
        let id = try await synchronizer.importAccount(
            ufvk: wallet.ufvk,
            seedFingerprint: wallet.seedFingerprint,
            zip32AccountIndex: Zip32AccountIndex(wallet.account),
            purpose: .spending,
            name: wallet.displayName,
            keySource: wallet.isPhone ? "zapp" : "zflip",
            birthday: wallet.birthday
        )
        accounts[wallet.id] = id
        return id
    }

    /// Adds a wallet and makes it the active one.
    func add(_ wallet: Pairing, keepingLink: Bool = false) async throws {
        let synchronizer = try await database()
        _ = try await account(for: wallet, in: synchronizer)
        store(wallet)
        try await activate(wallet.id, keepingLink: keepingLink)
    }

    /// Switches the app to another wallet: balance, activity, addresses, signing device.
    /// `keepingLink`: the Flipper just connected is the new wallet's own, so stay connected.
    func activate(_ id: UUID, keepingLink: Bool = false) async throws {
        guard let wallet = wallets.first(where: { $0.id == id }) else { return }
        // The Bluetooth link stays up across switches. Back on the connected Flipper's
        // wallet: ready at once. Another Flipper wallet: its own Flipper must connect.
        if !keepingLink, pairing?.id != id {
            if wallet.isFlipper, linkedWallet == wallet.id, link.isConnected {
                flipperState = .ready
            } else if wallet.isFlipper {
                let linked = wallets.first { $0.id == linkedWallet }
                if link.isConnected, linked?.flipperID != wallet.flipperID { link.disconnect() }
                flipperState = .idle
            }
        }
        pairing = wallet
        saveWallets()
        let synchronizer = try await database()
        accountUUID = try await account(for: wallet, in: synchronizer)
        address = try? await synchronizer.getUnifiedAddress(accountUUID: accountUUID!).stringEncoded
        activity = []
        if let lastState { update(lastState) }
        refreshTransactions(force: true)
    }

    /// Removes a wallet from this phone (its account, and its recovery phrase for a phone
    /// wallet). Funds stay on the chain: the words or the Flipper restore it.
    func remove(_ id: UUID, keepingDatabase: Bool = false) async {
        if let synchronizer, let account = accounts[id] {
            try? await synchronizer.deleteAccount(account)
        }
        accounts[id] = nil
        SeedVault.delete(id)
        wallets.removeAll { $0.id == id }
        balances[id] = nil
        if pairing?.id == id {
            // Straight to the next wallet, without passing through the welcome screen.
            if !keepingDatabase, let next = wallets.first {
                try? await activate(next.id)
                return
            }
            pairing = nil
            accountUUID = nil
            if keepingDatabase { saveWallets(); return }
            await tearDown()
            link.disconnect()
            flipperState = .idle
        }
        saveWallets()
    }

    func rename(_ id: UUID, to name: String) {
        guard var w = wallets.first(where: { $0.id == id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        w.name = clean.isEmpty ? nil : clean
        store(w)
    }

    // MARK: Phone wallets (keys on this phone)

    /// A fresh 24-word recovery phrase from the system's secure random generator.
    static func newRecoveryPhrase() throws -> String {
        var entropy = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &entropy) == errSecSuccess else {
            throw Bridge.Failure(message: String(localized: "This phone couldn't produce random numbers."))
        }
        defer { entropy.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, 32) } }
        return try Bridge.mnemonicNew(entropy: entropy)
    }

    /// Creates (new phrase, `since` nil: starts at today's block) or restores a phone wallet.
    func addPhoneWallet(name: String, phrase: String, since: Date?) async throws {
        let seed = try Bridge.mnemonicSeed(phrase)
        let tool = DerivationTool(networkType: networkType)
        let usk = try tool.deriveUnifiedSpendingKey(seed: seed, accountIndex: Zip32AccountIndex(0))
        let ufvk = try tool.deriveUnifiedFullViewingKey(from: usk).stringEncoded
        let fingerprint = try Bridge.seedFingerprint(seed)
        if wallets.contains(where: { $0.ufvk == ufvk }) {
            throw Bridge.Failure(message: String(localized: "This wallet is already on this phone."))
        }
        let synchronizer = try await database()
        let birthday = since.map { max(synchronizer.estimateBirthdayHeight(for: $0.addingTimeInterval(-86_400)), Self.nu5Height(networkType)) }
            ?? max(tipHeight, synchronizer.estimateBirthdayHeight(for: Date()))
        let id = UUID()
        try SeedVault.save(Bridge.normalized(phrase), for: id)
        let wallet = Pairing(walletID: id, kind: .phone, name: name, flipperID: id, flipperName: name, network: 0,
                             ufvk: ufvk, seedFingerprint: fingerprint, account: 0, birthday: birthday, addressIndex: 0)
        do {
            try await add(wallet)
        } catch {
            SeedVault.delete(id)
            throw error
        }
    }

    /// Derives the next ZIP-32 account of a phone wallet's seed as a new wallet (the same 24 words,
    /// account index + 1 — as MetaMask adds accounts from one recovery phrase).
    func addAccount(from parent: Pairing) async throws {
        guard parent.isPhone else { throw Bridge.Failure(message: String(localized: "This wallet's words are on its device.")) }
        let phrase = try SeedVault.read(parent.id, reason: String(localized: "Add an account"))
        let seed = try Bridge.mnemonicSeed(phrase)
        let fingerprint = try Bridge.seedFingerprint(seed)
        // The next free account index across every wallet sharing this seed.
        let kin = wallets.filter { $0.isPhone && $0.seedFingerprint == fingerprint }
        let nextAccount = (kin.map { $0.account }.max() ?? 0) + 1
        let tool = DerivationTool(networkType: networkType)
        let usk = try tool.deriveUnifiedSpendingKey(seed: seed, accountIndex: Zip32AccountIndex(nextAccount))
        let ufvk = try tool.deriveUnifiedFullViewingKey(from: usk).stringEncoded
        if wallets.contains(where: { $0.ufvk == ufvk }) {
            throw Bridge.Failure(message: String(localized: "This account already exists on this phone."))
        }
        let id = UUID()
        try SeedVault.save(Bridge.normalized(phrase), for: id)
        // Found from the seed's birthday, so earlier funds on this account are picked up.
        let name = String(localized: "Account \(Int(nextAccount) + 1)")
        let wallet = Pairing(walletID: id, kind: .phone, name: name, flipperID: id, flipperName: name, network: parent.network,
                             ufvk: ufvk, seedFingerprint: fingerprint, account: nextAccount, birthday: parent.birthday, addressIndex: 0)
        do {
            try await add(wallet)
        } catch {
            SeedVault.delete(id)
            throw error
        }
    }

    /// The active phone wallet's words, after Face ID.
    func recoveryPhrase() throws -> String {
        guard let pairing, pairing.isPhone else { throw Bridge.Failure(message: String(localized: "This wallet's words are on its device.")) }
        return try SeedVault.read(pairing.id, reason: String(localized: "Show your recovery phrase"))
    }

    /// A phone wallet's next receiving address (any number of them, all unlinkable).
    func newPhoneAddress() {
        guard var w = pairing, w.isPhone else { return }
        w.addressIndex = (w.addressIndex ?? 0) + 1
        store(w)
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
        accounts = [:]
        lastState = nil
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

    /// Opens the saved wallets at launch.
    func resume() async {
        guard var pairing, synchronizer == nil else { return }
        do {
            // A single Flipper wallet paired before the birthday fix (a Flipper clock that was
            // never set) starts before NU5: start it from ZFlip's first day, on a fresh database.
            if wallets.count == 1, pairing.isFlipper, pairing.birthday <= Self.nu5Height(networkType) {
                try? FileManager.default.removeItem(at: try Self.dataDirectory(networkType))
                let probe = try makeSynchronizer(network: ZcashNetworkBuilder.network(for: networkType))
                pairing.birthday = probe.estimateBirthdayHeight(for: Self.zflipEpoch.addingTimeInterval(-86_400))
                store(pairing)
            }
            try await activate(pairing.id)
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Syncs while the app is in the background (see BackgroundSync): opens the wallet if
    /// it isn't yet, then waits until it's up to date. False if time ran out first.
    func syncInBackground() async -> Bool {
        guard !wallets.isEmpty else { return true }
        if synchronizer == nil { await resume() }
        guard let synchronizer else { return false }
        if case .stopped = synchronizer.latestState.syncStatus { try? await synchronizer.start(retry: true) }
        // "Up to date" may be from before the wake-up: give the next sync pass a moment.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        while !synced && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return synced
    }

    /// Connects to the paired Flipper and opens a session (the user presses OK on
    /// the Flipper). Waits as long as it takes for ZFlip to appear.
    /// "Connect to Flipper": connects and opens a session (OK on the Flipper).
    func connectFlipper() async {
        guard let pairing, pairing.isFlipper, !flipperReady else { return }
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
            linkedWallet = pairing?.id
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
        store(p)
    }

    /// The receiving address the Flipper shows (or showed last).
    var receiveIndex: UInt32 { pairing?.addressIndex ?? 0 }

    /// The diversified address at `index` (index 0 is the wallet's default).
    func address(at index: UInt32) -> String? {
        guard let ufvk = pairing?.ufvk else { return nil }
        return try? Bridge.address(ufvk: ufvk, index: index)
    }

    /// A wallet's current receiving address (to send to it from another wallet).
    func receivingAddress(of w: Pairing) -> String? {
        try? Bridge.address(ufvk: w.ufvk, index: w.addressIndex ?? 0)
    }

    /// The name of the wallet on this phone that `address` belongs to (any of the addresses
    /// it has shown), so a payment between your own wallets reads by name.
    func walletName(for address: String) -> String? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard a.count > 20 else { return nil }
        if ownAddressesFor != wallets {
            ownAddresses = [:]
            for w in wallets {
                for i in 0...(w.addressIndex ?? 0) {
                    if let addr = try? Bridge.address(ufvk: w.ufvk, index: i) { ownAddresses[addr] = w.id }
                }
            }
            ownAddressesFor = wallets
        }
        return ownAddresses[a].flatMap { id in wallets.first { $0.id == id }?.displayName }
    }
    private var ownAddresses: [String: UUID] = [:]
    private var ownAddressesFor: [Pairing] = []

    /// Removes the active wallet.
    func forget() async {
        guard let pairing else { return }
        await remove(pairing.id)
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

    private func update(_ state: SynchronizerState) {
        lastState = state
        for (wallet, account) in accounts {
            if let b = state.accountsBalances[account] {
                balances[wallet] = b.ironwoodBalance.spendableValue + b.orchardBalance.spendableValue
                    + b.ironwoodBalance.changePendingConfirmation + b.orchardBalance.changePendingConfirmation
            }
        }
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
            for tx in all.filter({ $0.accountUUID == self.accountUUID }).sorted(by: { ($0.minedHeight ?? .max, $0.index ?? 0) > ($1.minedHeight ?? .max, $1.index ?? 0) }) {
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
    struct Payment: Equatable, Codable {
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
            if pairing.isPhone {
                // Keys on this phone: Face ID unlocks them, the SDK proves, signs and sends.
                let phrase = try SeedVault.read(pairing.id, reason: String(localized: "Sign this payment"))
                let tool = DerivationTool(networkType: networkType)
                let usk = try tool.deriveUnifiedSpendingKey(seed: try Bridge.mnemonicSeed(phrase), accountIndex: Zip32AccountIndex(pairing.account))
                sendStep = .broadcasting
                let results = try await synchronizer.createProposedTransactions(proposal: proposal, spendingKey: usk)
                var error: String?
                for try await result in results {
                    switch result {
                    case .success(let txId): sendStep = .sent(txId.reversed().map { String(format: "%02x", $0) }.joined())
                    case .grpcFailure(_, let e): error = String(localized: "Couldn't reach the network (\(e.localizedDescription)). The wallet will retry on its own.")
                    case .submitFailure(_, _, let d): error = d
                    case .notAttempted: error = String(localized: "The transaction was not submitted.")
                    }
                }
                if let error { sendStep = .failed(error) }
                refreshTransactions(force: true)
                return
            }
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
            let proofs = try await proven
            let autoBroadcast = UserDefaults.standard.object(forKey: Self.autoBroadcastKey) as? Bool ?? true
            // Signed, but the network can't be reached (or the user decides when): keep it on
            // this phone, outside the wallet database, until broadcast or discarded.
            let reachable = autoBroadcast ? await serverReachable() : false
            if !reachable {
                let fee = proposal.totalFeeRequired().amount
                pendingBroadcasts.append(PendingBroadcast(created: Date(), payments: payments, expiryHeight: tipHeight + 40,
                                                          proofs: proofs, sigs: signed, walletID: pairing.id, fee: fee,
                                                          signer: pairing.flipperName, signedHeight: tipHeight))
                savePending()
                sendStep = .signedOffline
                return
            }
            sendStep = .broadcasting
            if let error = try await submit(proofs: proofs, sigs: signed, synchronizer: synchronizer) {
                sendStep = .failed(error)
            }
            refreshTransactions(force: true)
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
                return String(localized: "Not enough spendable ZEC. Sending \(Zatoshi(zatoshi).zecString) also costs a network fee of at least \(minimumFee.zecString), and received funds become spendable after 10 confirmations.")
            }
            return String(localized: "Could not prepare the transaction: \(detail)")
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
