import Foundation
import UIKit
import WebKit

/// zkSNARKs: 10,000 pixel portraits (26×26). Who holds which is not on chain: it lives in
/// zilkroad accounts, read from zilkroad's `/api/me` with the session of the user's own
/// sign-in in a web view. Only the token numbers are kept here (never the cookie), so
/// "Mine" shows offline too.
@MainActor
final class Zilkroad: ObservableObject {
    nonisolated static let site = URL(string: "https://zilkroad.com")!
    nonisolated static let count = 10_000

    /// Token numbers of the collection "main" the signed-in account holds.
    @Published private(set) var held: [Int]
    /// The last read of the account found a session.
    @Published private(set) var signedIn: Bool
    @Published private(set) var refreshing = false
    @Published var error: String?

    private static let heldKey = "zapp.zksnarks.held"
    private static let signedInKey = "zapp.zksnarks.signedIn"

    init() {
        let d = UserDefaults.standard
        held = d.array(forKey: Self.heldKey) as? [Int] ?? []
        signedIn = d.bool(forKey: Self.signedInKey)
    }

    nonisolated static func itemURL(_ n: Int) -> URL { URL(string: "https://zilkroad.com/#/\(n)")! }

    /// Reads the account again with the session in the web views' cookie store.
    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("zilkroad.com") }
        var request = URLRequest(url: Self.site.appendingPathComponent("api/me"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        do {
            let (data, _) = try await URLSession(configuration: config).data(for: request)
            if !apply(data) { error = String(localized: "Sign in to zilkroad again to refresh.") }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Takes an `/api/me` answer. False when it has no signed-in account.
    @discardableResult
    func apply(_ data: Data) -> Bool {
        struct Me: Decodable {
            struct Snark: Decodable {
                let collection: String?
                let tokenNumber: Int?
            }
            let address: String?
            let snarks: [Snark]?
        }
        guard let me = try? JSONDecoder().decode(Me.self, from: data) else { return false }
        guard me.address != nil else {
            signedIn = false
            UserDefaults.standard.set(false, forKey: Self.signedInKey)
            return false
        }
        let numbers = (me.snarks ?? []).filter { $0.collection == "main" }.compactMap(\.tokenNumber)
        held = Array(Set(numbers.filter { (1...Self.count).contains($0) })).sorted()
        signedIn = true
        error = nil
        let d = UserDefaults.standard
        d.set(held, forKey: Self.heldKey)
        d.set(true, forKey: Self.signedInKey)
        return true
    }

    /// Clears zilkroad's website data (its session) and the list kept here.
    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { $0.displayName.contains("zilkroad") }
        await store.removeData(ofTypes: types, for: records)
        held = []
        signedIn = false
        error = nil
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.heldKey)
        d.removeObject(forKey: Self.signedInKey)
    }
}

/// A zkSNARK's name and traits (zilkroad `/api/snarks/{n}`).
struct SnarkDetails: Equatable {
    struct Trait: Equatable, Hashable {
        let type: String
        let value: String
    }

    let name: String
    let traits: [Trait]

    static func load(_ n: Int) async throws -> SnarkDetails {
        struct Reply: Decodable {
            struct Snark: Decodable {
                struct Metadata: Decodable {
                    struct Attribute: Decodable {
                        let trait_type: String
                        let value: String
                    }
                    let attributes: [Attribute]?
                }
                let name: String?
                let metadata: Metadata?
            }
            let snark: Snark
        }
        let url = Zilkroad.site.appendingPathComponent("api/snarks/\(n)")
        let (data, _) = try await URLSession.shared.data(from: url)
        let snark = try JSONDecoder().decode(Reply.self, from: data).snark
        return SnarkDetails(name: snark.name ?? "zkSNARKs #\(n)",
                            traits: (snark.metadata?.attributes ?? []).map { Trait(type: $0.trait_type, value: $0.value) })
    }
}

/// The portraits from ZScan's API, kept on disk (Caches) once fetched, a few at a time,
/// the most recently asked first (what's on screen after a fast scroll).
@MainActor
final class SnarkImages {
    static let shared = SnarkImages()

    private let memory = NSCache<NSNumber, UIImage>()
    private var loading: [Int: Task<UIImage?, Never>] = [:]
    private var free = 8
    private var queue: [CheckedContinuation<Void, Never>] = []
    private let directory: URL? = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("zksnarks", isDirectory: true)
        if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }()

    private init() {
        memory.countLimit = 600
    }

    func cached(_ n: Int) -> UIImage? { memory.object(forKey: n as NSNumber) }

    func image(_ n: Int) async -> UIImage? {
        if let image = cached(n) { return image }
        if let task = loading[n] { return await task.value }
        let task = Task { await self.load(n) }
        loading[n] = task
        let image = await task.value
        loading[n] = nil
        return image
    }

    private func load(_ n: Int) async -> UIImage? {
        let file = directory?.appendingPathComponent("\(n).png")
        if let file, let data = await Task.detached(operation: { try? Data(contentsOf: file) }).value,
           let image = UIImage(data: data) {
            memory.setObject(image, forKey: n as NSNumber)
            return image
        }
        await acquire()
        defer { release() }
        guard let url = URL(string: "https://api.zscan.cash/v1/collections/zksnarks/items/\(n)/image"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: n as NSNumber)
        if let file { Task.detached { try? data.write(to: file, options: .atomic) } }
        return image
    }

    private func acquire() async {
        if free > 0 {
            free -= 1
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if let next = queue.popLast() { next.resume() } else { free += 1 }
    }
}
