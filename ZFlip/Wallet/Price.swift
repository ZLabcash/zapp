import Foundation

/// The ZEC price in the user's currency: CoinGecko's public API for every currency,
/// ZScan's own API (USD) when CoinGecko can't be reached. Refreshed every 5 minutes.
@MainActor
final class PriceService: ObservableObject {
    struct Currency: Identifiable, Hashable {
        let code: String
        var id: String { code }
        /// Its flag in Assets.xcassets/Flags (the euro's is the EU's).
        var flag: String { ["usd": "us", "eur": "eu", "gbp": "gb", "chf": "ch", "cad": "ca", "aud": "au", "jpy": "jp"][code] ?? "us" }
        /// In the user's language, from the system ("US dollar", "dollar des États-Unis"…).
        var name: String { Locale.current.localizedString(forCurrencyCode: code.uppercased()) ?? code.uppercased() }
    }

    static let currencies = [
        Currency(code: "usd"),
        Currency(code: "eur"),
        Currency(code: "gbp"),
        Currency(code: "chf"),
        Currency(code: "cad"),
        Currency(code: "aud"),
        Currency(code: "jpy"),
    ]

    /// Price of 1 ZEC, by lowercase currency code.
    @Published private(set) var prices: [String: Double] = [:]
    @Published private(set) var updated: Date?
    private var refreshing = false

    func price(_ code: String) -> Double? { prices[code] }

    /// "≈ €12.34" for `zatoshi` in `code`, nil without a price.
    func format(zatoshi: Int64, in code: String) -> String? {
        guard let price = prices[code] else { return nil }
        let value = Double(zatoshi) / 1e8 * price
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code.uppercased()
        f.maximumFractionDigits = value != 0 && abs(value) < 0.01 ? 4 : 2
        return f.string(from: NSNumber(value: value))
    }

    func refreshIfStale() async {
        if let updated, Date().timeIntervalSince(updated) < 300 { return }
        await refresh()
    }

    func refresh() async {
        if Demo.scene != nil {
            prices = ["usd": 1224.0]
            updated = Date()
            return
        }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let codes = Self.currencies.map(\.code).joined(separator: ",")
        if let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=zcash&vs_currencies=\(codes)"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]],
           let zec = json["zcash"], !zec.isEmpty {
            prices = zec
            updated = Date()
            return
        }
        if let url = URL(string: "https://api.zscan.cash/v1/price"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let usd = json["usd"] as? Double {
            prices["usd"] = usd
            updated = Date()
        }
    }
}
