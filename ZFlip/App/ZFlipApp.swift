import SwiftUI

@main
struct ZFlipApp: App {
    @StateObject private var link: FlipperLink
    @StateObject private var wallet: WalletModel
    /// 0 = follow the system, 1 = light, 2 = dark.
    @AppStorage("appearance") private var appearance = 0

    init() {
        let link = FlipperLink()
        _link = StateObject(wrappedValue: link)
        _wallet = StateObject(wrappedValue: WalletModel(link: link))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if wallet.pairing == nil {
                    PairView()
                } else {
                    HomeView().task { await wallet.resume() }
                }
            }
            .environmentObject(link)
            .environmentObject(wallet)
            .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
            .tint(Theme.zcash)
            .background(Theme.background.ignoresSafeArea())
        }
    }
}
