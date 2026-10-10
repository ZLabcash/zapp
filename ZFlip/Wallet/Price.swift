import Foundation

/// The ZEC price in the user's currency: CoinGecko's public API for every currency,
/// ZScan's own API (USD) when CoinGecko can't be reached. Refreshed every 5 minutes.
@MainActor
final class PriceService: ObservableObject {
    struct Currency: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let currencies = [
        Currency(code: "usd", name: "US dollar"),
        Currency(code: "eur", name: "Euro"),
        Currency(code: "gbp", name: "British pound"),
        Currency(code: "chf", name: "Swiss franc"),
        Currency(code: "cad", name: "Canadian dollar"),
        Currency(code: "aud", name: "Australian dollar"),
        Currency(code: "jpy", name: "Japanese yen"),
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
