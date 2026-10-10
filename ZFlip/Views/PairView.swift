import SwiftUI

/// First run: explain, then "Connect to Flipper" → find it, pair over Bluetooth,
/// get its viewing key.
struct PairView: View {
    @EnvironmentObject var wallet: WalletModel
    @EnvironmentObject var link: FlipperLink

    enum Step: Equatable {
        case intro
        case scan
        case connecting(String)
        case approve
        case birthday(FlipperProtocol.Info)
        case creating
    }

    @State private var step = Step.intro
    @State private var error: String?
    @State private var flipperID: UUID?
    @State private var restoredFrom = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            Group {
                if step == .intro { Shield() } else { ForgingShield() }
            }
            .frame(height: 110)
            Text("ZApp").font(.system(size: 42, weight: .heavy, design: .rounded))
            Text(headline)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal)
            content
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(24)
        .background(Theme.background.ignoresSafeArea())
        .onDisappear { link.stopScan() }
        .onChange(of: link.found) { _, found in
            // One ZFlip in range: connect to it straight away.
            if step == .scan, found.count == 1, let only = found.first {
                Task { await pair(only) }
            }
        }
        .onChange(of: link.awaitingFlipper) { _, waiting in
            if waiting, case .connecting = step { step = .approve }
        }
    }

    private var headline: String {
        switch step {
        case .intro: return "Your Flipper keeps the keys"
        case .scan: return "Looking for your Flipper…"
        case .connecting: return "Connecting…"
        case .approve: return "Press OK on your Flipper"
        case .birthday: return "When was this wallet made?"
        case .creating: return "Setting up your wallet…"
        }
    }

    private var detail: String {
        switch step {
        case .intro:
            return "This iPhone shows your balance and prepares payments. Your Flipper checks and signs them. Open ZFlip on the Flipper and unlock it."
        case .scan:
            return "Keep ZFlip open and unlocked on the Flipper, close to this iPhone."
        case .connecting:
            return "If iOS asks for a code, type the 6 digits shown on the Flipper."
        case .approve:
            return "It asks to share this wallet's viewing key: this iPhone will see your balance, never spend."
        case .birthday:
            return "This wallet was restored from its words. Since when should we look for its funds?"
        case .creating:
            return "Getting ready to sync with the Zcash network."
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .intro:
            Button {
                error = nil
                step = .scan
                link.scan()
            } label: {
                Label("Connect to Flipper", systemImage: "dot.radiowaves.left.and.right").primaryButton()
            }
        case .scan:
            VStack(spacing: 10) {
                if link.state == .off {
                    Text("Turn on Bluetooth and allow ZFlip to use it.").foregroundStyle(.orange)
                } else if link.found.isEmpty {
                    ProgressView().tint(Theme.zcash)
                }
                if link.found.count > 1 {
                    ForEach(link.found) { flipper in
                        Button { Task { await pair(flipper) } } label: {
                            HStack {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                Text(flipper.name).bold()
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .card()
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Cancel") {
                    link.stopScan()
                    step = .intro
                }
                .foregroundStyle(Theme.muted)
            }
        case .connecting, .approve, .creating:
            ProgressView().tint(Theme.zcash)
        case .birthday(let info):
            VStack(spacing: 16) {
                DatePicker("Restored wallet since", selection: $restoredFrom, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .card()
                Button("Continue") { Task { await create(info, restoredFrom: restoredFrom) } }
                    .primaryButton()
            }
        }
    }

    private func pair(_ flipper: FlipperLink.Found) async {
        error = nil
        flipperID = flipper.id
        step = .connecting(flipper.name)
        do {
            try await link.connect(flipper.id, timeout: 25)
            let info = try await wallet.requestInfo()
            if info.createdAt == 0 {
                step = .birthday(info)
            } else {
                await create(info, restoredFrom: nil)
            }
        } catch {
            self.error = error.localizedDescription
            link.disconnect()
            step = .intro
        }
    }

    private func create(_ info: FlipperProtocol.Info, restoredFrom: Date?) async {
        guard let flipperID else { return }
        step = .creating
        do {
            try await wallet.createWallet(info: info, flipperID: flipperID, restoredFrom: restoredFrom)
        } catch {
            self.error = error.localizedDescription
            step = .intro
        }
    }
}
