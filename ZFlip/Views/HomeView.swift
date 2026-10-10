import SwiftUI
import ZcashLightClientKit

struct HomeView: View {
    @EnvironmentObject var wallet: WalletModel
    @State private var showReceive = false
    @State private var showSend = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    BalanceCard()
                    HStack(spacing: 12) {
                        ActionTile(title: "Receive", icon: "arrow.down") { showReceive = true }
                        ActionTile(title: "Send", icon: "arrow.up") { showSend = true }
                            .disabled(!wallet.synced || wallet.balance.amount == 0)
                            .opacity(!wallet.synced || wallet.balance.amount == 0 ? 0.45 : 1)
                    }
                    DevicesCard()
                    ActivityCard()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showReceive) { ReceiveView() }
            .sheet(isPresented: $showSend) { SendView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Shield().frame(width: 34, height: 34)
            Text("ZApp").font(.system(size: 28, weight: .heavy, design: .rounded))
            if wallet.pairing?.network == 1 {
                Text("TESTNET").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.orange.opacity(0.25)).clipShape(Capsule())
            }
            Spacer()
            SyncPill()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(Theme.muted)
            }
        }
        .padding(.top, 8)
    }
}

/// The sync state, small, by the settings button: a green dot when up to date, a
/// filling ring while syncing, orange when the server can't be reached. Tap for
/// the block height and the server.
struct SyncPill: View {
    @EnvironmentObject var wallet: WalletModel
    @State private var details = false

    var body: some View {
        Button { details = true } label: {
            HStack(spacing: 6) {
                if wallet.syncError != nil {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                    Text("Offline")
                } else if wallet.synced {
                    Circle().fill(Theme.scan).frame(width: 8, height: 8)
                    Text("Synced")
                } else {
                    Ring(progress: Double(wallet.syncProgress), lineWidth: 2.5).frame(width: 12, height: 12)
                    Text("Syncing \(Int(wallet.syncProgress * 100))%").monospacedDigit()
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.card)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $details) {
            VStack(alignment: .leading, spacing: 8) {
                Text(wallet.synced ? "Up to date" : wallet.syncError == nil ? "Syncing" : "Can't reach the network")
                    .font(.headline)
                if let error = wallet.syncError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
                if wallet.tipHeight > 0 {
                    LabeledContent("Latest block", value: wallet.tipHeight.formatted())
                }
                if !wallet.synced && wallet.scannedHeight > 0 {
                    LabeledContent("Scanned up to", value: wallet.scannedHeight.formatted())
                }
                LabeledContent("Server", value: "zec.rocks")
            }
            .font(.subheadline)
            .padding(18)
            .frame(minWidth: 260)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// A progress ring in the Zcash yellow.
struct Ring: View {
    let progress: Double
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(Theme.zcash, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: progress)
        }
    }
}

/// Incoming ZEC on its way to spendable: a ring filling with confirmations, the
/// amount, and roughly how long until it can be spent (a block every 75 seconds).
struct IncomingRow: View {
    @EnvironmentObject var wallet: WalletModel
    static let needed = 10

    var body: some View {
        let confirmations = currentConfirmations
        HStack(spacing: 14) {
            ZStack {
                Ring(progress: Double(confirmations ?? 0) / Double(Self.needed), lineWidth: 4)
                Text(confirmations.map { "\($0)/\(Self.needed)" } ?? "…")
                    .font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("+\(wallet.pending.zecString) incoming")
                    .font(.subheadline.weight(.semibold))
                Text(detail(confirmations)).font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.zcash.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// The least-confirmed received transaction still under the threshold.
    private var currentConfirmations: Int? {
        let incoming = wallet.transactions.filter { !$0.isSentTransaction && $0.isExpiredUmined != true }
        let waiting = incoming.compactMap { tx -> Int? in
            guard let n = wallet.confirmations(tx) else { return 0 }
            return n < Self.needed ? n : nil
        }
        return waiting.min()
    }

    private func detail(_ n: Int?) -> String {
        guard let n, n > 0 else { return "Waiting for its first block · about 13 min to spendable" }
        let minutes = max(1, ((Self.needed - n) * 75 + 59) / 60)
        return "Spendable in about \(minutes) min · \(n) of \(Self.needed) confirmations"
    }
}

struct BalanceCard: View {
    @EnvironmentObject var wallet: WalletModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Shielded balance", systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.muted)
            HStack(alignment: .center, spacing: 10) {
                Text(wallet.balance.zecAmount)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                ZecLogo().frame(width: 34, height: 34)
            }
            if wallet.pending.amount > 0 {
                IncomingRow()
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Theme.card, Theme.card.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Theme.zcash.opacity(0.25), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

/// The signing devices, each with its name over its picture and a Connect button:
/// the Flipper Zero over Bluetooth, and soon a Kindle over local Wi-Fi.
struct DevicesCard: View {
    @EnvironmentObject var wallet: WalletModel
    @Environment(\.openURL) private var openURL
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Devices").font(.headline)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Flipper Zero").font(.subheadline.weight(.semibold))
                    FlipperZeroIcon(light: light, pulsing: pulsing && pulse).frame(width: 120)
                }
                Spacer()
                flipperButton
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            extraActions
            Divider()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kindle").font(.subheadline.weight(.semibold))
                    KindleIcon().frame(width: 38, height: 50)
                }
                Spacer()
                ConnectPill(title: "Connect", glyph: AnyView(Image(systemName: "wifi").font(.subheadline.weight(.bold))),
                            style: .disabled) {}
                    .disabled(true)
            }
            .opacity(0.45)
        }
        .padding(20)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var pulsing: Bool {
        switch wallet.flipperState {
        case .connecting, .approve: return true
        default: return false
        }
    }

    private var light: Color {
        switch wallet.flipperState {
        case .ready: return Theme.scan
        case .approve, .connecting: return Theme.zcash
        case .otherWallet: return .orange
        case .failed: return .red
        case .idle: return Color.gray
        }
    }

    /// One line, only when there is something to do or know.
    private var note: String? {
        switch wallet.flipperState {
        case .idle, .ready: return nil
        case .connecting: return "Open ZFlip on the Flipper and unlock it, close to this phone."
        case .approve: return "Press OK on your Flipper to share the viewing key (it can see, never spend)."
        case .otherWallet(let flipper): return "\(flipper) holds a different wallet than this phone."
        case .failed(let message): return message
        }
    }

    @ViewBuilder private var flipperButton: some View {
        switch wallet.flipperState {
        case .idle, .failed, .otherWallet:
            ConnectPill(title: "Connect", glyph: AnyView(BluetoothGlyph().frame(width: 10, height: 16)), style: .primary) {
                Task { await wallet.connectFlipper() }
            }
        case .connecting, .approve:
            ConnectPill(title: "Cancel", glyph: AnyView(ProgressView().controlSize(.small)), style: .plain) {
                wallet.disconnectFlipper()
            }
        case .ready:
            ConnectPill(title: "Connected", glyph: AnyView(BluetoothGlyph().frame(width: 10, height: 16)), style: .connected) {
                wallet.disconnectFlipper()
            }
        }
    }

    @ViewBuilder private var extraActions: some View {
        if wallet.bluetoothDenied {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.subheadline.weight(.semibold))
        }
        if case .otherWallet = wallet.flipperState {
            Button { Task { await wallet.adoptFlipperWallet() } } label: {
                Label("Use this Flipper's wallet", systemImage: "arrow.triangle.2.circlepath").primaryButton()
            }
        }
    }
}

/// The Connect button: a capsule with the link's symbol.
struct ConnectPill: View {
    enum Style { case primary, connected, plain, disabled }
    let title: String
    let glyph: AnyView
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                glyph
                Text(title).font(.subheadline.weight(.bold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        switch style {
        case .primary, .connected: return .black
        case .plain, .disabled: return .primary
        }
    }

    private var background: Color {
        switch style {
        case .primary: return Theme.zcash
        case .connected: return Theme.scan
        case .plain, .disabled: return Color.primary.opacity(0.1)
        }
    }
}

/// The Bluetooth rune (SF Symbols has none).
struct BluetoothGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                p.move(to: CGPoint(x: 0, y: h * 0.27))
                p.addLine(to: CGPoint(x: w, y: h * 0.73))
                p.addLine(to: CGPoint(x: w * 0.5, y: h))
                p.addLine(to: CGPoint(x: w * 0.5, y: 0))
                p.addLine(to: CGPoint(x: w, y: h * 0.27))
                p.addLine(to: CGPoint(x: 0, y: h * 0.73))
            }
            .stroke(style: StrokeStyle(lineWidth: max(1.6, w * 0.2), lineCap: .round, lineJoin: .round))
        }
    }
}

/// The Flipper Zero, front view: the white body with its rounded right end, the
/// orange screen, the round d-pad with its OK button, the back button, and the
/// status light (the connection's colour).
struct FlipperZeroIcon: View {
    let light: Color
    let pulsing: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = w * 0.42
            ZStack(alignment: .topLeading) {
                // Body: a long capsule, the d-pad end a little taller, like the device.
                UnevenRoundedRectangle(topLeadingRadius: h * 0.28, bottomLeadingRadius: h * 0.28,
                                       bottomTrailingRadius: h * 0.5, topTrailingRadius: h * 0.5)
                    .fill(Color(white: 0.95))
                    .overlay(
                        UnevenRoundedRectangle(topLeadingRadius: h * 0.28, bottomLeadingRadius: h * 0.28,
                                               bottomTrailingRadius: h * 0.5, topTrailingRadius: h * 0.5)
                            .stroke(Color.black.opacity(0.25), lineWidth: 1)
                    )
                    .frame(width: w, height: h)
                // Screen bezel and the orange LCD.
                RoundedRectangle(cornerRadius: h * 0.08)
                    .fill(Color(white: 0.2))
                    .frame(width: w * 0.46, height: h * 0.62)
                    .offset(x: w * 0.1, y: h * 0.19)
                RoundedRectangle(cornerRadius: h * 0.04)
                    .fill(Color(red: 1, green: 0.55, blue: 0.1))
                    .frame(width: w * 0.4, height: h * 0.48)
                    .overlay(Shield().frame(width: h * 0.34, height: h * 0.34))
                    .offset(x: w * 0.13, y: h * 0.26)
                // D-pad ring and OK.
                Circle()
                    .stroke(Color(white: 0.55), lineWidth: h * 0.07)
                    .frame(width: h * 0.56, height: h * 0.56)
                    .offset(x: w * 0.68, y: h * 0.22)
                Circle()
                    .fill(Color(white: 0.7))
                    .frame(width: h * 0.2, height: h * 0.2)
                    .offset(x: w * 0.68 + h * 0.18, y: h * 0.4)
                // Back button.
                Circle()
                    .fill(Color(white: 0.7))
                    .frame(width: h * 0.16, height: h * 0.16)
                    .offset(x: w * 0.9, y: h * 0.68)
                // Status light.
                Circle()
                    .fill(light)
                    .frame(width: h * 0.13, height: h * 0.13)
                    .scaleEffect(pulsing ? 1.5 : 1)
                    .offset(x: w * 0.04, y: h * 0.12)
            }
            .frame(width: w, height: h)
        }
        .aspectRatio(1 / 0.42, contentMode: .fit)
    }
}

/// A Kindle e-reader: a black frame and a pale e-ink page.
struct KindleIcon: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            RoundedRectangle(cornerRadius: w * 0.16)
                .fill(Color(white: 0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(white: 0.88))
                        .frame(width: w * 0.78, height: h * 0.76)
                        .overlay(VStack(spacing: h * 0.06) {
                            ForEach(0..<4) { _ in Capsule().fill(Color(white: 0.6)).frame(width: w * 0.55, height: 2) }
                        })
                        .offset(y: -h * 0.04)
                )
        }
    }
}

/// The ZEC coin: the Zcash yellow disc and its Z with the two bars.
struct ZecLogo: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(Theme.zcash)
                Path { p in
                    let u = s / 32
                    p.move(to: CGPoint(x: 16 * u, y: 5.5 * u))
                    p.addLine(to: CGPoint(x: 16 * u, y: 9 * u))
                    p.move(to: CGPoint(x: 10 * u, y: 10 * u))
                    p.addLine(to: CGPoint(x: 22 * u, y: 10 * u))
                    p.addLine(to: CGPoint(x: 10 * u, y: 22 * u))
                    p.addLine(to: CGPoint(x: 22 * u, y: 22 * u))
                    p.move(to: CGPoint(x: 16 * u, y: 23 * u))
                    p.addLine(to: CGPoint(x: 16 * u, y: 26.5 * u))
                }
                .stroke(Color.black, style: StrokeStyle(lineWidth: s * 0.1, lineCap: .square, lineJoin: .miter))
            }
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Recent transactions; each opens on ZScan.
struct ActivityCard: View {
    @EnvironmentObject var wallet: WalletModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity").font(.headline)
            if wallet.transactions.isEmpty {
                Text(wallet.synced ? "No transactions yet." : "Transactions appear here as the wallet syncs.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            ForEach(wallet.transactions.prefix(20)) { tx in
                Button {
                    if let url = WalletModel.zscanURL(tx) { openURL(url) }
                } label: {
                    row(tx)
                }
                .buttonStyle(.plain)
                if tx.id != wallet.transactions.prefix(20).last?.id { Divider() }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func row(_ tx: ZcashTransaction.Overview) -> some View {
        let sent = tx.isSentTransaction
        return HStack(spacing: 12) {
            Image(systemName: sent ? "arrow.up" : "arrow.down")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(sent ? Color(white: 0.75) : Theme.zcash)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(sent ? "Sent" : "Received").font(.subheadline.weight(.semibold))
                Text(status(tx)).font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text((sent ? "−" : "+") + Zatoshi(abs(tx.value.amount)).zecString)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Label("ZScan", systemImage: "arrow.up.right.square").font(.caption2).foregroundStyle(Theme.muted)
            }
        }
        .contentShape(Rectangle())
    }

    private func status(_ tx: ZcashTransaction.Overview) -> String {
        if tx.isExpiredUmined == true { return "Expired" }
        guard let n = wallet.confirmations(tx) else { return "Pending · in the mempool" }
        let when = tx.blockTime.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? ""
        if n < 10 { return "Confirming · \(n) of 10" }
        return when.isEmpty ? "Confirmed" : when
    }
}

struct ActionTile: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(Theme.zcash)
                    .clipShape(Circle())
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}

/// The receiving address the Flipper shows, checked against this iPhone's own
/// derivation from the viewing key.
struct ReceiveView: View {
    @EnvironmentObject var wallet: WalletModel
    @State private var copied = false

    var body: some View {
        let index = wallet.receiveIndex
        let address = wallet.address(at: index)
        VStack(spacing: 18) {
            Capsule().fill(Theme.muted).frame(width: 40, height: 5).padding(.top, 8)
            Text("Receive ZEC").font(.title2.bold())
            HStack(spacing: 6) {
                Image(systemName: wallet.flipperReady ? "checkmark.seal.fill" : "clock.arrow.circlepath")
                Text(wallet.flipperReady ? "Same address as on your Flipper"
                                         : "Last address shown on your Flipper")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(wallet.flipperReady ? Theme.scan : Theme.muted)
            if let address {
                QRCode(text: address)
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .frame(maxWidth: 260)
                Text(address)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                HStack {
                    Button {
                        UIPasteboard.general.string = address
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").primaryButton()
                    }
                    ShareLink(item: address) {
                        Label("Share", systemImage: "square.and.arrow.up").primaryButton()
                    }
                }
                .padding(.horizontal)
                Text("A new address each time ZFlip opens, or press ▶ in Receive on the Flipper: this screen follows it.")
                    .font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center).padding(.horizontal)
            } else {
                ProgressView()
            }
            Spacer()
        }
        .padding()
        .background(Theme.background.ignoresSafeArea())
    }
}
