import SwiftUI
import VisionKit

/// The camera, reading the first QR code it sees.
struct QRScanner: UIViewControllerRepresentable {
    /// Only codes inside this square (in the view's coordinates) are read.
    var region: CGRect?
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

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if let region, region.width > 0 { controller.regionOfInterest = region }
    }

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

/// The camera with a viewfinder: the screen dimmed around a clear square with
/// yellow corners, and a hint. Codes are read inside the square only.
struct ScannerScreen: View {
    let found: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.68
            let square = CGRect(x: (geo.size.width - side) / 2, y: (geo.size.height - side) / 2 - 40,
                                width: side, height: side)
            ZStack {
                QRScanner(region: square, found: found)
                // Dim everything but the square.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRoundedRect(in: square, cornerSize: CGSize(width: 22, height: 22))
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Corners()
                    .stroke(Theme.zcash, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: side, height: side)
                    .position(x: square.midX, y: square.midY)
                    .allowsHitTesting(false)
                VStack(spacing: 6) {
                    Text("Scan a Zcash QR code").font(.headline)
                    Text("Hold it inside the square").font(.subheadline).opacity(0.8)
                }
                .foregroundStyle(.white)
                .position(x: geo.size.width / 2, y: square.maxY + 50)
            }
        }
        .ignoresSafeArea()
    }
}

/// The four corner brackets of a viewfinder.
private struct Corners: Shape {
    func path(in r: CGRect) -> Path {
        let l = r.width * 0.16, k: CGFloat = 22
        var p = Path()
        // Top left, top right, bottom right, bottom left: an arm, the curve, an arm.
        p.move(to: CGPoint(x: r.minX, y: r.minY + l))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + k))
        p.addQuadCurve(to: CGPoint(x: r.minX + k, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + k), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - k))
        p.addQuadCurve(to: CGPoint(x: r.maxX - k, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + k, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - k), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}
