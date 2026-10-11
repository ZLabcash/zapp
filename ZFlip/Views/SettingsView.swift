import SwiftUI

/// Settings, in Home's cards: the devices to sign with, the wallet (address book,
/// currency, sync, server), appearance, and the version with its notes.
struct SettingsView: View {
    @EnvironmentObject var wallet: WalletModel
    @EnvironmentObject var book: ContactBook
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("currency") private var currency = "usd"
    @AppStorage(AppLanguage.key) private var language = ""
    @AppStorage(WalletModel.autoBroadcastKey) private var autoBroadcast = true
    @State private var broadcastInfo = false
    // Filming: open the language or currency page straight away.
    @State private var demoLanguage = Demo.on("settings-lang")
    @State private var demoCurrency = Demo.on("settings-currency")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    header("Devices")
                    DevicesCard()
                }
                section("Appearance") {
                    HStack(spacing: 8) {
                        chip("System", icon: "circle.lefthalf.filled", tag: 0)
                        chip("Light", icon: "sun.max.fill", tag: 1)
                        chip("Dark", icon: "moon.fill", tag: 2)
                    }
                }
                section("Language") {
                    NavigationLink { LanguageView() } label: {
                        SettingsRow(icon: "globe", title: "Language", value: AppLanguage.name(AppLanguage.effective),
                                    flag: AppLanguage.flag(AppLanguage.effective), chevron: "chevron.right")
                    }
                    .buttonStyle(.plain)
                }
                section("Wallet") {
                    NavigationLink { AllActivityView() } label: {
                        SettingsRow(icon: "list.bullet.rectangle.portrait.fill", title: "All activity",
                                    value: wallet.activity.isEmpty ? nil : "\(wallet.activity.count)", chevron: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    Divider()
                    NavigationLink { ContactsView() } label: {
                        SettingsRow(icon: "person.2.fill", title: "Address book",
                                    value: book.contacts.isEmpty ? nil : "\(book.contacts.count)", chevron: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    Divider()
                    NavigationLink { CurrencyView() } label: {
                        SettingsRow(icon: "dollarsign.circle.fill", title: "Currency", badge: currency.uppercased(), chevron: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    Divider()
                    NavigationLink { SyncDetailView() } label: {
                        SettingsRow(icon: "arrow.triangle.2.circlepath", title: "Synced",
                                    value: wallet.syncError != nil ? String(localized: "Offline") : wallet.synced ? String(localized: "Up to date") : "\(Int(wallet.syncProgress * 100))%",
                                    chevron: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    Divider()
                    Toggle(isOn: $autoBroadcast) {
                        HStack(spacing: 12) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                                .frame(width: 30, height: 30).background(Theme.zcash).clipShape(RoundedRectangle(cornerRadius: 8))
                            HStack(spacing: 6) {
                                Text("Automatic broadcast").font(.subheadline.weight(.semibold))
                                Button { broadcastInfo = true } label: {
                                    Image(systemName: "info.circle").foregroundStyle(Theme.muted)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("About automatic broadcast")
                                .popover(isPresented: $broadcastInfo) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("Automatic broadcast").font(.headline)
                                        Text("Your hardware wallet signs payments without ever going online. Broadcasting is the next step: this app sends the signed transaction to the Zcash network.")
                                        Text("On: it leaves as soon as your device has signed it.")
                                        Text("Off: every signed payment waits in Activity. You broadcast it or discard it when you decide. Without network, it always waits.")
                                        Text("A signed payment expires after about 40 blocks (around 50 minutes). Until it is broadcast, nothing has left your wallet.")
                                            .foregroundStyle(Theme.muted)
                                    }
                                    .font(.subheadline)
                                    .padding(18)
                                    .frame(width: 310)
                                    .presentationCompactAdaptation(.popover)
                                }
                            }
                        }
                    }
                    .tint(Theme.zcash)
                    Divider()
                    NavigationLink { ServerView() } label: {
                        SettingsRow(icon: "server.rack", title: "Server", value: WalletModel.server.components(separatedBy: ":").first,
                                    chevron: "chevron.right")
                    }
                    .buttonStyle(.plain)
                }
                section("About") {
                    NavigationLink { ReleaseNotesView() } label: {
                        SettingsRow(icon: "info.circle.fill", title: "Version", value: Self.version, chevron: "chevron.right")
                    }
                    .buttonStyle(.plain)
                }
                Button(role: .destructive) { confirmForget = true } label: {
                    Text("Forget this wallet")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red.opacity(0.12))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
        .navigationDestination(isPresented: $demoLanguage) { LanguageView() }
        .navigationDestination(isPresented: $demoCurrency) { CurrencyView() }
        .confirmationDialog("Forget this wallet?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                Task {
                    await wallet.forget()
                    dismiss()
                }
            }
        } message: {
            Text("Removes the watch-only wallet from this phone. Your funds stay safe: the keys are on your Flipper.")
        }
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title).textCase(.uppercase).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted).padding(.leading, 4)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(title)
            SettingsCard(content: content)
        }
    }

    private func chip(_ title: LocalizedStringKey, icon: String, tag: Int) -> some View {
        Button { appearance = tag } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(appearance == tag ? Color.black : Color.primary)
            .background(appearance == tag ? Theme.zcash : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

/// An icon tile, a title, and on the right a value or a badge and a chevron.
struct SettingsRow: View {
    let icon: String
    let title: LocalizedStringKey
    var value: String? = nil
    var badge: String? = nil
    var flag: String? = nil
    var chevron: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 30, height: 30)
                .background(Theme.zcash)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            if let flag { Flag(name: flag, height: 16) }
            if let value { Text(value).font(.subheadline).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1) }
            if let badge {
                Text(badge)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.zcash.opacity(0.18))
                    .foregroundStyle(Theme.zcash)
                    .clipShape(Capsule())
            }
            if let chevron { Image(systemName: chevron).font(.caption.weight(.bold)).foregroundStyle(Theme.muted) }
        }
        .contentShape(Rectangle())
    }
}

/// Where the sync stands, in blocks.
struct SyncDetailView: View {
    @EnvironmentObject var wallet: WalletModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsCard {
                    HStack(spacing: 14) {
                        ZStack {
                            Ring(progress: wallet.synced ? 1 : Double(wallet.syncProgress), lineWidth: 5)
                            Text(wallet.synced ? "✓" : "\(Int(wallet.syncProgress * 100))%")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .frame(width: 54, height: 54)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(wallet.syncError != nil ? "Can't reach the server" : wallet.synced ? "Up to date" : "Syncing")
                                .font(.headline)
                            Text(wallet.syncError ?? String(localized: "Your phone reads the chain to find this wallet's payments. Nothing about you is sent."))
                                .font(.footnote).foregroundStyle(wallet.syncError == nil ? Theme.muted : .orange)
                        }
                    }
                }
                SettingsCard {
                    SettingsRow(icon: "cube.fill", title: "Latest block", value: wallet.tipHeight > 0 ? wallet.tipHeight.formatted() : "…")
                    Divider()
                    SettingsRow(icon: "checkmark.seal.fill", title: "Scanned up to", value: wallet.scannedHeight > 0 ? wallet.scannedHeight.formatted() : "…")
                    Divider()
                    SettingsRow(icon: "flag.fill", title: "Scanning from block", value: (wallet.pairing?.birthday ?? 0).formatted())
                    Divider()
                    SettingsRow(icon: "server.rack", title: "Server", value: WalletModel.server)
                }
                Text("The wallet starts at the block where it was created: older blocks can't hold its funds.")
                    .font(.caption).foregroundStyle(Theme.muted).padding(.horizontal, 4)
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Synced")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
    }
}

/// The lightwalletd server to sync from, and the explorer transactions open on.
struct ServerView: View {
    @EnvironmentObject var wallet: WalletModel
    @State private var server = WalletModel.server
    @State private var customServer = ""
    @AppStorage("zapp.explorer") private var explorer = WalletModel.explorers[0].template
    @State private var customExplorer = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SERVER").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted).padding(.leading, 4)
                    SettingsCard {
                        ForEach(Array(WalletModel.servers.enumerated()), id: \.offset) { i, s in
                            if i > 0 { Divider() }
                            option(s.components(separatedBy: ":").first ?? s, selected: server == s) { choose(server: s) }
                        }
                        Divider()
                        HStack {
                            TextField("host:port", text: $customServer)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .font(.subheadline.monospaced())
                            Button("Use") { choose(server: customServer) }
                                .font(.subheadline.weight(.semibold))
                                .disabled(customServer.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    Text("Your phone syncs from this lightwalletd server. Changing it restarts the sync where it stopped.")
                        .font(.caption).foregroundStyle(Theme.muted).padding(.horizontal, 4)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("EXPLORER").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted).padding(.leading, 4)
                    SettingsCard {
                        ForEach(Array(WalletModel.explorers.enumerated()), id: \.offset) { i, e in
                            if i > 0 { Divider() }
                            option(e.name, detail: URL(string: e.template)?.host, selected: explorer == e.template) {
                                explorer = e.template
                            }
                        }
                        Divider()
                        HStack {
                            TextField("https://…/tx/{txid}", text: $customExplorer)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .font(.subheadline.monospaced())
                            Button("Use") { explorer = customExplorer.trimmingCharacters(in: .whitespaces) }
                                .font(.subheadline.weight(.semibold))
                                .disabled(URL(string: customExplorer) == nil || customExplorer.isEmpty)
                        }
                    }
                    Text("Transactions open there. {txid} stands for the transaction id.")
                        .font(.caption).foregroundStyle(Theme.muted).padding(.horizontal, 4)
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
        .onAppear {
            if !WalletModel.servers.contains(server) { customServer = server }
            if !WalletModel.explorers.contains(where: { $0.template == explorer }) { customExplorer = explorer }
        }
    }

    private func choose(server s: String) {
        server = s.contains(":") ? s : s + ":443"
        Task { await wallet.switchServer(to: server) }
    }

    private func option(_ title: String, detail: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let detail { Text(detail).font(.caption).foregroundStyle(Theme.muted) }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.zcash : Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What changed, version by version.
struct ReleaseNotesView: View {
    static var notes: [(version: String, items: [String])] = [
        ("0.1.0", [
            String(localized: "Pair with ZFlip on a Flipper Zero over Bluetooth; it signs every payment."),
            String(localized: "Shielded balance, hidden until your Flipper is connected; tap it for its value in your currency."),
            String(localized: "Receive follows the address on your Flipper; ▶ there makes a new one."),
            String(localized: "Send with clear checks on the amount and the network fee, a QR scanner and an address book."),
            String(localized: "Activity with confirmations; each transaction opens on your explorer."),
            String(localized: "Choice of server and explorer; light, dark or system appearance."),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Self.notes, id: \.version) { note in
                    SettingsCard {
                        HStack {
                            Text("Version \(note.version)").font(.headline)
                            if note.version == SettingsView.version {
                                Text("Installed").font(.caption2.weight(.bold))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Theme.scan.opacity(0.2)).foregroundStyle(Theme.scan).clipShape(Capsule())
                            }
                        }
                        ForEach(note.items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(Theme.zcash).frame(width: 6, height: 6)
                                Text(item).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("What's new")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
    }
}

/// A flag (4:3, flag-icons SVG kept as vectors), with softly rounded corners.
struct Flag: View {
    let name: String
    var height: CGFloat = 21

    var body: some View {
        Image("Flags/\(name)")
            .resizable()
            .aspectRatio(4 / 3, contentMode: .fill)
            .frame(width: height * 4 / 3, height: height)
            .clipShape(RoundedRectangle(cornerRadius: height * 0.18))
            .overlay(RoundedRectangle(cornerRadius: height * 0.18).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            .environment(\.layoutDirection, .leftToRight) // flags never mirror
    }
}

/// One choice in a list: flag (or icon), a title, a subtitle, a check when selected.
private struct ChoiceRow: View {
    var flag: String?
    var icon: String?
    let title: String
    var subtitle: String?
    var trailing: String?
    let selected: Bool

    var body: some View {
        HStack(spacing: 14) {
            if let flag {
                Flag(name: flag, height: 24)
            } else if let icon {
                Image(systemName: icon).font(.title3).foregroundStyle(Theme.zcash).frame(width: 32, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.subheadline.weight(.semibold))
                if let subtitle { Text(verbatim: subtitle).font(.caption).foregroundStyle(Theme.muted) }
            }
            Spacer()
            if let trailing { Text(verbatim: trailing).font(.subheadline).foregroundStyle(Theme.muted).monospacedDigit() }
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Theme.zcash : Theme.muted.opacity(0.5))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Settings → Language: the system's, or one of the 13 ZApp speaks, applied at once.
struct LanguageView: View {
    @AppStorage(AppLanguage.key) private var language = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            SettingsCard {
                ForEach(Array(AppLanguage.codes.enumerated()), id: \.element) { i, code in
                    if i > 0 { Divider() }
                    Button { choose(code) } label: {
                        // The subtitle is in the app's language, not the phone's.
                        ChoiceRow(flag: AppLanguage.flag(code), title: AppLanguage.name(code),
                                  subtitle: AppLanguage.effectiveLocale.localizedString(forIdentifier: code)?.capitalized(with: AppLanguage.effectiveLocale),
                                  selected: AppLanguage.effective == code)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
    }

    private func choose(_ code: String) {
        guard code != AppLanguage.effective else { return dismiss() }
        // The whole app is rebuilt in the new language; it reopens on Settings.
        AppLanguage.reopenSettingsAfterRebuild()
        AppLanguage.apply(code)
        language = code
    }
}

/// Settings → Currency: what the balance is shown in, with 1 ZEC's price in each.
struct CurrencyView: View {
    @EnvironmentObject var prices: PriceService
    @AppStorage("currency") private var currency = "usd"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            SettingsCard {
                ForEach(Array(PriceService.currencies.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { Divider() }
                    Button {
                        currency = c.code
                        dismiss() // back to Settings
                    } label: {
                        ChoiceRow(flag: c.flag, title: c.code.uppercased(), subtitle: c.name.prefix(1).uppercased(with: AppLanguage.effectiveLocale) + c.name.dropFirst(),
                                  trailing: prices.format(zatoshi: 100_000_000, in: c.code), selected: currency == c.code)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            // CoinGecko's attribution for its free API: one line, small mark.
            Link(destination: URL(string: "https://www.coingecko.com/en/api")!) {
                HStack(spacing: 6) {
                    Text("Fetched from").foregroundStyle(Theme.muted)
                    Image("CoinGecko").resizable().scaledToFit().frame(width: 16, height: 16)
                    Text(verbatim: "CoinGecko").fontWeight(.semibold).foregroundStyle(Theme.ink)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
        .task { await prices.refreshIfStale() }
    }
}
