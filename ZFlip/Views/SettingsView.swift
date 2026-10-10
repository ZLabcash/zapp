import SwiftUI

/// Settings, in the same cards as Home: the device, preferences (appearance,
/// currency), the wallet (address book, sync), and forgetting the wallet.
struct SettingsView: View {
    @EnvironmentObject var wallet: WalletModel
    @EnvironmentObject var prices: PriceService
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("currency") private var currency = "usd"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                deviceCard
                section("Preferences") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Appearance").font(.subheadline.weight(.semibold))
                        HStack(spacing: 8) {
                            chip("System", icon: "circle.lefthalf.filled", tag: 0)
                            chip("Light", icon: "sun.max.fill", tag: 1)
                            chip("Dark", icon: "moon.fill", tag: 2)
                        }
                    }
                    Divider()
                    Menu {
                        Picker("Currency", selection: $currency) {
                            ForEach(PriceService.currencies) { c in
                                Text("\(c.code.uppercased()) · \(c.name)").tag(c.code)
                            }
                        }
                    } label: {
                        row(icon: "dollarsign.circle.fill", title: "Currency",
                            value: currency.uppercased(), chevron: "chevron.up.chevron.down")
                    }
                    .buttonStyle(.plain)
                    if let price = prices.format(zatoshi: 100_000_000, in: currency) {
                        Text("1 ZEC ≈ \(price) · tap your balance to see it in \(currency.uppercased())")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                section("Wallet") {
                    NavigationLink {
                        ContactsView()
                    } label: {
                        row(icon: "person.2.fill", title: "Address book", value: "\(contactsCount)", chevron: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    Divider()
                    row(icon: "arrow.triangle.2.circlepath", title: "Synced", value: wallet.synced ? "Up to date" : "\(Int(wallet.syncProgress * 100))%")
                    Divider()
                    row(icon: "flag.fill", title: "Scanning from block", value: (wallet.pairing?.birthday ?? 0).formatted())
                    Divider()
                    row(icon: "server.rack", title: "Server", value: "zec.rocks")
                }
                section("About") {
                    row(icon: "info.circle.fill", title: "Version", value: version)
                    Divider()
                    Link(destination: URL(string: "https://zscan.cash")!) {
                        row(icon: "magnifyingglass.circle.fill", title: "ZScan explorer", value: "zscan.cash", chevron: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button(role: .destructive) { confirmForget = true } label: {
                        Label("Forget this wallet", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.red.opacity(0.12))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Text("Removes the watch-only wallet from this phone. Your funds stay safe: the keys are on your Flipper.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
        .task { await prices.refreshIfStale() }
        .confirmationDialog("Forget this wallet?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                Task {
                    await wallet.forget()
                    dismiss()
                }
            }
        } message: {
            Text("You can pair your Flipper again at any time.")
        }
    }

    @EnvironmentObject private var book: ContactBook
    private var contactsCount: Int { book.contacts.count }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var deviceCard: some View {
        HStack(spacing: 16) {
            FlipperZeroIcon(light: wallet.flipperReady ? Theme.scan : .gray, pulsing: false).frame(width: 96)
            VStack(alignment: .leading, spacing: 5) {
                Text(wallet.pairing?.flipperName ?? "Flipper Zero").font(.headline)
                HStack(spacing: 6) {
                    Text(wallet.pairing?.network == 1 ? "Testnet" : "Mainnet")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.zcash.opacity(0.2)).clipShape(Capsule())
                    Circle().fill(wallet.flipperReady ? Theme.scan : Color.gray).frame(width: 7, height: 7)
                    Text(wallet.flipperReady ? "Connected" : "Not connected").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .padding(.top, 8)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(18)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 24))
        }
    }

    private func row(icon: String, title: String, value: String? = nil, chevron: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 30, height: 30)
                .background(Theme.zcash)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            if let value { Text(value).font(.subheadline).foregroundStyle(Theme.muted).monospacedDigit() }
            if let chevron { Image(systemName: chevron).font(.caption.weight(.bold)).foregroundStyle(Theme.muted) }
        }
        .contentShape(Rectangle())
    }

    private func chip(_ title: String, icon: String, tag: Int) -> some View {
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
