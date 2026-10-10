import SwiftUI
import ZcashLightClientKit

struct SendView: View {
    @EnvironmentObject var wallet: WalletModel
    @EnvironmentObject var link: FlipperLink
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var fee: Zatoshi?

    private var zatoshi: Int64? {
        let normalized = amount.replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: normalized), value > 0 else { return nil }
        let z = NSDecimalNumber(decimal: value * 100_000_000).int64Value
        return z > 0 ? z : nil
    }

    /// The fee shown once estimated, the ZIP 317 minimum until then.
    private var feeOrMinimum: Int64 { (fee ?? WalletModel.minimumFee).amount }

    /// The amount plus its fee fits in what is spendable now.
    private var covered: Bool {
        guard let zatoshi else { return true }
        return zatoshi + feeOrMinimum <= wallet.balance.amount
    }

    private var valid: Bool {
        guard zatoshi != nil else { return false }
        return wallet.validate(address: address) && covered
    }

    var body: some View {
        NavigationStack {
            Group {
                switch wallet.sendStep {
                case .idle: form
                default: progress
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Send ZEC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        wallet.sendStep = .idle
                        dismiss()
                    }
                }
            }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                field("To", text: $address, prompt: "u1… shielded address")
                if !address.isEmpty && !wallet.validate(address: address) {
                    Text("Not a valid Zcash address for this network.").font(.footnote).foregroundStyle(.orange)
                }
                field("Amount (ZEC)", text: $amount, prompt: "0.1", keyboard: .decimalPad)
                HStack {
                    Text("Spendable: \(wallet.balance.zecString)").font(.footnote).foregroundStyle(Theme.muted)
                    Spacer()
                    if wallet.balance.amount > feeOrMinimum {
                        Button("Max") {
                            let max = Decimal(wallet.balance.amount - feeOrMinimum) / 100_000_000
                            amount = "\(max)"
                        }
                        .font(.footnote.weight(.semibold))
                    }
                }
                if wallet.pending.amount > 0 {
                    Text("\(wallet.pending.zecString) still confirming: spendable after 10 confirmations.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                if !covered {
                    Text(wallet.balance.amount <= feeOrMinimum
                         ? "Your spendable balance doesn't cover the network fee (at least \(WalletModel.minimumFee.zecString))."
                         : "The amount plus the network fee (\(Zatoshi(feeOrMinimum).zecString)) is more than you can spend.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                field("Memo (optional)", text: $memo, prompt: "Private message")
                if let fee {
                    Text("Network fee: \(fee.zecString)").font(.footnote).foregroundStyle(Theme.muted)
                }
                Button {
                    guard let zatoshi else { return }
                    Task { await wallet.send(to: address, zatoshi: zatoshi, memo: memo) }
                } label: {
                    Label("Review on Flipper", systemImage: "shield.lefthalf.filled").primaryButton()
                }
                .disabled(!valid)
                .opacity(valid ? 1 : 0.5)
                .padding(.top, 8)
                Text("Your Flipper will show the amount, the recipient and the fee. Check them there, then hold OK to sign.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .padding(20)
        }
        .task(id: "\(address)|\(amount)") {
            fee = nil
            guard let zatoshi, wallet.validate(address: address) else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            fee = await wallet.proposalFee(to: address, zatoshi: zatoshi)
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Theme.muted)
            TextField(prompt, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var progress: some View {
        VStack(spacing: 22) {
            Spacer()
            switch wallet.sendStep {
            case .sent(let txid):
                Shield().frame(height: 110)
                Text("Sent").font(.largeTitle.bold())
                Text(txid).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                if let url = URL(string: "https://zscan.cash/tx/\(txid)") {
                    Link(destination: url) {
                        Label("View on ZScan", systemImage: "arrow.up.right.square").font(.subheadline.weight(.semibold))
                    }
                }
                Button("Done") {
                    wallet.sendStep = .idle
                    dismiss()
                }
                .primaryButton()
            case .failed(let message):
                Image(systemName: "xmark.shield").font(.system(size: 70)).foregroundStyle(.red)
                Text("Not sent").font(.title.bold())
                Text(message).multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                Button("Back") { wallet.sendStep = .idle }.primaryButton()
            default:
                ForgingShield().frame(height: 110)
                Text(stepTitle).font(.title2.bold()).multilineTextAlignment(.center)
                Text(stepDetail).multilineTextAlignment(.center).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(24)
    }

    private var stepTitle: String {
        switch wallet.sendStep {
        case .preparing: return "Preparing the transaction"
        case .confirmOnFlipper: return link.awaitingFlipper ? "Confirm on your Flipper" : "Flipper is checking…"
        case .broadcasting: return "Broadcasting"
        default: return ""
        }
    }

    private var stepDetail: String {
        switch wallet.sendStep {
        case .confirmOnFlipper:
            return "Open ZFlip Sign. Check each payment and the fee on the Flipper's screen, then hold OK. Press Back to refuse."
        case .broadcasting:
            return "Signed by your Flipper. Sending it to the Zcash network."
        default:
            return "Building a shielded transaction and its zero-knowledge proof."
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var wallet: WalletModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false
    @AppStorage("appearance") private var appearance = 0

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag(0)
                        Text("Light").tag(1)
                        Text("Dark").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Flipper") {
                    LabeledContent("Name", value: wallet.pairing?.flipperName ?? "-")
                    LabeledContent("Network", value: wallet.pairing?.network == 1 ? "Testnet" : "Mainnet")
                    LabeledContent("Scanning from block", value: "\(wallet.pairing?.birthday ?? 0)")
                }
                Section {
                    Button("Forget this wallet", role: .destructive) { confirmForget = true }
                } footer: {
                    Text("Removes the watch-only wallet from this iPhone. Your funds stay safe: the keys are on the Flipper.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Forget this wallet?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    Task {
                        await wallet.forget()
                        dismiss()
                    }
                }
            }
        }
    }
}
