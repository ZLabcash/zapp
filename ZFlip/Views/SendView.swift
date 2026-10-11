import SwiftUI
import ZcashLightClientKit

/// Send: one or more recipients (a multisend is one transaction and one Flipper signature).
/// Each recipient is the same card: address (typed, scanned or from the address book),
/// amount, and its own optional message, or one message for everyone.
struct SendView: View {
    @EnvironmentObject var wallet: WalletModel
    @EnvironmentObject var link: FlipperLink
    @EnvironmentObject var book: ContactBook
    @Environment(\.dismiss) private var dismiss

    struct Line: Identifiable, Equatable {
        let id = UUID()
        var address = ""
        var amount = ""
        var memo = ""
    }

    @State private var lines: [Line] = Demo.on("send-multi")
        ? [Line(address: Demo.friend, amount: "0.05", memo: "lunch, thanks!"), Line(address: Demo.friend, amount: "0.02")]
        : [Demo.on("send-filled") ? Line(address: Demo.friend, amount: "0.05") : Line()]
    @State private var sameMemo = false
    @State private var sharedMemo = ""
    @State private var fee: Zatoshi?
    /// The card a scan or an address-book pick fills in.
    @State private var scanningFor: UUID?
    @State private var pickingFor: UUID?
    @State private var saving: (id: UUID, name: String)?

    private static func zats(_ text: String) -> Int64? {
        guard let value = Decimal(string: text.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        let z = NSDecimalNumber(decimal: value * 100_000_000).int64Value
        return z > 0 ? z : nil
    }

    private var multi: Bool { lines.count > 1 }

    /// Every payment, if each card has a valid address and amount.
    private var payments: [WalletModel.Payment]? {
        var all: [WalletModel.Payment] = []
        for l in lines {
            guard let z = Self.zats(l.amount), wallet.validate(address: l.address) else { return nil }
            all.append(WalletModel.Payment(address: l.address, zatoshi: z, memo: multi && sameMemo ? sharedMemo : l.memo))
        }
        return all
    }

    /// What the recipients get together (nil while an amount is missing or invalid).
    private var total: Int64? {
        var sum: Int64 = 0
        for l in lines {
            guard let z = Self.zats(l.amount) else { return nil }
            sum += z
        }
        return sum
    }

    /// The fee shown once estimated, the ZIP 317 minimum until then.
    private var feeOrMinimum: Int64 { (fee ?? WalletModel.minimumFee).amount }

    /// What is wrong with the amounts, or worth knowing, in one sentence.
    private var amountNote: (text: String, blocking: Bool)? {
        let spendable = wallet.balance.amount
        if lines.contains(where: { !$0.amount.isEmpty && Self.zats($0.amount) == nil }) {
            return ("Enter an amount above zero, like 0.01.", true)
        }
        guard let total else { return nil }
        if spendable <= feeOrMinimum {
            return ("Your spendable balance (\(wallet.balance.zecString)) doesn't cover the network fee of \(Zatoshi(feeOrMinimum).zecString).", true)
        }
        if total > spendable {
            return ("That's more than your spendable balance of \(wallet.balance.zecString).", true)
        }
        if total + feeOrMinimum > spendable {
            let max = Zatoshi(spendable - feeOrMinimum)
            return ("That leaves nothing for the network fee (\(Zatoshi(feeOrMinimum).zecString)). You can send up to \(max.zecString)\(multi ? " in total" : ": tap Max").", true)
        }
        if total < feeOrMinimum {
            return ("Very small amount: the network fee (\(Zatoshi(feeOrMinimum).zecString)) is more than what you send.", false)
        }
        return nil
    }

    private var valid: Bool { payments != nil && amountNote?.blocking != true && wallet.pendingBroadcasts.isEmpty }

    var body: some View {
        Group {
            switch wallet.sendStep {
            case .idle: form
            default: progress
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Send ZEC")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow { wallet.sendStep = .idle }
        .sheet(isPresented: Binding(get: { scanningFor != nil }, set: { if !$0 { scanningFor = nil } })) {
            NavigationStack {
                Group {
                    if QRScanner.available {
                        ScannerScreen { text in
                            let request = PaymentRequest(text)
                            update(scanningFor) { l in
                                l.address = request.address
                                if let a = request.amount { l.amount = a }
                                if let m = request.memo { l.memo = m }
                            }
                            scanningFor = nil
                        }
                    } else {
                        Text("The camera isn't available. Allow it for ZApp in Settings.")
                            .multilineTextAlignment(.center).padding()
                    }
                }
                .navigationTitle("Scan a Zcash QR code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { scanningFor = nil } }
            }
        }
        .sheet(isPresented: Binding(get: { pickingFor != nil }, set: { if !$0 { pickingFor = nil } })) {
            NavigationStack {
                ContactsView(pick: { c in
                    update(pickingFor) { $0.address = c.address }
                    pickingFor = nil
                })
            }
        }
        .alert("Save to address book", isPresented: Binding(get: { saving != nil }, set: { if !$0 { saving = nil } })) {
            TextField("Name", text: Binding(get: { saving?.name ?? "" }, set: { saving?.name = $0 }))
            Button("Save") {
                if let saving, let l = lines.first(where: { $0.id == saving.id }) {
                    let name = saving.name.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { book.save(Contact(name: name, address: l.address)) }
                }
                saving = nil
            }
            Button("Cancel", role: .cancel) { saving = nil }
        }
    }

    private func update(_ id: UUID?, _ change: (inout Line) -> Void) {
        guard let id, let i = lines.firstIndex(where: { $0.id == id }) else { return }
        change(&lines[i])
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, _ in
                    card(i)
                }
                if lines.count < WalletModel.maxRecipients {
                    Button {
                        withAnimation(.snappy) { lines.append(Line()) }
                    } label: {
                        Label("Add a recipient", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.zcash.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.zcash)
                }
                if multi {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $sameMemo.animation(.snappy)) {
                            Text("Same message for everyone").font(.subheadline.weight(.semibold))
                        }
                        .tint(Theme.zcash)
                        if sameMemo {
                            input("Message for all recipients (optional)", text: $sharedMemo)
                        }
                    }
                    .padding(16)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                summary
                Button {
                    guard let payments else { return }
                    Task { await wallet.send(payments) }
                } label: {
                    Label(multi ? "Review \(lines.count) payments on Flipper" : "Review on Flipper", systemImage: "shield.lefthalf.filled")
                        .primaryButton()
                }
                .disabled(!valid)
                .opacity(valid ? 1 : 0.5)
                .padding(.top, 4)
                Text(multi
                     ? "One transaction, one signature. Your Flipper shows each payment on its own page (OK or ▶ for the next), then the total and the fee: hold OK once to sign them all."
                     : "Your Flipper will show the amount, the recipient and the fee. Check them there, then hold OK to sign.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .padding(20)
        }
        .task(id: lines.map { $0.address + "=" + $0.amount }.joined(separator: ",")) {
            if Demo.scene != nil {
                fee = total == nil ? nil : WalletModel.minimumFee
                return
            }
            fee = nil
            guard let payments else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            fee = await wallet.proposalFee(payments)
        }
    }

    /// Spendable, the total of several payments, the fee, and what is wrong if anything.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Spendable").foregroundStyle(Theme.muted)
                Spacer()
                Text(wallet.balance.zecString).monospacedDigit()
            }
            if multi, let total {
                HStack {
                    Text("Total to \(lines.count) recipients").foregroundStyle(Theme.muted)
                    Spacer()
                    Text(Zatoshi(total).zecString).monospacedDigit().fontWeight(.semibold)
                }
            }
            if let fee {
                HStack {
                    Text("Network fee").foregroundStyle(Theme.muted)
                    Spacer()
                    Text(fee.zecString).monospacedDigit()
                }
            }
            if wallet.pending.amount > 0 {
                Text("\(wallet.pending.zecString) still confirming: spendable after 10 confirmations.").foregroundStyle(Theme.muted)
            }
            if let note = amountNote {
                Label(note.text, systemImage: note.blocking ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(note.blocking ? .orange : Theme.muted)
            }
            if !wallet.pendingBroadcasts.isEmpty {
                Label("A signed payment is waiting to be broadcast (see Activity). Broadcast or discard it first: a new one could spend the same funds.",
                      systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if !wallet.online {
                Label("No network: you can still sign with your Flipper and broadcast later.", systemImage: "wifi.slash")
                    .foregroundStyle(Theme.muted)
            }
        }
        .font(.footnote)
        .padding(16)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    /// One recipient: address with scan and address book, amount, and its message.
    private func card(_ i: Int) -> some View {
        let line = $lines[i]
        let l = lines[i]
        let bad = !l.address.isEmpty && !wallet.validate(address: l.address)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(multi ? "Recipient \(i + 1)" : "To").font(.subheadline.weight(.semibold))
                if let c = book.named(l.address) {
                    Text("· \(c.name)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.zcash)
                }
                Spacer()
                if multi {
                    Button {
                        withAnimation(.snappy) { lines.removeAll { $0.id == l.id } }
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(Theme.muted)
                    }
                    .accessibilityLabel("Remove recipient \(i + 1)")
                }
            }
            HStack(spacing: 10) {
                TextField("u1… shielded address", text: line.address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button { scanningFor = l.id } label: {
                    Image(systemName: "qrcode.viewfinder").font(.title3)
                }
                .accessibilityLabel("Scan a QR code")
                Button { pickingFor = l.id } label: {
                    Image(systemName: "person.crop.circle").font(.title3)
                }
                .accessibilityLabel("Address book")
            }
            .padding(14)
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if bad {
                Text("Not a valid Zcash address for this network.").font(.footnote).foregroundStyle(.orange)
            } else if wallet.validate(address: l.address) && book.named(l.address) == nil {
                Button { saving = (l.id, "") } label: {
                    Label("Save to address book", systemImage: "person.badge.plus").font(.footnote.weight(.semibold))
                }
            }
            HStack(spacing: 10) {
                TextField("Amount", text: line.amount)
                    .keyboardType(.decimalPad)
                Text("ZEC").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                if !multi && wallet.balance.amount > feeOrMinimum {
                    Button("Max") {
                        lines[i].amount = "\(Decimal(wallet.balance.amount - feeOrMinimum) / 100_000_000)"
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .padding(14)
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if !(multi && sameMemo) {
                input("Message (optional)", text: line.memo, onCard: true)
            }
        }
        .padding(16)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func input(_ prompt: String, text: Binding<String>, onCard: Bool = false) -> some View {
        TextField(prompt, text: text, axis: .vertical)
            .lineLimit(1...4)
            .padding(14)
            .background(onCard ? Theme.background : Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
            case .signedOffline:
                Image(systemName: "clock.badge.checkmark").font(.system(size: 66)).foregroundStyle(Theme.zcash)
                Text("Signed, not broadcast yet").font(.title2.bold()).multilineTextAlignment(.center)
                Text(wallet.online
                     ? "Your Flipper signed it. It's waiting in Activity: broadcast it when you decide (within about 50 minutes, before it expires), or discard it."
                     : "Your Flipper signed it, but this phone has no network. It's saved in Activity: broadcast it when you're back online (within about 50 minutes, before it expires), or discard it.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.muted)
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
            return "Check each payment and the fee on the Flipper's screen, then hold OK. Press Back to refuse."
        case .broadcasting:
            return "Signed by your Flipper. Sending it to the Zcash network."
        default:
            return "Building a shielded transaction and its zero-knowledge proof."
        }
    }
}
