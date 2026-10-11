import SwiftUI

/// Connect a Flipper Zero: find it over Bluetooth, pair, get its viewing key. Each step is
/// an animation around the Flipper with one short line, not a block of text.
struct PairView: View {
    @EnvironmentObject var wallet: WalletModel
    @EnvironmentObject var link: FlipperLink
    /// Called once the Flipper's wallet is added.
    var onDone: (() -> Void)? = nil

    enum Step: Equatable {
        case intro
        case scan
        case connecting(String)
        case approve
        case birthday(FlipperProtocol.Info)
        case creating
    }

    @State private var step = Step.intro
    @State private var error: String?
    @State private var flipperID: UUID?
    @State private var restoredFrom = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            PairingStage(step: stage)
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
        .onAppear(perform: startScan)
        .onDisappear { link.stopScan() }
        .onChange(of: link.found) { _, found in
            // One ZFlip in range: connect to it straight away.
            if step == .scan, found.count == 1, let only = found.first {
                Task { await pair(only) }
            }
        }
        .onChange(of: link.awaitingFlipper) { _, waiting in
            if waiting, case .connecting = step { step = .approve }
        }
    }

    private var stage: PairingStage.Step {
        switch step {
        case .intro: return error == nil ? .scan : .idle
        case .scan: return .scan
        case .connecting: return .link
        case .approve: return .approve
        case .birthday, .creating: return .done
        }
    }

    private var headline: String {
        switch step {
        case .intro: return String(localized: "Connect your Flipper Zero")
        case .scan: return String(localized: "Searching…")
        case .connecting(let name): return name
        case .approve: return String(localized: "Press OK on your Flipper")
        case .birthday: return String(localized: "When was this wallet made?")
        case .creating: return String(localized: "Setting up your wallet…")
        }
    }

    private var detail: String? {
        switch step {
        case .intro, .scan: return String(localized: "Open ZFlip on the Flipper and unlock it.")
        case .connecting: return String(localized: "If asked, type the code shown on the Flipper.")
        case .approve: return String(localized: "This phone will see the wallet, never spend.")
        case .birthday: return String(localized: "Its funds are looked for from that date.")
        case .creating: return nil
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .intro:
            Button(action: startScan) {
                Label("Search again", systemImage: "arrow.clockwise").primaryButton()
            }
        case .scan:
            VStack(spacing: 10) {
                if link.state == .off {
                    Text("Turn on Bluetooth and allow ZApp to use it.").font(.footnote).foregroundStyle(.orange)
                }
                // Several ZFlips in range: pick one.
                if link.found.count > 1 {
                    ForEach(link.found) { flipper in
                        Button { Task { await pair(flipper) } } label: {
                            OptionCard(title: LocalizedStringKey(flipper.name)) {
                                FlipperZeroIcon(light: .green, pulsing: false).frame(width: 52)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
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

    private func startScan() {
        guard step == .intro else { return }
        error = nil
        step = .scan
        link.scan()
    }

    private func pair(_ flipper: FlipperLink.Found) async {
        error = nil
        flipperID = flipper.id
        link.stopScan()
        step = .connecting(flipper.name)
        do {
            try await link.connect(flipper.id, timeout: 25)
            let info = try await wallet.requestInfo(adding: true)
            // A restored seed has no creation date: ask, unless this phone already has the wallet.
            if info.createdAt == 0, !wallet.wallets.contains(where: { $0.ufvk == info.ufvk }) {
                step = .birthday(info)
            } else {
                await create(info, restoredFrom: nil)
            }
        } catch {
            self.error = error.localizedDescription
            link.disconnect()
            step = .intro
        }
    }

    private func create(_ info: FlipperProtocol.Info, restoredFrom: Date?) async {
        guard let flipperID else { return }
        step = .creating
        do {
            try await wallet.createWallet(info: info, flipperID: flipperID, restoredFrom: restoredFrom)
            onDone?()
        } catch {
            self.error = error.localizedDescription
            step = .intro
        }
    }
}

/// The pairing animation: Bluetooth waves sweep out from the Flipper while searching, a
/// stream of dots runs between the phone and the Flipper while connecting, the Flipper's
/// light pulses while it waits for OK, and the shield draws itself when it's done.
struct PairingStage: View {
    enum Step: Equatable { case idle, scan, link, approve, done }
    let step: Step

    var body: some View {
        TimelineView(.animation(paused: step == .idle)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                switch step {
                case .idle:
                    FlipperZeroIcon(light: Color(white: 0.6), pulsing: false).frame(width: 200)
                case .scan:
                    // Three waves, each expanding and fading, a third of a cycle apart.
                    ForEach(0..<3) { i in
                        let phase = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(Theme.zcash, lineWidth: 2)
                            .frame(width: 120 + phase * 220, height: 120 + phase * 220)
                            .opacity(0.7 * (1 - phase))
                    }
                    FlipperZeroIcon(light: .blue, pulsing: sin(t * 4) > 0).frame(width: 200)
                    BluetoothGlyph()
                        .foregroundStyle(Theme.zcash)
                        .frame(width: 14, height: 24)
                        .offset(y: -78)
                case .link:
                    HStack(spacing: 10) {
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
                        FlipperZeroIcon(light: .blue, pulsing: false).frame(width: 150)
                    }
                case .approve:
                    Circle()
                        .stroke(Theme.zcash.opacity(0.35), lineWidth: 2)
                        .frame(width: 250, height: 250)
                        .scaleEffect(1 + 0.04 * sin(t * 3))
                    FlipperZeroIcon(light: .green, pulsing: sin(t * 5) > 0).frame(width: 200)
                    Text(verbatim: "OK")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.zcash).clipShape(Capsule())
                        .offset(x: 59, y: -58 - 5 * abs(sin(t * 3)))
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
