import SwiftUI
import ZcashLightClientKit

/// The wallet switcher: every wallet on this phone with its kind and balance; tap one to
/// make it active, swipe to rename or remove it, or add another.
struct WalletsSheet: View {
    @EnvironmentObject var wallet: WalletModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: WalletModel.Pairing?
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
                            Button { renaming = w } label: { Label("Rename", systemImage: "pencil") }
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
            .sheet(item: $renaming) { RenameWalletSheet($0) }
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

/// Rename a wallet: a small sheet with the name and Save, readable in light and dark.
struct RenameWalletSheet: View {
    @EnvironmentObject var wallet: WalletModel
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var name: String
    @FocusState private var focused: Bool

    init(_ w: WalletModel.Pairing) {
        id = w.id
        _name = State(initialValue: w.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Rename wallet").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                        .frame(width: 32, height: 32).background(Theme.card).clipShape(Circle())
                }
                .accessibilityLabel("Cancel")
            }
            HStack {
                TextField("Name", text: $name)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
                if !name.isEmpty {
                    Button { name = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }
                        .buttonStyle(.plain)
                }
            }
            .padding(14).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
            Button(action: save) { Text("Save").primaryButton() }
        }
        .padding(20)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        .onAppear { focused = true }
    }

    private func save() {
        wallet.rename(id, to: name)
        dismiss()
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
                    Image(systemName: "wallet.bifold.fill").font(.title2).foregroundStyle(Theme.zcash)
                } else {
                    FlipperZeroIcon(light: .green, pulsing: false)
                }
            }
            .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: w.displayName).font(.subheadline.weight(.semibold))
                Text(w.isPhone ? "On this phone" : "Flipper Zero").font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            // A Flipper wallet's balance only while its Flipper is connected.
            let visible = w.isPhone || wallet.linkedWallet == w.id
            Text(visible ? (wallet.balances[w.id] ?? .zero).zecString : "•••• ZEC")
                .font(.subheadline.monospacedDigit()).foregroundStyle(Theme.muted)
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(active ? Theme.zcash : Theme.muted.opacity(0.5))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// First launch: the logo draws itself, the wordmark comes in, then the line, Start and
/// the language menu fade in, all on this one screen.
struct WelcomeView: View {
    /// Played once per launch: a language change rebuilds the screen without replaying it.
    @MainActor private static var played = false
    @State private var progress: CGFloat = Self.played ? 1 : 0
    @State private var wordmark = Self.played
    @State private var rest = Self.played
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                LanguageMenu()
            }
            .opacity(rest ? 1 : 0)
            Spacer()
            VStack(spacing: 14) {
                Shield(progress: progress).frame(width: 112, height: 112)
                Text(verbatim: "ZApp").font(.system(size: 44, weight: .heavy, design: .rounded))
                    .opacity(wordmark ? 1 : 0)
                    .offset(y: wordmark ? 0 : 8)
            }
            Text("Private by default.")
                .font(.title3.weight(.semibold)).foregroundStyle(Theme.muted)
                .padding(.top, 10)
                .opacity(rest ? 1 : 0)
            Spacer()
            Button { started = true } label: {
                Text("Start").primaryButton()
            }
            .opacity(rest ? 1 : 0)
            .offset(y: rest ? 0 : 12)
            .disabled(!rest)
        }
        .padding(20)
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $started) { GetStartedView() }
        .task {
            guard !Self.played else { return }
            Self.played = true
            withAnimation(.easeInOut(duration: 1.0)) { progress = 1 }
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.spring(duration: 0.4)) { wordmark = true }
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.easeOut(duration: 0.6)) { rest = true }
        }
    }
}

/// The language picker in the welcome screen's corner: flag, then the list.
struct LanguageMenu: View {
    @AppStorage(AppLanguage.key) private var language = ""

    var body: some View {
        Menu {
            ForEach(AppLanguage.codes, id: \.self) { code in
                Button {
                    AppLanguage.apply(code)
                    language = code
                } label: {
                    if code == AppLanguage.effective {
                        Label(AppLanguage.name(code), systemImage: "checkmark")
                    } else {
                        Text(AppLanguage.name(code))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Flag(name: AppLanguage.flag(AppLanguage.effective), height: 16)
                Text(AppLanguage.name(AppLanguage.effective)).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.card).clipShape(Capsule())
        }
    }
}

/// After Start: how to get a wallet.
struct GetStartedView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            WalletOptions(onDone: {}, showsSoon: false)
            Spacer()
        }
        .padding(20)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Your wallet")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
    }
}

/// Add a wallet (from the wallet switcher): made here, restored from its words, held by a
/// device, or shared between several (soon).
struct AddWalletView: View {
    var onDone: () -> Void

    var body: some View {
        ScrollView {
            WalletOptions(onDone: onDone, showsSoon: true).padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Add a wallet")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
    }
}

/// The ways to get a wallet, as cards.
struct WalletOptions: View {
    @EnvironmentObject var wallet: WalletModel
    var onDone: () -> Void
    var showsSoon: Bool
    @State private var busy = false
    @State private var error: String?
    @State private var picking = false

    /// The distinct seeds already here (each can grow another account).
    private var seeds: [[WalletModel.Pairing]] {
        var order: [[UInt8]] = []
        var by: [[UInt8]: [WalletModel.Pairing]] = [:]
        for w in wallet.wallets where w.isPhone {
            if by[w.seedFingerprint] == nil { order.append(w.seedFingerprint) }
            by[w.seedFingerprint, default: []].append(w)
        }
        return order.map { by[$0]! }
    }

    var body: some View {
        VStack(spacing: 12) {
            if !seeds.isEmpty {
                Button {
                    if seeds.count == 1 { Task { await derive(seeds[0]) } } else { picking = true }
                } label: {
                    OptionCard(title: "Add an account", busy: busy) { symbol("plus") }
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            NavigationLink { CreateWalletView(onDone: onDone) } label: {
                OptionCard(title: "Create a new wallet", subtitle: "A brand-new wallet, with its own 24-word recovery phrase.") { symbol("wallet.bifold.fill") }
            }
            .buttonStyle(.plain)
            NavigationLink { RestoreWalletView(onDone: onDone) } label: {
                OptionCard(title: "Import a recovery phrase", subtitle: "Bring back a wallet from its 24-word recovery phrase.") { symbol("arrow.counterclockwise") }
            }
            .buttonStyle(.plain)
            NavigationLink { ConnectDeviceView(onDone: onDone) } label: {
                OptionCard(title: "Connect a device", subtitle: "Any compatible hardware signer that keeps its keys.") { symbol("dot.radiowaves.left.and.right") }
            }
            .buttonStyle(.plain)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
        }
        .confirmationDialog("From which wallet's recovery phrase?", isPresented: $picking, titleVisibility: .visible) {
            ForEach(seeds, id: \.first!.id) { group in
                Button(group.first!.displayName) { Task { await derive(group) } }
            }
        }
    }

    private func derive(_ group: [WalletModel.Pairing]) async {
        busy = true
        defer { busy = false }
        do {
            try await wallet.addAccount(from: group[0])
            onDone()
        } catch {
            self.error = (error as? Bridge.Failure)?.message ?? error.localizedDescription
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.title3.weight(.semibold)).foregroundStyle(.black)
            .frame(width: 44, height: 44).background(Theme.zcash).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// One choice: an icon, a title and a line about it; greyed with a badge when it's coming,
/// or a spinner while it's working.
struct OptionCard<Icon: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var soon = false
    var busy = false
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 14) {
            icon().frame(width: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            if soon {
                Text("Coming soon").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.zcash.opacity(0.2)).foregroundStyle(Theme.zcash).clipShape(Capsule())
            }
            Spacer()
            if busy { ProgressView() }
            else if !soon { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.muted) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(minHeight: 72)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .opacity(soon ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

/// Connect a device: the cold wallets ZApp can watch and send through.
struct ConnectDeviceView: View {
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            NavigationLink { PairView(onDone: onDone).backArrow() } label: {
                OptionCard(title: "Flipper Zero") {
                    FlipperZeroIcon(light: .green, pulsing: false).frame(width: 52)
                }
            }
            .buttonStyle(.plain)
            OptionCard(title: "Kindle", soon: true) {
                KindleIcon().frame(width: 30, height: 40)
            }
            Spacer()
        }
        .padding(20)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Connect a device")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
    }
}

/// The opening animation, on every launch: the shield draws itself, the Z, then the scan line,
/// the wordmark comes in, and the app shows underneath.
struct Splash: View {
    var finished: () -> Void
    @State private var progress: CGFloat = 0
    @State private var wordmark = false

    var body: some View {
        VStack(spacing: 14) {
            Shield(progress: progress).frame(width: 112, height: 112)
            Text(verbatim: "ZApp").font(.system(size: 44, weight: .heavy, design: .rounded))
                .opacity(wordmark ? 1 : 0)
                .offset(y: wordmark ? 0 : 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .task {
            withAnimation(.easeInOut(duration: 1.0)) { progress = 1 }
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.spring(duration: 0.4)) { wordmark = true }
            try? await Task.sleep(nanoseconds: 700_000_000)
            finished()
        }
    }
}

/// Copies a recovery phrase for a password manager: kept on this phone only (not Handoff's
/// universal clipboard) and cleared after two minutes.
struct CopyPhraseButton: View {
    let phrase: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.setItems([["public.utf8-plain-text": phrase]],
                                          options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.card).clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}

/// Recovery words in numbered cells, three columns so all 24 fit on one screen.
struct WordGrid: View {
    let words: [String]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                HStack(spacing: 4) {
                    Text("\(i + 1)").font(.caption2.monospacedDigit()).foregroundStyle(Theme.muted).frame(width: 18, alignment: .trailing)
                    Text(verbatim: w).font(.footnote.weight(.semibold).monospaced()).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7).padding(.horizontal, 6)
                .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
    }
}

/// A new phone wallet, step 1: its 24 words, all on screen, to write down.
/// Then step 2 checks three of them, step 3 names the wallet.
struct CreateWalletView: View {
    var onDone: () -> Void
    @State private var phrase = ""
    @State private var revealed = false
    @State private var checking = false
    @State private var asked: [Int] = []

    private var words: [String] { phrase.split(separator: " ").map(String.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("These 24 words are your money. Write them on paper, in order, and keep them offline. Anyone who sees them can spend your funds; without them, a lost phone means lost funds.")
                .font(.footnote).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            WordGrid(words: words)
                .blur(radius: revealed ? 0 : 8)
                .overlay {
                    if !revealed {
                        Button { revealed = true } label: {
                            Label("Tap to show the words", systemImage: "eye").primaryButton()
                        }
                        .padding(.horizontal, 40)
                    }
                }
            if revealed { CopyPhraseButton(phrase: phrase) }
            Spacer(minLength: 0)
            Button {
                asked = Array((0..<words.count).shuffled().prefix(3)).sorted()
                checking = true
            } label: {
                Text("I wrote them down").primaryButton()
            }
            .disabled(!revealed)
            .opacity(revealed ? 1 : 0.5)
        }
        .padding(20)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Your recovery phrase")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
        .navigationDestination(isPresented: $checking) {
            CheckWordsView(words: words, asked: asked, phrase: phrase, onDone: onDone)
        }
        .task { if phrase.isEmpty { phrase = (try? WalletModel.newRecoveryPhrase()) ?? "" } }
    }
}

/// Step 2: type three of the words back. The back arrow returns to the words.
struct CheckWordsView: View {
    let words: [String]
    let asked: [Int]
    let phrase: String
    var onDone: () -> Void
    @State private var answers = ["", "", ""]
    @State private var error: String?
    @State private var naming = false
    @FocusState private var focused: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Type these words from your paper.").font(.footnote).foregroundStyle(Theme.muted)
            ForEach(Array(asked.enumerated()), id: \.offset) { k, i in
                TextField(String(localized: "Word #\(i + 1)"), text: $answers[k])
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused, equals: k)
                    .submitLabel(k < 2 ? .next : .done)
                    .onSubmit { focused = k < 2 ? k + 1 : nil }
                    .padding(14).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
            Spacer(minLength: 0)
            Button {
                let ok = asked.enumerated().allSatisfy { k, i in
                    answers[k].trimmingCharacters(in: .whitespaces).lowercased() == words[i]
                }
                if ok { error = nil; naming = true } else {
                    error = String(localized: "A word doesn't match. Check your paper, or go back to the words.")
                }
            } label: {
                Text("Continue").primaryButton()
            }
        }
        .padding(20)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Check your words")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
        .onAppear { focused = 0 }
        .navigationDestination(isPresented: $naming) {
            NameWalletView(phrase: phrase, onDone: onDone)
        }
    }
}

/// Step 3: name the new wallet, then it's made.
struct NameWalletView: View {
    @EnvironmentObject var wallet: WalletModel
    let phrase: String
    var onDone: () -> Void
    @State private var name = String(localized: "My wallet")
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Give it a name to find it among your wallets.").font(.footnote).foregroundStyle(Theme.muted)
            TextField("Wallet name", text: $name)
                .focused($focused)
                .padding(14).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
            Spacer(minLength: 0)
            Button { Task { await create() } } label: {
                HStack(spacing: 8) {
                    if working { ProgressView().tint(.black) }
                    Text(working ? "Creating…" : "Create the wallet")
                }.primaryButton()
            }
            .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(20)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Name your wallet")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
        .onAppear { focused = true }
    }

    private func create() async {
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
                    HStack(spacing: 8) {
                        if working { ProgressView().tint(.black) }
                        Text(working ? "Restoring…" : "Restore")
                    }.primaryButton()
                }
                .disabled(working || ![12, 15, 18, 21, 24].contains(count))
                .opacity([12, 15, 18, 21, 24].contains(count) ? 1 : 0.5)
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Import a recovery phrase")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
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
                WordGrid(words: words)
                if !words.isEmpty { CopyPhraseButton(phrase: words.joined(separator: " ")) }
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
