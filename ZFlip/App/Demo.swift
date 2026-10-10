import Foundation

/// Debug builds only: `-demo <scene>` on the command line puts ZApp in a fixed state
/// (paired, a balance, a payment on its way…) so its real screens can be filmed.
/// Release builds always read `nil`.
enum Demo {
    #if DEBUG
    static let scene: String? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-demo"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()
    #else
    static let scene: String? = nil
    #endif

    static func on(_ prefix: String) -> Bool { scene?.hasPrefix(prefix) ?? false }

    /// Seed [11; 64]: the wallet the film's Flipper screens show.
    static let ufvk = "uview14ct0hd83ckzp564fuu9hh6a093c23ygcg3ansq249pps94kf0zmy0ha0me49tteknm5wm9d8rl7vuu00u73zu2lvqwnhajmkhs38rqnhfu9ajwmdln40gd6k6rh827dpxjg70t3aprmsscn2eaj7fsydrj607z6pq4fsfgtz9j898lt7ta5njtcfmrgqh"
    static let seedFingerprint: [UInt8] = [237, 17, 146, 252, 65, 221, 239, 130, 78, 116, 187, 199, 127, 116, 126, 222, 114, 231, 120, 224, 126, 3, 109, 90, 130, 43, 72, 70, 218, 214, 18, 131]
    static let friend = "u1755x90wfsndsgvqlm5ljvacu08uvr304vdgtn45jt0yugf6ale65ya75dqdly33zuznp00xwpcn4ehq3qx2ywwwufxh9l75gqs49v8aq"
    static let txid = "9f3c2a71e0b4d58c6a1f02e7b93d4c8e5a71f6029bd3e84c0a5f17d2c96b3e40"
}
