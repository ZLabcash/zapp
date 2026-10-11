import CoreImage.CIFilterBuiltins
import SwiftUI

enum Theme {
    static let zcash = Color(red: 0.957, green: 0.718, blue: 0.157)
    /// Black in dark mode, white in light mode.
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
    static let card = Color(uiColor: UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0.11, alpha: 1) : UIColor(white: 0.955, alpha: 1)
    })
    static let muted = Color.secondary
    /// The Z of the mark: white on dark, the logo's ink on light.
    static let ink = Color(uiColor: UIColor {
        $0.userInterfaceStyle == .dark ? .white : UIColor(red: 0.13, green: 0.15, blue: 0.16, alpha: 1)
    })
    /// The scan line green of the ZScan mark.
    static let scan = Color(red: 0.106, green: 0.686, blue: 0.478)
}

/// The ZScan mark (shared with zscan.cash and ZStreet): a yellow shield, a white Z
/// and the green dashed scan line. Paths from `scan/public/brand/zscan-logo.svg`
/// (32×32 viewBox). `progress` draws it in, as the Flipper's forging animation does.
struct Shield: View {
    var progress: CGFloat = 1
    var lineWidth: CGFloat? = nil

    var body: some View {
        logoBody.environment(\.layoutDirection, .leftToRight) // a logo never mirrors
    }

    private var logoBody: some View {
        GeometryReader { geo in
            let unit = min(geo.size.width, geo.size.height) / 32
            let stroke = lineWidth ?? 2 * unit
            ZStack {
                MarkShape(path: Self.shield)
                    .trim(from: 0, to: min(1, progress / 0.6))
                    .stroke(Theme.zcash, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                MarkShape(path: Self.z)
                    .trim(from: 0, to: max(0, (progress - 0.6) / 0.3))
                    .stroke(Theme.ink, style: StrokeStyle(lineWidth: stroke * 1.1, lineCap: .round, lineJoin: .round))
                MarkShape(path: Self.scan)
                    .trim(from: 0, to: max(0, (progress - 0.85) / 0.15))
                    .stroke(Theme.scan, style: StrokeStyle(lineWidth: stroke * 0.6, dash: [2 * unit, 2 * unit]))
                    .opacity(0.85)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    static let shield: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 16, y: 2.5))
        p.addLine(to: CGPoint(x: 27.5, y: 7))
        p.addLine(to: CGPoint(x: 27.5, y: 15.6))
        p.addCurve(to: CGPoint(x: 16, y: 29.5), control1: CGPoint(x: 27.5, y: 22.6), control2: CGPoint(x: 22.7, y: 27.5))
        p.addCurve(to: CGPoint(x: 4.5, y: 15.6), control1: CGPoint(x: 9.3, y: 27.5), control2: CGPoint(x: 4.5, y: 22.6))
        p.addLine(to: CGPoint(x: 4.5, y: 7))
        p.closeSubpath()
        return p
    }()

    static let z: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 11, y: 11))
        p.addLine(to: CGPoint(x: 21, y: 11))
        p.addLine(to: CGPoint(x: 11, y: 21))
        p.addLine(to: CGPoint(x: 21, y: 21))
        return p
    }()

    static let scan: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 7.5, y: 16))
        p.addLine(to: CGPoint(x: 24.5, y: 16))
        return p
    }()
}

/// A path in the mark's 32×32 coordinates, scaled to the view.
private struct MarkShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 32
        let dx = rect.minX + (rect.width - 32 * unit) / 2
        let dy = rect.minY + (rect.height - 32 * unit) / 2
        return path.applying(CGAffineTransform(scaleX: unit, y: unit).concatenating(CGAffineTransform(translationX: dx, y: dy)))
    }
}

/// The shield forging itself, looping.
struct ForgingShield: View {
    @State private var progress: CGFloat = 0

    var body: some View {
        logoBody.environment(\.layoutDirection, .leftToRight) // a logo never mirrors
    }

    private var logoBody: some View {
        Shield(progress: progress)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { progress = 1 }
            }
    }
}

struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct PrimaryButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.zcash)
            .foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

extension View {
    func primaryButton() -> some View { modifier(PrimaryButton()) }

    func card() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

/// A plain back arrow at the far left instead of the system "< Back" or Close.
private struct BackArrow: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let before: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        before()
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 36, height: 36)
                            .background(Theme.card)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Back")
                }
            }
    }
}

extension View {
    func backArrow(before: @escaping () -> Void = {}) -> some View {
        modifier(BackArrow(before: before))
    }
}
