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
    @Published private(set) var address: String?
    @Published var sendStep = SendStep.idle
    @Published private(set) var flipperState = FlipperState.idle
    /// The Flipper accepted this connection's HELLO (it will take sign requests).
    var flipperReady: Bool { flipperState == .ready }
    /// INFO from a Flipper holding another wallet, kept to adopt it on request.
    private var otherWallet: (info: FlipperProtocol.Info, id: UUID)?

    let link: FlipperLink
    private var synchronizer: SDKSynchronizer?
    private var accountUUID: AccountUUID?
    private var cancellables = Set<AnyCancellable>()
    /// The synchronizer's subscriptions (reset when the wallet is replaced).
    private var syncCancellables = Set<AnyCancellable>()

    private static let pairingKey = "zflip.pairing"

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
        if pairing != nil { remember(index: info.addressIndex) }
        return info
    }

    /// Creates the watch-only wallet for a Flipper. `restoredFrom` is the date to
    /// scan from when the Flipper's seed was restored rather than created on it.
    func createWallet(info: FlipperProtocol.Info, flipperID: UUID, restoredFrom: Date?) async throws {
        let network = ZcashNetworkBuilder.network(for: info.network == 1 ? .testnet : .mainnet)
        let created = info.createdAt > 0 ? Date(timeIntervalSince1970: TimeInterval(info.createdAt)) : nil
        let since = created ?? restoredFrom ?? Date(timeIntervalSince1970: 1_654_041_600) // NU5, June 2022
        let synchronizer = try makeSynchronizer(network: network)
        // A day of margin: the Flipper's clock may be off.
        let birthday = synchronizer.estimateBirthdayHeight(for: since.addingTimeInterval(-86_400))
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

    /// Opens the saved wallet at launch.
    func resume() async {
        guard let pairing, synchronizer == nil else { return }
        do {
            let network = ZcashNetworkBuilder.network(for: networkType)
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
        do {
            if !link.isConnected {
                try await link.connect(pairing.flipperID, timeout: 20)
            }
            _ = try await requestInfo()
        } catch FlipperError.timeout {
            flipperState = .failed("Flipper not found. Open ZFlip on it and unlock it.")
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
        synchronizer?.stop()
        if let synchronizer {
            _ = try? await synchronizer.wipe().values.first(where: { _ in true })
        }
        synchronizer = nil
        accountUUID = nil
        syncCancellables.removeAll()
        address = nil
        balance = .zero
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
        synchronizer?.stop()
        if let synchronizer {
            _ = try? await synchronizer.wipe().values.first(where: { _ in true })
        }
        synchronizer = nil
        accountUUID = nil
        syncCancellables.removeAll()
        flipperState = .idle
        UserDefaults.standard.removeObject(forKey: Self.pairingKey)
        pairing = nil
        address = nil
        balance = .zero
        link.disconnect()
    }

    private func makeSynchronizer(network: ZcashNetwork) throws -> SDKSynchronizer {
        let base = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ZFlip-\(network.networkType == .testnet ? "test" : "main")", isDirectory: true)
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
            sendStep = .failed(error.localizedDescription)
        }
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
