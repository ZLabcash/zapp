import SwiftUI

/// Connect a Kindle running KindleWallet: scan the QR code it shows, connect over Wi-Fi with
/// the code's one-time key, the Kindle asks its user, then its viewing key comes back.
struct KindlePairView: View {
    @EnvironmentObject var wallet: WalletModel
    @EnvironmentObject var kindle: KindleLink
    /// Called once the Kindle's wallet is added.
    var onDone: (() -> Void)? = nil

    enum Step: Equatable {
        case intro
        case connecting(String)
        case approve
        case birthday(FlipperProtocol.Info)
        case creating
    }

    @State private var step = Step.intro
    @State private var scanning = false
    @State private var error: String?
    @State private var endpoint: KindleEndpoint?
    @State private var restoredFrom = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            KindleStage(step: stage)
                .frame(height: 240)
                .animation(.easeInOut(duration: 0.4), value: stage)
            Text(headline)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
            if let detail {
                Text(detail)
                    .font(.subheadline).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            Spacer()
            content
        }
        .padding(20)
        .background(Theme.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.3), value: step)
        .onChange(of: kindle.awaitingUser) { _, waiting in
            if waiting, case .connecting = step { step = .approve }
        }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                Group {
                    if QRScanner.available {
                        ScannerScreen(title: "Scan the QR code on your Kindle") { text in
                            scanning = false
                            Task { await pair(text) }
                        }
                    } else {
                        Text("The camera isn't available. Allow it for ZApp in Settings.")
                            .multilineTextAlignment(.center).padding()
                    }
                }
                .navigationTitle("Kindle")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { scanning = false } }
            }
        }
    }

    private var stage: KindleStage.Step {
        switch step {
        case .intro: return .idle
        case .connecting: return .link
        case .approve: return .approve
        case .birthday, .creating: return .done
        }
    }

    private var headline: String {
        switch step {
        case .intro: return String(localized: "Connect your Kindle")
        case .connecting(let name): return name
        case .approve: return String(localized: "Approve on your Kindle")
        case .birthday: return String(localized: "When was this wallet made?")
        case .creating: return String(localized: "Setting up your wallet…")
        }
    }

    private var detail: String? {
        switch step {
        case .intro: return String(localized: "Open KindleWallet on your Kindle and show its pairing QR code. Both devices must be on the same Wi-Fi.")
        case .connecting: return String(localized: "Connecting over your Wi-Fi…")
        case .approve: return String(localized: "This phone will see the wallet, never spend.")
        case .birthday: return String(localized: "Its funds are looked for from that date.")
        case .creating: return nil
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .intro:
            Button { error = nil; scanning = true } label: {
                Label("Scan the QR code", systemImage: "qrcode.viewfinder").primaryButton()
            }
        case .connecting, .approve, .creating:
            EmptyView()
        case .birthday(let info):
            VStack(spacing: 14) {
                DatePicker("Created around", selection: $restoredFrom, in: ...Date(), displayedComponents: .date)
                    .card()
                Button { Task { await create(info, restoredFrom: restoredFrom) } } label: {
                    Text("Continue").primaryButton()
                }
            }
        }
    }

    private func pair(_ text: String) async {
        guard let (found, psk) = KindleEndpoint.parse(text) else {
            error = String(localized: "This isn't a KindleWallet pairing code.")
            return
        }
        error = nil
        endpoint = found
        step = .connecting(found.name)
        do {
            // The first connection uses the code's one-time key; the Kindle then remembers this phone.
            try await kindle.connect(found, psk: psk, timeout: 25)
            let info = try await wallet.requestInfo(adding: true, from: kindle)
            // A restored seed has no creation date: ask, unless this phone already has the wallet.
            if info.createdAt == 0, !wallet.wallets.contains(where: { $0.ufvk == info.ufvk }) {
                step = .birthday(info)
            } else {
                await create(info, restoredFrom: nil)
            }
        } catch {
            self.error = error.localizedDescription
            kindle.disconnect()
            step = .intro
        }
    }

    private func create(_ info: FlipperProtocol.Info, restoredFrom: Date?) async {
        guard let endpoint else { return }
        step = .creating
        do {
            try await wallet.createWallet(info: info, flipperID: UUID(), restoredFrom: restoredFrom, kindle: endpoint)
            onDone?()
        } catch {
            self.error = error.localizedDescription
            kindle.disconnect()
            step = .intro
        }
    }
}

/// The Kindle pairing animation: dots running between the phone and the Kindle while
/// connecting, a ring breathing around the Kindle while it waits for its user, and the
/// shield drawing itself when it's done.
struct KindleStage: View {
    enum Step: Equatable { case idle, link, approve, done }
    let step: Step

    var body: some View {
        TimelineView(.animation(paused: step == .idle || step == .done)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                switch step {
                case .idle:
                    KindleIcon().frame(width: 120, height: 160)
                case .link:
                    HStack(spacing: 14) {
                        Image(systemName: "iphone.gen3").font(.system(size: 54, weight: .light))
                        HStack(spacing: 8) {
                            ForEach(0..<5) { i in
                                let lit = Int(t * 6) % 5 == i
                                Circle().fill(Theme.zcash)
                                    .frame(width: 8, height: 8)
                                    .opacity(lit ? 1 : 0.25)
                                    .scaleEffect(lit ? 1.4 : 1)
                            }
                        }
                        KindleIcon().frame(width: 66, height: 88)
                    }
                case .approve:
                    Circle()
                        .stroke(Theme.zcash.opacity(0.35), lineWidth: 2)
                        .frame(width: 230, height: 230)
                        .scaleEffect(1 + 0.04 * sin(t * 3))
                    KindleIcon().frame(width: 120, height: 160)
                case .done:
                    ForgingShield().frame(width: 120, height: 120)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}
