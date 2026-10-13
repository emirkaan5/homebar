import SwiftUI
import Core

/// Adds a Philips Hue Bridge: find it on the network (or type its address),
/// press the button on the bridge, and the lights appear in the panel.
struct HueSetupView: View {
    let bridge: any BridgeSetup
    let onFinish: (_ paired: Bool) -> Void

    private enum Step: Equatable {
        case searching
        case choose([BridgeCandidate])
        case pressButton(BridgeCandidate)
        case connected(String)
    }

    @State private var step: Step = .searching
    @State private var address = ""
    @State private var message: String?
    @State private var secondsLeft = 45
    @FocusState private var addressFocused: Bool

    /// How long the bridge waits for HomeBar after its button is pressed.
    private static let pairingWindow = 45

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Philips Hue").font(.system(size: 17, weight: .bold))
                Spacer()
                if case .connected = step {} else {
                    Button("Cancel") { onFinish(false) }
                        .buttonStyle(PressableStyle())
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            switch step {
            case .searching:
                searching
            case .choose(let bridges):
                choose(bridges)
            case .pressButton(let candidate):
                pressButton(candidate)
            case .connected(let name):
                connected(name)
            }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.unlocked)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.snappy, value: step)
        .task { await search() }
    }

    // MARK: Steps

    private var searching: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Looking for a Hue Bridge on your network…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }

    private func choose(_ bridges: [BridgeCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if bridges.isEmpty {
                Text("No bridge answered. Check that it is on and connected to your router, or enter its address. You can find the address in the Hue app under Settings > My Hue System.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(bridges) { candidate in
                    Button { Task { await startPairing(candidate) } } label: {
                        HStack(spacing: 10) {
                            BridgeIcon(isWaiting: false).frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.name).font(.system(size: 13, weight: .semibold))
                                Text(candidate.host).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.98))
                }
            }

            HStack(spacing: 8) {
                TextField("Address", text: $address, prompt: Text("Bridge address, e.g. 192.168.0.20"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($addressFocused)
                    .onSubmit(connectToAddress)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(addressFocused ? Color.primary.opacity(0.7) : Palette.hairline, lineWidth: addressFocused ? 1.2 : 0.5))
                Button("Connect", action: connectToAddress)
                    .buttonStyle(MonoButtonStyle(isFilled: true))
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button("Search Again") { Task { await search() } }
                .buttonStyle(PressableStyle())
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func pressButton(_ candidate: BridgeCandidate) -> some View {
        VStack(alignment: .center, spacing: 12) {
            BridgeIcon(isWaiting: true)
                .frame(width: 76, height: 76)
                .frame(maxWidth: .infinity)
            Text("Press the round button on top of your Hue Bridge")
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("HomeBar is waiting for \(candidate.name) · \(secondsLeft) s")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(maxWidth: .infinity)
    }

    private func connected(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(name) is connected. Its lights are in the panel now.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.multicolor)
                .fixedSize(horizontal: false, vertical: true)
            Button("Done") { onFinish(true) }
                .buttonStyle(MonoButtonStyle(isFilled: true, isWide: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Actions

    private func search() async {
        message = nil
        step = .searching
        let found = await bridge.discover(for: .seconds(4))
        step = .choose(found)
        addressFocused = found.isEmpty
    }

    private func connectToAddress() {
        let host = address.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        Task { await startPairing(BridgeCandidate(id: host, name: "the bridge", host: host)) }
    }

    /// Asks the bridge for a key every 2 s until its button is pressed or time runs out.
    private func startPairing(_ candidate: BridgeCandidate) async {
        message = nil
        step = .pressButton(candidate)
        let deadline = ContinuousClock.now + .seconds(Self.pairingWindow)
        while ContinuousClock.now < deadline, step == .pressButton(candidate) {
            secondsLeft = max(0, Int((deadline - ContinuousClock.now).components.seconds))
            do {
                if try await bridge.pair(with: candidate.host) == .paired {
                    Haptics.bump()
                    step = .connected(await bridge.pairedBridgeName() ?? "The bridge")
                    return
                }
            } catch {
                message = error.localizedDescription
                step = .choose([])
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        if step == .pressButton(candidate) {
            message = "The button was not pressed in time. Try again."
            step = .choose([candidate])
        }
    }
}

/// A Hue Bridge seen from above: a rounded square with the round link button.
/// While HomeBar waits, the button pulses to show where to press.
private struct BridgeIcon: View {
    let isWaiting: Bool

    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
                if isWaiting {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.5), lineWidth: 1.5)
                        .frame(width: side * 0.42, height: side * 0.42)
                        .phaseAnimator([false, true]) { ring, expanded in
                            ring
                                .scaleEffect(reduceMotion ? 1 : (expanded ? 1.7 : 1))
                                .opacity(expanded ? 0 : 0.9)
                        } animation: { expanded in
                            expanded ? .easeOut(duration: 1.1) : .linear(duration: 0.01)
                        }
                }
                Circle()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: side * 0.4, height: side * 0.4)
                    .overlay(Circle().fill(Color.primary.opacity(0.4)).frame(width: side * 0.18, height: side * 0.18).blendMode(.destinationOut))
                    .compositingGroup()
            }
            .frame(width: side, height: side)
        }
        .accessibilityHidden(true)
    }
}
