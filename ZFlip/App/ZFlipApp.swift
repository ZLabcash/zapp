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

    init() {
        AppLanguage.apply(AppLanguage.current)
        let link = FlipperLink()
        _link = StateObject(wrappedValue: link)
        _wallet = StateObject(wrappedValue: WalletModel(link: link))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if wallet.pairing == nil {
                    NavigationStack { AddWalletView(welcome: true, onDone: {}) }
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
        }
    }
}
