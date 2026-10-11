import SwiftUI
import ZcashLightClientKit

/// The wallet switcher: every wallet on this phone with its kind and balance; tap one to
/// make it active, swipe to rename or remove it, or add another.
struct WalletsSheet: View {
    @EnvironmentObject var wallet: WalletModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: WalletModel.Pairing?
    @State private var newName = ""
    @State private var removing: WalletModel.Pairing?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(wallet.wallets) { w in
                        Button {
                            Task {
                                try? await wallet.activate(w.id)
                                dismiss()
                            }
                        } label: {
                            WalletRow(w: w, active: w.id == wallet.pairing?.id)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { removing = w } label: { Label("Remove", systemImage: "trash") }
                            Button {
                                newName = w.displayName
                                renaming = w
                            } label: { Label("Rename", systemImage: "pencil") }
                        }
                    }
                }
                Section {
                    NavigationLink { AddWalletView(onDone: { dismiss() }) } label: {
                        Label("Add a wallet", systemImage: "plus.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.zcash)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Wallets")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Rename wallet", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") { if let r = renaming { wallet.rename(r.id, to: newName) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(removing.map { String(localized: "Remove “\($0.displayName)”?") } ?? "",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let r = removing { Task { await wallet.remove(r.id) } }
                }
            } message: {
                Text(removing?.isPhone == true
                     ? "Its recovery phrase is erased from this phone. Without your written 24 words, its funds are lost."
                     : "It's removed from this phone. Your funds stay safe: the keys are on your device.")
            }
        }
    }
}

/// One wallet in a list: its kind (phone or Flipper), name, and balance when it may show.
struct WalletRow: View {
    @EnvironmentObject var wallet: WalletModel
    let w: WalletModel.Pairing
    let active: Bool

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if w.isPhone {
                    Image(systemName: "iphone.gen3").font(.title2).foregroundStyle(Theme.zcash)
                } else {
                    Image(systemName: "cpu").font(.title2).foregroundStyle(.orange)
                }
            }
            .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: w.displayName).font(.subheadline.weight(.semibold))
                Text(w.isPhone ? "On this phone" : "Flipper Zero").font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            // A Flipper wallet's balance only while its Flipper is connected.
            let visible = w.isPhone || (active && wallet.flipperReady)
            Text(visible ? (wallet.balances[w.id] ?? .zero).zecString : "•••• ZEC")
                .font(.subheadline.monospacedDigit()).foregroundStyle(Theme.muted)
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(active ? Theme.zcash : Theme.muted.opacity(0.5))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Add a wallet: made here, restored from its words, or held by a device.
struct AddWalletView: View {
    /// First run: no wallet yet, so a welcome above the choices.
    var welcome = false
    var onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if welcome {
                    Shield().frame(height: 90).padding(.top, 30)
                    Text("ZApp").font(.system(size: 42, weight: .heavy, design: .rounded))
                    Text("A private Zcash wallet. Keep the keys on this phone, or on a cold wallet like a Flipper Zero.")
                        .font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                        .padding(.horizontal).padding(.bottom, 16)
                }
                option("Create a new wallet", "A new recovery phrase, kept on this phone behind Face ID.", "sparkles") {
                    CreateWalletView(onDone: onDone)
                }
                option("Restore a wallet", "From its 12 or 24 words.", "arrow.counterclockwise") {
                    RestoreWalletView(onDone: onDone)
                }
                option("Connect a Flipper Zero", "Keys stay on the Flipper; this phone only sees and prepares.", "dot.radiowaves.left.and.right") {
                    PairView(onDone: onDone)
                }
                soon("Kindle", "An offline wallet on a Kindle, over local Wi-Fi.", "book.closed")
                soon("Multisig", "Several devices must sign together (FROST).", "person.3")
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(welcome ? "" : String(localized: "Add a wallet"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func option<D: View>(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ icon: String, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink(destination: destination) {
            card(title, detail, icon, enabled: true)
        }
        .buttonStyle(.plain)
    }

    private func soon(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ icon: String) -> some View {
        card(title, detail, icon, enabled: false)
    }

    private func card(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ icon: String, enabled: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(.black)
                .frame(width: 42, height: 42).background(enabled ? Theme.zcash : Color.gray).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if !enabled {
                        Text("Coming soon").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.zcash.opacity(0.2)).foregroundStyle(Theme.zcash).clipShape(Capsule())
                    }
                }
                Text(detail).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if enabled { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.muted) }
        }
        .padding(16)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .opacity(enabled ? 1 : 0.55)
    }
}

/// A new phone wallet: name it, write down its 24 words, prove it by typing three of them.
struct CreateWalletView: View {
    @EnvironmentObject var wallet: WalletModel
    var onDone: () -> Void
    @State private var name = String(localized: "My wallet")
    @State private var phrase = ""
    @State private var revealed = false
    @State private var checking = false
    @State private var asked: [Int] = []
    @State private var answers = ["", "", ""]
    @State private var working = false
    @State private var error: String?

    private var words: [String] { phrase.split(separator: " ").map(String.init) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !checking {
                    TextField("Wallet name", text: $name)
                        .padding(14).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("Your recovery phrase").font(.headline)
                    Text("These 24 words are your money. Write them on paper, in order, and keep them offline. Anyone who sees them can spend your funds; without them, a lost phone means lost funds.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                            HStack(spacing: 8) {
                                Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted).frame(width: 22, alignment: .trailing)
                                Text(verbatim: w).font(.subheadline.weight(.semibold).monospaced())
                                Spacer()
                            }
                            .padding(.vertical, 8).padding(.horizontal, 10)
                            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .blur(radius: revealed ? 0 : 8)
                    .overlay {
                        if !revealed {
                            Button { revealed = true } label: {
                                Label("Tap to show the words", systemImage: "eye").primaryButton()
                            }
                            .padding(.horizontal, 40)
                        }
                    }
                    Button {
                        asked = Array((0..<words.count).shuffled().prefix(3)).sorted()
                        answers = ["", "", ""]
                        checking = true
                    } label: {
                        Text("I wrote them down").primaryButton()
                    }
                    .disabled(!revealed || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(revealed ? 1 : 0.5)
                } else {
                    Text("Check your words").font(.headline)
                    Text("Type these words from your paper.").font(.footnote).foregroundStyle(Theme.muted)
                    ForEach(Array(asked.enumerated()), id: \.offset) { k, i in
                        TextField(String(localized: "Word #\(i + 1)"), text: $answers[k])
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(14).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
                    Button { Task { await create() } } label: {
                        Text(working ? "Creating…" : "Create the wallet").primaryButton()
                    }
                    .disabled(working)
                    Button("Show the words again") { checking = false }
                        .font(.footnote).frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("New wallet")
        .navigationBarTitleDisplayMode(.inline)
        .task { if phrase.isEmpty { phrase = (try? WalletModel.newRecoveryPhrase()) ?? "" } }
    }

    private func create() async {
        let ok = asked.enumerated().allSatisfy { k, i in answers[k].trimmingCharacters(in: .whitespaces).lowercased() == words[i] }
        guard ok else {
            error = String(localized: "A word doesn't match. Check your paper, or show the words again.")
            return
        }
        working = true
        defer { working = false }
        do {
            try await wallet.addPhoneWallet(name: name, phrase: phrase, since: nil)
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Restore a wallet from its words (from ZApp, Zashi, Zodl or any ZIP 32 wallet), from
/// about the date it was made.
struct RestoreWalletView: View {
    @EnvironmentObject var wallet: WalletModel
    var onDone: () -> Void
    @State private var name = String(localized: "Restored wallet")
    @State private var phrase = ""
    @State private var since = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var working = false
    @State private var error: String?

    private var count: Int { Bridge.normalized(phrase).split(separator: " ").count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Wallet name", text: $name)
                    .padding(14).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Recovery phrase").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(count) words").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    TextField("word1 word2 word3 …", text: $phrase, axis: .vertical)
                        .lineLimit(4...8)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.body.monospaced())
                        .padding(14).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                DatePicker("Created around", selection: $since, in: ...Date(), displayedComponents: .date)
                    .padding(14).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
                Text("The wallet is scanned from that date. Earlier is safer but takes longer.")
                    .font(.caption).foregroundStyle(Theme.muted)
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
                Button { Task { await restore() } } label: {
                    Text(working ? "Restoring…" : "Restore").primaryButton()
                }
                .disabled(working || ![12, 15, 18, 21, 24].contains(count))
                .opacity([12, 15, 18, 21, 24].contains(count) ? 1 : 0.5)
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Restore a wallet")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func restore() async {
        working = true
        defer { working = false }
        do {
            try await wallet.addPhoneWallet(name: name, phrase: phrase, since: since)
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Settings → Recovery phrase: the active phone wallet's words, after Face ID.
struct RecoveryPhraseView: View {
    @EnvironmentObject var wallet: WalletModel
    @State private var words: [String] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Never share these words. Anyone who has them can spend this wallet's funds.")
                    .font(.footnote).foregroundStyle(.orange)
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.muted) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted).frame(width: 22, alignment: .trailing)
                            Text(verbatim: w).font(.subheadline.weight(.semibold).monospaced())
                            Spacer()
                        }
                        .padding(.vertical, 8).padding(.horizontal, 10)
                        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Recovery phrase")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow { words = [] }
        .task {
            do { words = try wallet.recoveryPhrase().split(separator: " ").map(String.init) } catch { self.error = error.localizedDescription }
        }
        .onDisappear { words = [] }
    }
}
