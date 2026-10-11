import SwiftUI
import ZcashLightClientKit

/// Home: today's activity (or, on a quiet day, the last few), and a way to see everything.
struct ActivityCard: View {
    @EnvironmentObject var wallet: WalletModel
    @State private var selected: WalletModel.ActivityItem?

    private var recent: (title: LocalizedStringKey, items: [WalletModel.ActivityItem]) {
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
            if wallet.activity.isEmpty {
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
    }
}

/// Home, between Receive/Send and the activity: signed payments waiting for a decision.
struct BroadcastCard: View {
    @EnvironmentObject var wallet: WalletModel
    @State private var selected: WalletModel.PendingBroadcast?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("To broadcast").font(.headline)
                Text("\(wallet.pendingHere.count)").font(.caption.weight(.bold)).foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange).clipShape(Capsule())
                Spacer()
            }
            ForEach(wallet.pendingHere) { p in
                Button { selected = p } label: { PendingRow(p: p) }.buttonStyle(.plain)
                if p.id != wallet.pendingHere.last?.id { Divider() }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .sheet(item: $selected) { PendingView(p: $0) }
    }
}

/// A signed payment in the broadcast block (shown in full even with the hardware wallet
/// away: the user signed it and decides on it): "Sent to …", the amount, and under it the time
/// left to broadcast, as a line that empties and a live countdown.
struct PendingRow: View {
    @EnvironmentObject var wallet: WalletModel
    @EnvironmentObject var book: ContactBook
    let p: WalletModel.PendingBroadcast

    var body: some View {
        let first = p.payments.first?.address ?? ""
        let to = book.named(first)?.name ?? wallet.walletName(for: first) ?? String(first.prefix(7)) + "…"
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(wallet.expired(p) ? Color.red : Color.orange).clipShape(Circle())
                Text("Sent to \(to + (p.payments.count > 1 ? " +\(p.payments.count - 1)" : ""))")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("−" + Zatoshi(p.total).zecString)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            BroadcastTimer(p: p)
        }
        .contentShape(Rectangle())
    }
}

/// The time left to broadcast: a line that empties, and the countdown beside it, live.
struct BroadcastTimer: View {
    @EnvironmentObject var wallet: WalletModel
    let p: WalletModel.PendingBroadcast

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let left = wallet.secondsLeft(p)
            let expired = wallet.expired(p) || left == 0
            let color: Color = expired ? .red : wallet.windowLeft(p) < 0.25 ? .orange : Theme.zcash
            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.muted.opacity(0.2))
                        Capsule().fill(color).frame(width: geo.size.width * wallet.windowLeft(p))
                    }
                }
                .frame(height: 4)
                .environment(\.layoutDirection, .leftToRight)
                Text(expired ? String(localized: "Expired") : String(format: "%d:%02d", left / 60, left % 60))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(expired ? .red : Theme.ink)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
    }
}

/// A signed payment, as a sheet like Sent's.
struct PendingView: View {
    @Environment(\.dismiss) private var dismiss
    let p: WalletModel.PendingBroadcast
    @State private var height: CGFloat = 620

    var body: some View {
        ScrollView {
            PendingPanel(p: p, onClose: { dismiss() })
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
        }
        .background(Theme.background.ignoresSafeArea())
        .presentationDetents([.height(height), .large])
        .presentationDragIndicator(.visible)
    }
}

/// The signed payment laid out like a Sent transaction, with the decision at the bottom:
/// Cancel, or hold to broadcast. It stays saved on this phone until then (or until it expires).
struct PendingPanel: View {
    @EnvironmentObject var wallet: WalletModel
    let p: WalletModel.PendingBroadcast
    var onClose: () -> Void
    /// Right after signing (in Send): offer to decide later.
    var showsLater = false
    @State private var working = false
    @State private var error: String?
    @State private var confirmCancel = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let expired = wallet.expired(p)
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2.weight(.bold)).foregroundStyle(.black)
                        .frame(width: 54, height: 54)
                        .background(expired ? Color.red : Color.orange).clipShape(Circle())
                    Text(expired ? "Expired" : "Signed · not broadcast").font(.headline).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        Text("−" + Zatoshi(p.total).zecAmount)
                            .font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                        ZecLogo().frame(width: 28, height: 28)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(p.payments.enumerated()), id: \.offset) { i, pay in
                        AddressRow(label: p.payments.count > 1 ? "To (\(i + 1))" : "To", address: pay.address)
                        if p.payments.count > 1 { row("Amount", Zatoshi(pay.zatoshi).zecString) }
                        if !pay.memo.isEmpty { row("Message", pay.memo) }
                    }
                    if let fee = p.fee { row("Network fee", Zatoshi(fee).zecString) }
                    row("Signed", p.created.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: AppLanguage.effectiveLocale))
                        + (p.signer.map { " · \($0)" } ?? ""))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Broadcast before").font(.subheadline).foregroundStyle(Theme.muted)
                        BroadcastTimer(p: p)
                    }
                    .padding(.vertical, 12)
                    Divider()
                    HStack(spacing: 8) {
                        Text("Network").font(.subheadline).foregroundStyle(Theme.muted)
                        Spacer()
                        Circle().fill(wallet.online ? Theme.scan : Color.gray).frame(width: 8, height: 8)
                        Text(wallet.online ? "Online" : "Offline: saved on this phone").font(.subheadline)
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 16)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Button { confirmCancel = true } label: {
                        Text(expired ? "Remove" : "Cancel")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.red.opacity(0.12))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    if !expired {
                        Button {
                            working = true
                            error = nil
                            Task {
                                error = await wallet.broadcast(p)
                                working = false
                                if error == nil { onClose() }
                            }
                        } label: {
                            Text(working ? "Broadcasting…" : "Broadcast").primaryButton()
                        }
                        .disabled(working || !wallet.online)
                        .opacity(working || !wallet.online ? 0.5 : 1)
                    }
                }
                if showsLater {
                    Button("Decide later", action: onClose)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                }
            }
        }
        .confirmationDialog("Cancel this payment?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel payment", role: .destructive) {
                wallet.discard(p)
                onClose()
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("It was never broadcast: nothing is sent and your balance doesn't change.")
        }
    }

    private func row(_ k: LocalizedStringKey, _ v: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Text(k).font(.subheadline).foregroundStyle(Theme.muted)
                Spacer(minLength: 20)
                Text(v).font(.subheadline).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
            .padding(.vertical, 12)
            Divider()
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
            TxIcon(tx: tx, size: 34)
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
/// A transaction's icon, by where it is: an hourglass turning while it waits in the mempool,
/// a check with an arc turning around it while it confirms, then the
/// arrow (sent or received) once it's settled.
struct TxIcon: View {
    @EnvironmentObject var wallet: WalletModel
    let tx: WalletModel.ActivityItem
    let size: CGFloat

    var body: some View {
        let color = tx.sent ? Color(white: 0.75) : Theme.zcash
        let glyph = Font.system(size: size * 0.4, weight: .bold)
        if tx.expired {
            Image(systemName: "xmark").font(glyph).foregroundStyle(.white)
                .frame(width: size, height: size).background(Color.red.opacity(0.8)).clipShape(Circle())
        } else if let n = wallet.confirmations(tx), n >= 10 {
            Image(systemName: tx.sent ? "arrow.up" : "arrow.down").font(glyph).foregroundStyle(.black)
                .frame(width: size, height: size).background(color).clipShape(Circle())
        } else if let n = wallet.confirmations(tx) {
            ConfirmingRing(confirmations: n, color: color, size: size)
        } else {
            Hourglass().foregroundStyle(.black).padding(size * 0.26)
                .frame(width: size, height: size).background(color).clipShape(Circle())
        }
    }
}

/// Confirming: a check in the circle and a short arc running around it while it confirms.
struct ConfirmingRing: View {
    let confirmations: Int
    let color: Color
    let size: CGFloat
    @State private var spin = false

    var body: some View {
        let ring = max(2, size * 0.08)
        ZStack {
            Circle().fill(color.opacity(0.35))
            Image(systemName: "checkmark").font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(Theme.ink)
            Circle().stroke(Theme.muted.opacity(0.25), lineWidth: ring)
            Circle().trim(from: 0, to: 0.12)
                .stroke(Theme.zcash.opacity(0.9), style: StrokeStyle(lineWidth: ring, lineCap: .round))
                .rotationEffect(.degrees(spin ? 270 : -90))
                .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: spin)
        }
        .frame(width: size, height: size)
        .environment(\.layoutDirection, .leftToRight)
        .onAppear { spin = true }
    }
}

@MainActor
enum TxStatus {
    static func short(_ tx: WalletModel.ActivityItem, _ wallet: WalletModel) -> String {
        if tx.expired { return String(localized: "Expired") }
        guard let n = wallet.confirmations(tx) else { return String(localized: "Pending · in the mempool") }
        if n < 10 { return String(localized: "Confirming \(n)/10") }
        return tx.blockTime.map { Date(timeIntervalSince1970: $0).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: AppLanguage.effectiveLocale)) } ?? "Confirmed"
    }

    static func long(_ tx: WalletModel.ActivityItem, _ wallet: WalletModel) -> String {
        if tx.expired { return String(localized: "Expired, never mined") }
        guard let n = wallet.confirmations(tx) else { return String(localized: "Pending, in the mempool") }
        if n < 10 { return String(localized: "Confirming, \(n) of 10 confirmations") }
        return String(localized: "Confirmed · \(n.formatted()) confirmations")
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
                    TxIcon(tx: tx, size: 54)
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
                            row("To", String(localized: "Shielded recipient"))
                        }
                        ForEach(Array(recipients.enumerated()), id: \.offset) { i, r in
                            AddressRow(label: recipients.count > 1 ? "To (\(i + 1))" : "To", address: r)
                        }
                        if let fee = tx.fee { row("Network fee", Zatoshi(fee).zecString) }
                    } else {
                        row("From", String(localized: "Shielded sender"))
                    }
                    row("Status", TxStatus.long(tx, wallet))
                    if let t = tx.blockTime {
                        row("Date", Date(timeIntervalSince1970: t).formatted(Date.FormatStyle(date: .long, time: .shortened, locale: AppLanguage.effectiveLocale)))
                    }
                    if tx.memos.isEmpty {
                        row("Message", String(localized: "None"))
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

    private func row(_ k: LocalizedStringKey, _ v: String, mono: Bool = false) -> some View {
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

    private var days: [(String, [WalletModel.ActivityItem])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let items = wallet.activity.filter { tx in
            q.isEmpty || tx.memos.contains { $0.lowercased().contains(q) } || tx.txid.hasPrefix(q)
                || Zatoshi(tx.zatoshi).zecString.contains(q)
        }
        var out: [(String, [WalletModel.ActivityItem])] = []
        for tx in items {
            let day = tx.blockTime.map { Date(timeIntervalSince1970: $0) }.map { d in
                Calendar.current.isDateInToday(d) ? String(localized: "Today") : Calendar.current.isDateInYesterday(d) ? String(localized: "Yesterday") : d.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: AppLanguage.effectiveLocale))
            } ?? String(localized: "Pending")
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
                if days.isEmpty {
                    Text(query.isEmpty ? "No transactions yet." : "Nothing matches “\(query)”.").font(.footnote).foregroundStyle(Theme.muted)
                }
                ForEach(days, id: \.0) { day, items in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(day.localizedUppercase).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted).padding(.leading, 4)
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
    }
}

/// A recipient address, short (with the contact's name when known); tap to see it whole and copy it.
struct AddressRow: View {
    @EnvironmentObject var book: ContactBook
    @EnvironmentObject var wallet: WalletModel
    let label: LocalizedStringKey
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
                            if let name = book.named(address)?.name ?? wallet.walletName(for: address) {
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

