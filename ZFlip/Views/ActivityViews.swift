import SwiftUI
import ZcashLightClientKit

/// Home: today's activity (or, on a quiet day, the last few), and a way to see everything.
struct ActivityCard: View {
    @EnvironmentObject var wallet: WalletModel
    @State private var selected: WalletModel.ActivityItem?
    @State private var pending: WalletModel.PendingBroadcast?

    private var recent: (title: String, items: [WalletModel.ActivityItem]) {
        let today = wallet.activity.filter { item in
            guard let t = item.blockTime else { return true } // in the mempool: happening now
            return Calendar.current.isDateInToday(Date(timeIntervalSince1970: t))
        }
        return today.isEmpty ? ("Recent activity", Array(wallet.activity.prefix(3))) : ("Today", today)
    }

    var body: some View {
        let recent = recent
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(recent.title).font(.headline)
                Spacer()
                if !wallet.activity.isEmpty {
                    NavigationLink { AllActivityView() } label: {
                        Text("See all").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.zcash)
                    }
                }
            }
            ForEach(wallet.pendingBroadcasts) { p in
                Button { pending = p } label: { PendingRow(p: p) }.buttonStyle(.plain)
                Divider()
            }
            if wallet.activity.isEmpty && wallet.pendingBroadcasts.isEmpty {
                Text(wallet.synced ? "No transactions yet." : "Transactions appear here as the wallet syncs.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            ForEach(recent.items) { tx in
                Button { selected = tx } label: { ActivityRow(tx: tx) }
                    .buttonStyle(.plain)
                if tx.id != recent.items.last?.id { Divider() }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .sheet(item: $selected) { TxDetailView(tx: $0) }
        .sheet(item: $pending) { PendingView(p: $0) }
        .onAppear {
            // Filming: open a transaction's sheet straight away.
            if Demo.on("detail") { selected = wallet.activity.first }
        }
    }
}

/// A signed payment waiting for the user to broadcast it.
struct PendingRow: View {
    @EnvironmentObject var wallet: WalletModel
    let p: WalletModel.PendingBroadcast

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(Color.orange)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Signed · not broadcast").font(.subheadline.weight(.semibold))
                Text(wallet.expired(p) ? "Expired: discard it and send again"
                     : wallet.minutesLeft(p).map { "Broadcast within about \($0) min" } ?? "Waiting to be broadcast")
                    .font(.caption).foregroundStyle(wallet.expired(p) ? .red : .orange)
            }
            Spacer()
            Text("−" + (wallet.showsAmounts ? Zatoshi(p.total).zecString : "•••• ZEC"))
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .contentShape(Rectangle())
    }
}

/// What the signed payment pays, its deadline, and the two choices: broadcast or discard.
struct PendingView: View {
    @EnvironmentObject var wallet: WalletModel
    @EnvironmentObject var book: ContactBook
    @Environment(\.dismiss) private var dismiss
    let p: WalletModel.PendingBroadcast
    @State private var working = false
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var height: CGFloat = 560

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "clock.badge.checkmark").font(.system(size: 44)).foregroundStyle(Theme.zcash)
                Text("Signed, waiting to be broadcast").font(.title3.bold())
                Text("Your Flipper signed this payment. Nothing has left your wallet yet: it happens when you broadcast it.")
                    .font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                VStack(spacing: 0) {
                    ForEach(Array(p.payments.enumerated()), id: \.offset) { i, pay in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(p.payments.count > 1 ? "To (\(i + 1))" : "To").foregroundStyle(Theme.muted)
                                Spacer()
                                Text(Zatoshi(pay.zatoshi).zecString).fontWeight(.semibold).monospacedDigit()
                            }
                            Text(book.named(pay.address)?.name ?? AddressRow.short(pay.address))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.muted)
                            if !pay.memo.isEmpty { Text("“\(pay.memo)”").font(.caption) }
                        }
                        .font(.subheadline)
                        .padding(.vertical, 10)
                        Divider()
                    }
                    HStack {
                        Text("Signed").foregroundStyle(Theme.muted)
                        Spacer()
                        Text(p.created.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.subheadline).padding(.vertical, 10)
                    Divider()
                    HStack {
                        Text("Expires").foregroundStyle(Theme.muted)
                        Spacer()
                        Text(wallet.expired(p) ? "Expired" : "Block \(p.expiryHeight.formatted())" + (wallet.minutesLeft(p).map { " · ~\($0) min" } ?? ""))
                            .foregroundStyle(wallet.expired(p) ? .red : Theme.ink)
                    }
                    .font(.subheadline).padding(.vertical, 10)
                }
                .padding(.horizontal, 16)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                }
                Button {
                    working = true
                    Task {
                        error = await wallet.broadcast(p)
                        working = false
                        if error == nil { dismiss() }
                    }
                } label: {
                    Label(working ? "Broadcasting…" : "Broadcast now", systemImage: "antenna.radiowaves.left.and.right").primaryButton()
                }
                .disabled(working || wallet.expired(p) || !wallet.online)
                .opacity(working || wallet.expired(p) || !wallet.online ? 0.5 : 1)
                if !wallet.online {
                    Text("No network right now.").font(.footnote).foregroundStyle(Theme.muted)
                }
                Button(role: .destructive) { confirmDiscard = true } label: {
                    Text("Discard").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
        }
        .background(Theme.background.ignoresSafeArea())
        .presentationDetents([.height(height), .large])
        .presentationDragIndicator(.visible)
        .confirmationDialog("Discard this signed payment?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                wallet.discard(p)
                dismiss()
            }
        } message: {
            Text("It was never broadcast: nothing is sent and your balance doesn't change.")
        }
    }
}

/// One transaction: direction, status (or its message), amount.
struct ActivityRow: View {
    @EnvironmentObject var wallet: WalletModel
    let tx: WalletModel.ActivityItem
    var showMemo = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tx.sent ? "arrow.up" : "arrow.down")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(tx.sent ? Color(white: 0.75) : Theme.zcash)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.sent ? "Sent" : "Received").font(.subheadline.weight(.semibold))
                Text(TxStatus.short(tx, wallet)).font(.caption).foregroundStyle(Theme.muted)
                if showMemo, let memo = tx.memos.first {
                    Text("“\(memo)”").font(.caption).foregroundStyle(Theme.ink).lineLimit(2)
                }
            }
            Spacer()
            Text((tx.sent ? "−" : "+") + (wallet.showsAmounts ? Zatoshi(tx.zatoshi).zecString : "•••• ZEC"))
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .contentShape(Rectangle())
    }
}

@MainActor
enum TxStatus {
    static func short(_ tx: WalletModel.ActivityItem, _ wallet: WalletModel) -> String {
        if tx.expired { return "Expired" }
        guard let n = wallet.confirmations(tx) else { return "Pending · in the mempool" }
        if n < 10 { return "Confirming · \(n) of 10" }
        return tx.blockTime.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "Confirmed"
    }

    static func long(_ tx: WalletModel.ActivityItem, _ wallet: WalletModel) -> String {
        if tx.expired { return "Expired, never mined" }
        guard let n = wallet.confirmations(tx) else { return "Pending, in the mempool" }
        if n < 10 { return "Confirming, \(n) of 10 confirmations" }
        return "Confirmed · \(n.formatted()) confirmations"
    }
}

/// The detail of one transaction: who, how much, status, message, date, id, explorer.
struct TxDetailView: View {
    @EnvironmentObject var wallet: WalletModel
    @Environment(\.openURL) private var openURL
    let tx: WalletModel.ActivityItem
    @State private var recipients: [String] = []
    @State private var copied = false
    @State private var height: CGFloat = 520

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Image(systemName: tx.sent ? "arrow.up" : "arrow.down")
                        .font(.title2.weight(.bold)).foregroundStyle(.black)
                        .frame(width: 54, height: 54)
                        .background(tx.sent ? Color(white: 0.75) : Theme.zcash).clipShape(Circle())
                    Text(tx.sent ? "Sent" : "Received").font(.headline).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        Text((tx.sent ? "−" : "+") + (wallet.showsAmounts ? Zatoshi(tx.zatoshi).zecAmount : "••••"))
                            .font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                        ZecLogo().frame(width: 28, height: 28)
                    }
                }
                VStack(spacing: 0) {
                    if tx.sent {
                        if recipients.isEmpty {
                            row("To", "Shielded recipient")
                        }
                        ForEach(Array(recipients.enumerated()), id: \.offset) { i, r in
                            AddressRow(label: recipients.count > 1 ? "To (\(i + 1))" : "To", address: r)
                        }
                        if let fee = tx.fee { row("Network fee", Zatoshi(fee).zecString) }
                    } else {
                        row("From", "Shielded sender")
                    }
                    row("Status", TxStatus.long(tx, wallet))
                    if let t = tx.blockTime {
                        row("Date", Date(timeIntervalSince1970: t).formatted(date: .long, time: .shortened))
                    }
                    if tx.memos.isEmpty {
                        row("Message", "None")
                    } else {
                        ForEach(Array(tx.memos.enumerated()), id: \.offset) { i, m in
                            row(tx.memos.count > 1 ? "Message (\(i + 1))" : "Message", m)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Transaction ID").font(.subheadline).foregroundStyle(Theme.muted)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = tx.txid
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption.weight(.semibold))
                            }
                        }
                        Text(tx.txid).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 16)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                if let url = tx.url {
                    Button { openURL(url) } label: {
                        Label("View on \(url.host() ?? "the explorer")", systemImage: "arrow.up.right.square").primaryButton()
                    }
                }
                if !tx.sent {
                    Text("Zcash shielded payments don't reveal who sent them, to anyone, including this app.")
                        .font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
        }
        .background(Theme.background.ignoresSafeArea())
        // As tall as the content (nothing hidden below), the full screen only if it's longer.
        .presentationDetents([.height(height), .large])
        .presentationDragIndicator(.visible)
        .task { recipients = await wallet.recipients(of: tx) }
    }

    private func row(_ k: String, _ v: String, mono: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Text(k).font(.subheadline).foregroundStyle(Theme.muted)
                Spacer(minLength: 20)
                Text(v)
                    .font(mono ? .system(.caption, design: .monospaced) : .subheadline)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 12)
            Divider()
        }
    }
}

/// Settings → All activity: every transaction by day, with its messages, searchable.
struct AllActivityView: View {
    @EnvironmentObject var wallet: WalletModel
    @State private var query = ""
    @State private var selected: WalletModel.ActivityItem?
    @State private var pending: WalletModel.PendingBroadcast?

    private var days: [(String, [WalletModel.ActivityItem])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let items = wallet.activity.filter { tx in
            q.isEmpty || tx.memos.contains { $0.lowercased().contains(q) } || tx.txid.hasPrefix(q)
                || Zatoshi(tx.zatoshi).zecString.contains(q)
        }
        var out: [(String, [WalletModel.ActivityItem])] = []
        for tx in items {
            let day = tx.blockTime.map { Date(timeIntervalSince1970: $0) }.map { d in
                Calendar.current.isDateInToday(d) ? "Today" : Calendar.current.isDateInYesterday(d) ? "Yesterday" : d.formatted(date: .complete, time: .omitted)
            } ?? "Pending"
            if out.last?.0 == day { out[out.count - 1].1.append(tx) } else { out.append((day, [tx])) }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Search messages, amounts, transaction IDs", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .padding(14)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                if !wallet.pendingBroadcasts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WAITING TO BROADCAST").font(.caption.weight(.semibold)).foregroundStyle(.orange).padding(.leading, 4)
                        VStack(spacing: 10) {
                            ForEach(wallet.pendingBroadcasts) { p in
                                Button { pending = p } label: { PendingRow(p: p) }.buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                }
                if days.isEmpty {
                    Text(query.isEmpty ? "No transactions yet." : "Nothing matches “\(query)”.").font(.footnote).foregroundStyle(Theme.muted)
                }
                ForEach(days, id: \.0) { day, items in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(day.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted).padding(.leading, 4)
                        VStack(spacing: 10) {
                            ForEach(items) { tx in
                                Button { selected = tx } label: { ActivityRow(tx: tx, showMemo: true) }.buttonStyle(.plain)
                                if tx.id != items.last?.id { Divider() }
                            }
                        }
                        .padding(16)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("All activity")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
        .sheet(item: $selected) { TxDetailView(tx: $0) }
        .sheet(item: $pending) { PendingView(p: $0) }
    }
}

/// A recipient address, short (with the contact's name when known); tap to see it whole and copy it.
struct AddressRow: View {
    @EnvironmentObject var book: ContactBook
    let label: String
    let address: String
    @State private var open = false
    @State private var copied = false

    static func short(_ a: String) -> String { a.count > 24 ? "\(a.prefix(10))…\(a.suffix(8))" : a }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { open.toggle() }
                copied = false
            } label: {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(label).font(.subheadline).foregroundStyle(Theme.muted)
                        Spacer(minLength: 20)
                        VStack(alignment: .trailing, spacing: 2) {
                            if let name = book.named(address)?.name {
                                Text(name).font(.subheadline.weight(.semibold))
                            }
                            Text(Self.short(address)).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.muted)
                        }
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Theme.muted)
                    }
                    if open {
                        Text(address).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.bottom, open ? 6 : 12)
            if open {
                HStack {
                    Spacer()
                    Button {
                        UIPasteboard.general.string = address
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption.weight(.semibold))
                    }
                }
                .padding(.bottom, 12)
            }
            Divider()
        }
    }
}

