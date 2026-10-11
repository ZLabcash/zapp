import Foundation

/// The ZEC price in the user's currency: CoinGecko's public API for every currency,
/// ZScan's own API (USD) when CoinGecko can't be reached. Refreshed every 5 minutes.
@MainActor
final class PriceService: ObservableObject {
    struct Currency: Identifiable, Hashable {
        let code: String
        var id: String { code }
        /// Its flag in Assets.xcassets/Flags (the euro's is the EU's).
        var flag: String { ["usd": "us", "eur": "eu", "gbp": "gb", "chf": "ch", "jpy": "jp", "cny": "cn", "cad": "ca", "aud": "au", "nzd": "nz", "krw": "kr", "inr": "in", "brl": "br", "mxn": "mx", "ars": "ar", "clp": "cl", "rub": "ru", "uah": "ua", "try": "tr", "pln": "pl", "czk": "cz", "huf": "hu", "sek": "se", "nok": "no", "dkk": "dk", "ils": "il", "aed": "ae", "sar": "sa", "kwd": "kw", "bhd": "bh", "zar": "za", "ngn": "ng", "sgd": "sg", "hkd": "hk", "twd": "tw", "thb": "th", "idr": "id", "myr": "my", "php": "ph", "vnd": "vn", "pkr": "pk", "bdt": "bd", "lkr": "lk", "gel": "ge"][code] ?? "un" }
        /// In the user's language, from the system ("US dollar", "dollar des États-Unis"…).
        var name: String { AppLanguage.effectiveLocale.localizedString(forCurrencyCode: code.uppercased()) ?? code.uppercased() }
    }

    static let currencies: [Currency] = [
        Currency(code: "usd"),
        Currency(code: "eur"),
        Currency(code: "gbp"),
        Currency(code: "chf"),
        Currency(code: "jpy"),
        Currency(code: "cny"),
        Currency(code: "cad"),
        Currency(code: "aud"),
        Currency(code: "nzd"),
        Currency(code: "krw"),
        Currency(code: "inr"),
        Currency(code: "brl"),
        Currency(code: "mxn"),
        Currency(code: "ars"),
        Currency(code: "clp"),
        Currency(code: "rub"),
        Currency(code: "uah"),
        Currency(code: "try"),
        Currency(code: "pln"),
        Currency(code: "czk"),
        Currency(code: "huf"),
        Currency(code: "sek"),
        Currency(code: "nok"),
        Currency(code: "dkk"),
        Currency(code: "ils"),
        Currency(code: "aed"),
        Currency(code: "sar"),
        Currency(code: "kwd"),
        Currency(code: "bhd"),
        Currency(code: "zar"),
        Currency(code: "ngn"),
        Currency(code: "sgd"),
        Currency(code: "hkd"),
        Currency(code: "twd"),
        Currency(code: "thb"),
        Currency(code: "idr"),
        Currency(code: "myr"),
        Currency(code: "php"),
        Currency(code: "vnd"),
        Currency(code: "pkr"),
        Currency(code: "bdt"),
        Currency(code: "lkr"),
        Currency(code: "gel"),
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
        f.locale = AppLanguage.effectiveLocale
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
