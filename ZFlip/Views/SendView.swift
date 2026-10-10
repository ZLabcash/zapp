import SwiftUI
import ZcashLightClientKit

struct SendView: View {
    @EnvironmentObject var wallet: WalletModel
    @EnvironmentObject var link: FlipperLink
    @EnvironmentObject var book: ContactBook
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var fee: Zatoshi?
    @State private var picking = false
    @State private var scanning = false
    @State private var savingName = ""
    @State private var askingName = false

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

    /// What is wrong with the amount, or worth knowing, in one sentence.
    private var amountNote: (text: String, blocking: Bool)? {
        let spendable = wallet.balance.amount
        if !amount.isEmpty && zatoshi == nil {
            return ("Enter an amount above zero, like 0.01.", true)
        }
        guard let zatoshi else { return nil }
        if spendable <= feeOrMinimum {
            return ("Your spendable balance (\(wallet.balance.zecString)) doesn't cover the network fee of \(Zatoshi(feeOrMinimum).zecString).", true)
        }
        if zatoshi > spendable {
            return ("That's more than your spendable balance of \(wallet.balance.zecString).", true)
        }
        if zatoshi + feeOrMinimum > spendable {
            let max = Zatoshi(spendable - feeOrMinimum)
            return ("That leaves nothing for the network fee (\(Zatoshi(feeOrMinimum).zecString)). You can send up to \(max.zecString): tap Max.", true)
        }
        if zatoshi < feeOrMinimum {
            return ("Very small amount: the network fee (\(Zatoshi(feeOrMinimum).zecString)) is more than what you send.", false)
        }
        return nil
    }

    private var valid: Bool {
        guard zatoshi != nil else { return false }
        return wallet.validate(address: address) && covered && amountNote?.blocking != true
    }

    var body: some View {
        Group {
            Group {
                switch wallet.sendStep {
                case .idle: form
                default: progress
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Send ZEC")
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    Group {
                        if QRScanner.available {
                            ScannerScreen { text in
                                let request = PaymentRequest(text)
                                address = request.address
                                if let a = request.amount { amount = a }
                                if let m = request.memo { memo = m }
                                scanning = false
                            }
                        } else {
                            Text("The camera isn't available. Allow it for ZApp in Settings.")
                                .multilineTextAlignment(.center).padding()
                        }
                    }
                    .navigationTitle("Scan a Zcash QR code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Cancel") { scanning = false } }
                }
            }
            .sheet(isPresented: $picking) {
                NavigationStack { ContactsView(pick: { address = $0.address }) }
            }
            .alert("Save to address book", isPresented: $askingName) {
                TextField("Name", text: $savingName)
                Button("Save") {
                    let name = savingName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { book.save(Contact(name: name, address: address)) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .navigationBarTitleDisplayMode(.inline)
            .backArrow { wallet.sendStep = .idle }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("To").font(.caption).foregroundStyle(Theme.muted)
                        if let contact = book.named(address) {
                            Text("· \(contact.name)").font(.caption.weight(.semibold)).foregroundStyle(Theme.zcash)
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("u1… shielded address", text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button { scanning = true } label: {
                            Image(systemName: "qrcode.viewfinder").font(.title3)
                        }
                        .accessibilityLabel("Scan a QR code")
                        Button { picking = true } label: {
                            Image(systemName: "person.crop.circle").font(.title3)
                        }
                        .accessibilityLabel("Address book")
                    }
                    .padding(14)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if !address.isEmpty && !wallet.validate(address: address) {
                    Text("Not a valid Zcash address for this network.").font(.footnote).foregroundStyle(.orange)
                } else if wallet.validate(address: address) && book.named(address) == nil {
                    Button {
                        savingName = ""
                        askingName = true
                    } label: {
                        Label("Save to address book", systemImage: "person.badge.plus").font(.footnote.weight(.semibold))
                    }
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
                if let note = amountNote {
                    Label(note.text, systemImage: note.blocking ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.footnote).foregroundStyle(note.blocking ? .orange : Theme.muted)
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
                if let url = WalletModel.explorerURL(txid: txid) {
                    Link(destination: url) {
                        Label("View on the explorer", systemImage: "arrow.up.right.square").font(.subheadline.weight(.semibold))
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
