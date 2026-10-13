import SwiftUI
import WebKit

/// NFTs: the collections first, each opening on its own page.
struct NFTCollectionsView: View {
    @StateObject private var zilkroad = Zilkroad()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                NavigationLink { NFTsView(zilkroad: zilkroad) } label: {
                    HStack(spacing: 14) {
                        SnarkImage(number: zilkroad.held.first ?? 1)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: "zkSNARKs").font(.headline)
                            Text(zilkroad.held.isEmpty ? String(localized: "10,000 portraits on Zcash")
                                                       : String(localized: "\(zilkroad.held.count) yours, of 10,000"))
                                .font(.subheadline).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                    }
                    .card()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("NFTs")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
    }
}

/// The zkSNARKs collection. "Mine" lists the ones held in the user's zilkroad account
/// (after signing in there); "All 10,000" browses the whole collection.
struct NFTsView: View {
    @EnvironmentObject var wallet: WalletModel
    @ObservedObject var zilkroad: Zilkroad
    @State private var tab = 0
    @State private var query = ""
    @State private var signingIn = false
    @State private var selected: SnarkNumber?
    @State private var sending = false
    @State private var kindleNote: String?
    @State private var confirmSignOut = false

    /// zilkroad sign-in is held back for now: the button shows, greyed.
    static let signInOpen = false

    struct SnarkNumber: Identifiable {
        let id: Int
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $tab) {
                    Text("Mine").tag(0)
                    Text("All 10,000").tag(1)
                }
                .pickerStyle(.segmented)
                if tab == 0 { mine } else { all }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("zkSNARKs")
        .navigationBarTitleDisplayMode(.inline)
        .backArrow()
        .sheet(isPresented: $signingIn) { ZilkroadSignIn(zilkroad: zilkroad) }
        .sheet(item: $selected) { SnarkDetailSheet(number: $0.id, held: zilkroad.held.contains($0.id)) }
        .confirmationDialog("Sign out of zilkroad?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await zilkroad.signOut() } }
        } message: {
            Text("Your zkSNARKs stay in your zilkroad account. This phone forgets the list and the session.")
        }
    }

    // MARK: Mine

    @ViewBuilder private var mine: some View {
        if !zilkroad.signedIn && zilkroad.held.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your zkSNARKs").font(.headline)
                Text("The zkSNARKs you hold live in your zilkroad account. Sign in there, in its own page, to list them here.")
                    .font(.subheadline).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button { signingIn = true } label: {
                    Label("Sign in to zilkroad", systemImage: "person.crop.circle").primaryButton()
                }
                .disabled(!Self.signInOpen)
                .opacity(Self.signInOpen ? 1 : 0.4)
            }
            .card()
        } else {
            HStack {
                Text("\(zilkroad.held.count) held").font(.subheadline.weight(.semibold)).monospacedDigit()
                Spacer()
                if zilkroad.signedIn {
                    Button { Task { await zilkroad.refresh() } } label: {
                        if zilkroad.refreshing { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                    .disabled(zilkroad.refreshing)
                } else {
                    Button { signingIn = true } label: { Label("Sign in", systemImage: "person.crop.circle") }
                        .disabled(!Self.signInOpen)
                }
                Button("Sign out") { confirmSignOut = true }
                    .padding(.leading, 8)
            }
            .font(.subheadline.weight(.semibold))
            if let error = zilkroad.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
            }
            if zilkroad.held.isEmpty {
                Text("No zkSNARKs in this zilkroad account.").font(.subheadline).foregroundStyle(Theme.muted).card()
            } else {
                grid(zilkroad.held, columns: 3)
            }
            if wallet.pairing?.isKindle == true && !zilkroad.held.isEmpty {
                Button { Task { await showOnKindle() } } label: {
                    HStack(spacing: 8) {
                        if sending { ProgressView().tint(.black) }
                        Label("Show on Kindle", systemImage: "rectangle.portrait.on.rectangle.portrait")
                    }
                    .primaryButton()
                }
                .disabled(sending)
                if let kindleNote {
                    Text(kindleNote).font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func showOnKindle() async {
        sending = true
        defer { sending = false }
        do {
            try await wallet.showOnKindle(zilkroad.held)
            kindleNote = String(localized: "Your Kindle lists them now, even offline.")
        } catch {
            kindleNote = error.localizedDescription
        }
    }

    // MARK: All

    @ViewBuilder private var all: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("Search by number", text: $query)
                .keyboardType(.numberPad)
                .onChange(of: query) { _, text in
                    let digits = String(text.filter(\.isNumber).prefix(5))
                    if digits != text { query = digits }
                }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }
                    .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        let numbers = results
        if numbers.isEmpty {
            Text("No zkSNARK has this number (1 to 10,000).").font(.subheadline).foregroundStyle(Theme.muted)
        } else {
            grid(numbers, columns: 4)
        }
    }

    /// Every number starting with what's typed (all of them when nothing is).
    private var results: [Int] {
        guard !query.isEmpty else { return Array(1...Zilkroad.count) }
        return (1...Zilkroad.count).filter { String($0).hasPrefix(query) }
    }

    private func grid(_ numbers: [Int], columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            ForEach(numbers, id: \.self) { n in
                Button { selected = SnarkNumber(id: n) } label: { SnarkTile(number: n) }
                    .buttonStyle(.plain)
            }
        }
    }
}

/// One portrait and its number.
struct SnarkTile: View {
    let number: Int

    var body: some View {
        VStack(spacing: 4) {
            SnarkImage(number: number)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(verbatim: "#\(number)").font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.muted)
        }
    }
}

/// A 26×26 portrait scaled up pixel for pixel (no smoothing).
struct SnarkImage: View {
    let number: Int
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.card
            if let shown = image ?? SnarkImages.shared.cached(number) {
                Image(uiImage: shown)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: number) { image = await SnarkImages.shared.image(number) }
    }
}

/// A zkSNARK on its own: the portrait large, its traits, and its page on zilkroad.
struct SnarkDetailSheet: View {
    let number: Int
    let held: Bool
    @State private var details: SnarkDetails?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Capsule().fill(Theme.muted).frame(width: 40, height: 5).frame(maxWidth: .infinity).padding(.top, 8)
                SnarkImage(number: number)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .frame(maxWidth: 320)
                    .frame(maxWidth: .infinity)
                HStack {
                    Text(verbatim: details?.name ?? "zkSNARKs #\(number)").font(.title2.bold())
                    Spacer()
                    if held {
                        Label("Yours", systemImage: "checkmark.seal.fill").font(.caption.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .foregroundStyle(Theme.scan).background(Theme.scan.opacity(0.14)).clipShape(Capsule())
                    }
                }
                if let details {
                    VStack(spacing: 0) {
                        ForEach(Array(details.traits.enumerated()), id: \.offset) { i, trait in
                            if i > 0 { Divider() }
                            HStack {
                                Text(verbatim: trait.type).foregroundStyle(Theme.muted)
                                Spacer()
                                Text(verbatim: trait.value).fontWeight(.semibold)
                            }
                            .font(.subheadline)
                            .padding(.vertical, 10)
                        }
                    }
                    .card()
                } else if failed {
                    Text("Traits unavailable right now.").font(.footnote).foregroundStyle(Theme.muted)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                Link(destination: Zilkroad.itemURL(number)) {
                    Label("View on zilkroad", systemImage: "arrow.up.right.square").primaryButton()
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .presentationDragIndicator(.hidden)
        .task {
            do { details = try await SnarkDetails.load(number) } catch { failed = true }
        }
    }
}

/// zilkroad.com in a web view, for the user's own sign-in (account code and captcha, on
/// their page, never filled in here). Once signed in, the account's zkSNARKs are read with
/// that page's session and the sheet closes.
struct ZilkroadSignIn: View {
    @ObservedObject var zilkroad: Zilkroad
    @Environment(\.dismiss) private var dismiss
    @StateObject private var page = WebPage()

    var body: some View {
        NavigationStack {
            WebView(view: page.view)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("zilkroad")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Task {
                                await read()
                                dismiss()
                            }
                        }
                    }
                }
        }
        .task {
            page.view.load(URLRequest(url: Zilkroad.site))
            // Signed in yet? Asked every few seconds, from the page itself.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if await read() {
                    dismiss()
                    return
                }
            }
        }
    }

    /// `/api/me` fetched by the page (its own cookies). True once an account is signed in.
    @discardableResult
    private func read() async -> Bool {
        guard page.view.url?.host?.hasSuffix("zilkroad.com") == true,
              let text = try? await page.view.callAsyncJavaScript(
                  "const r = await fetch('/api/me', {credentials: 'include', cache: 'no-store'}); return await r.text();",
                  contentWorld: .defaultClient) as? String else { return false }
        return zilkroad.apply(Data(text.utf8))
    }
}

/// The web view, kept across SwiftUI updates.
@MainActor
final class WebPage: ObservableObject {
    let view: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        return WKWebView(frame: .zero, configuration: config)
    }()
}

private struct WebView: UIViewRepresentable {
    let view: WKWebView

    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
