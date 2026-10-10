import SwiftUI
import VisionKit

/// The camera, reading the first QR code it sees.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    static var available: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in items {
                if let text = code.payloadStringValue {
                    done = true
                    scanner.stopScanning()
                    found(text)
                    return
                }
            }
        }
    }
}

/// A scanned payment: a bare address or a ZIP 321 URI (zcash:addr?amount=&memo=).
struct PaymentRequest {
    var address: String
    var amount: String?
    var memo: String?

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("zcash:") else {
            address = trimmed
            return
        }
        // Split by hand: base58 t-addresses are case-sensitive, URL hosts are not.
        let body = trimmed.dropFirst(6)
        let parts = body.split(separator: "?", maxSplits: 1)
        address = String(parts.first ?? "")
        guard parts.count == 2, let components = URLComponents(string: "x://x?" + parts[1]) else { return }
        for item in components.queryItems ?? [] {
            switch item.name {
            case "amount": amount = item.value
            case "memo":
                // ZIP 321 memos are base64url.
                if let v = item.value {
                    var b64 = v.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    while b64.count % 4 != 0 { b64 += "=" }
                    memo = Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) }
                }
            default: break
            }
        }
    }
}
