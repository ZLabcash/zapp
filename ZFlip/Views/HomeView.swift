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
                    FlipperCard()
                    HStack(spacing: 12) {
                        ActionTile(title: "Receive", icon: "arrow.down") { showReceive = true }
                        ActionTile(title: "Send", icon: "arrow.up") { showSend = true }
                            .disabled(!wallet.synced || wallet.balance.amount == 0)
                            .opacity(!wallet.synced || wallet.balance.amount == 0 ? 0.45 : 1)
                    }
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
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(Theme.muted)
            }
        }
        .padding(.top, 8)
    }
}

struct BalanceCard: View {
    @EnvironmentObject var wallet: WalletModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Shielded balance", systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.muted)
            Text(wallet.balance.zecString)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
            if wallet.pending.amount > 0 {
                Text("+ \(wallet.pending.zecString) confirming").font(.footnote).foregroundStyle(Theme.zcash)
            }
            if let error = wallet.syncError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
            } else if wallet.synced {
                Label("Up to date", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.scan)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: wallet.syncProgress).tint(Theme.zcash)
                    Text("Syncing with the Zcash network · \(Int(wallet.syncProgress * 100))%")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
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

/// The paired Flipper: what it is doing and the one action that makes sense now.
struct FlipperCard: View {
    @EnvironmentObject var wallet: WalletModel
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                FlipperGlyph(color: tint, pulsing: pulsing && pulse)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            actions
        }
        .padding(20)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var name: String { wallet.pairing?.flipperName ?? "your Flipper" }

    private var pulsing: Bool {
        switch wallet.flipperState {
        case .connecting, .approve: return true
        default: return false
        }
    }

    private var tint: Color {
        switch wallet.flipperState {
        case .ready: return Theme.scan
        case .approve: return Theme.zcash
        case .otherWallet: return .orange
        case .failed: return .red
        default: return Theme.muted
        }
    }

    private var title: String {
        switch wallet.flipperState {
        case .idle: return "Flipper not connected"
        case .connecting: return "Connecting to \(name)…"
        case .approve: return "Press OK on your Flipper"
        case .ready: return "\(name) connected"
        case .otherWallet: return "Another wallet on this Flipper"
        case .failed: return "Could not connect"
        }
    }

    private var subtitle: String {
        switch wallet.flipperState {
        case .idle: return "Open ZFlip on the Flipper and unlock it, then connect. It signs everything you send."
        case .connecting: return "Keep ZFlip open on the Flipper, close to this iPhone."
        case .approve: return "The Flipper asks to share this wallet's viewing key. It can see, never spend."
        case .ready: return "Ready to sign. Your keys never leave the Flipper."
        case .otherWallet(let flipper):
            return "\(flipper) holds a different wallet than the one on this iPhone. Use it instead?"
        case .failed(let message): return message
        }
    }

    @ViewBuilder private var actions: some View {
        switch wallet.flipperState {
        case .idle, .failed:
            Button { Task { await wallet.connectFlipper() } } label: {
                Label(wallet.flipperState == .idle ? "Connect to Flipper" : "Try again",
                      systemImage: "dot.radiowaves.left.and.right").primaryButton()
            }
        case .connecting, .approve:
            Button { wallet.disconnectFlipper() } label: {
                Text("Cancel").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color.primary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        case .ready:
            Button { wallet.disconnectFlipper() } label: {
                Text("Disconnect").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
        case .otherWallet:
            VStack(spacing: 10) {
                Button { Task { await wallet.adoptFlipperWallet() } } label: {
                    Label("Use this Flipper's wallet", systemImage: "arrow.triangle.2.circlepath").primaryButton()
                }
                Button { wallet.disconnectFlipper() } label: {
                    Text("Keep the current one").font(.subheadline).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A small Flipper Zero: an orange screen with the ZScan shield, and a status light.
struct FlipperGlyph: View {
    let color: Color
    let pulsing: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.96))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.15), lineWidth: 1))
                .frame(width: 58, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(red: 1, green: 0.55, blue: 0.1))
                        .frame(width: 30, height: 20)
                        .overlay(Shield().frame(width: 14, height: 14))
                        .offset(x: -6)
                )
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                .scaleEffect(pulsing ? 1.35 : 1)
                .offset(x: 4, y: -4)
        }
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
