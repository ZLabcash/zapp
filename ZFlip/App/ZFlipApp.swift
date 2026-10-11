import SwiftUI

@main
struct ZFlipApp: App {
    @StateObject private var link: FlipperLink
    @StateObject private var wallet: WalletModel
    @StateObject private var contacts = ContactBook()
    @StateObject private var prices = PriceService()
    /// 0 = follow the system, 1 = light, 2 = dark.
    @AppStorage("appearance") private var appearance = 0
    @AppStorage(AppLanguage.key) private var language = ""
    /// The opening animation over Home (the welcome screen plays its own).
    @State private var splash = true
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // English until the user picks a language (welcome screen or Settings).
        AppLanguage.apply(AppLanguage.current.isEmpty ? "en" : AppLanguage.current)
        let link = FlipperLink()
        _link = StateObject(wrappedValue: link)
        let wallet = WalletModel(link: link)
        _wallet = StateObject(wrappedValue: wallet)
        BackgroundSync.register(wallet)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Group {
                    if wallet.pairing == nil {
                        NavigationStack { WelcomeView() }
                    } else {
                        HomeView().task { await wallet.resume() }
                    }
                }
                .environmentObject(link)
                .environmentObject(wallet)
                .environmentObject(contacts)
                .environmentObject(prices)
                .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
                // A language change rebuilds every screen in the new language (and direction).
                .environment(\.locale, AppLanguage.locale(language))
                .environment(\.layoutDirection, AppLanguage.isRightToLeft(language) ? .rightToLeft : .leftToRight)
                .id(language)
                .tint(Theme.zcash)
                .background(Theme.background.ignoresSafeArea())
                if splash && wallet.pairing != nil {
                    Splash { withAnimation(.easeOut(duration: 0.35)) { splash = false } }
                        .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            // No wallet: the welcome screen animates itself, and adding a wallet later
            // goes straight to Home.
            .onAppear { if wallet.pairing == nil { splash = false } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { BackgroundSync.didEnterBackground(wallet) }
                if phase == .active { BackgroundSync.end() }
            }
        }
    }
}
