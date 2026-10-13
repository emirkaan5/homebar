import SwiftUI
import AppKit
import Core

/// The main panel that opens from the menu bar icon.
public struct PanelView: View {
    let store: HomeStore
    /// True when the panel is always on screen (a window) or never (a snapshot).
    let alwaysVisible: Bool
    /// True for snapshots. The offscreen renderer cannot draw scroll views or menus.
    let isSnapshot: Bool
    /// A Hue Bridge to set up, if this build supports one.
    let bridge: (any BridgeSetup)?
    @State private var isVisible = false
    @State private var showsHueSetup = false
    @State private var hueBridgeName: String?
    @State private var contentHeight: CGFloat = 0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @AppStorage(MotionPreference.key) private var fullAnimations = false

    public init(store: HomeStore, bridge: (any BridgeSetup)? = nil, alwaysVisible: Bool = false, isSnapshot: Bool = false) {
        self.store = store
        self.bridge = bridge
        self.alwaysVisible = alwaysVisible || isSnapshot
        self.isSnapshot = isSnapshot
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                if let message = store.errorMessage {
                    ErrorBanner(message: message) { store.errorMessage = nil }
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
                content
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .animation(Motion.snappy, value: store.errorMessage)
            footer
        }
        .frame(width: 360)
        .background(Palette.paper(scheme))
        .environment(\.reducesMotion, systemReducesMotion && !fullAnimations)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task { hueBridgeName = await bridge?.pairedBridgeName() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if store.homes.count > 1 {
                Menu(store.selectedHome?.name ?? "Select a Home") {
                    ForEach(store.homes) { home in
                        Button(home.name) { Task { await store.select(home: home.id) } }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Text(store.selectedHome?.name ?? "HomeBar")
                    .font(.system(size: 15, weight: .bold))
            }
            Spacer()
            if store.phase == .ready {
                StatusPill(text: statusText, tint: statusColor)
                    .help("Connection to SmartRent")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .starting, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 200)
        case .signedOut:
            SignInView(store: store).card()
        case .needsTwoFactor:
            TwoFactorView(store: store).card()
        case .ready where showsHueSetup:
            if let bridge {
                HueSetupView(bridge: bridge) { paired in
                    showsHueSetup = false
                    Task {
                        hueBridgeName = await bridge.pairedBridgeName()
                        if paired { await store.reload() }
                    }
                }
                .card()
            }
        case .ready where isSnapshot:
            deviceList
        case .ready:
            // A menu bar panel sizes itself to its content, and a bare ScrollView has no
            // height of its own. So measure the list and scroll only past the screen height.
            ScrollView {
                deviceList
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            .frame(height: min(max(contentHeight, 1), maximumListHeight))
        }
    }

    /// Leaves room for the menu bar, the header, and the footer.
    private var maximumListHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 140
    }

    private var deviceList: some View {
        VStack(spacing: 10) {
            ForEach(store.thermostats) { device in
                ClimateCard(device: device, store: store, isPanelVisible: isVisible || alwaysVisible)
            }
            ForEach(store.locks) { device in
                LockCard(device: device, store: store)
            }
            TileRows(items: store.lights, columns: 2) { device in
                LightTile(device: device, store: store)
            }
            TileRows(items: store.otherDevices, columns: 3) { device in
                DeviceChip(device: device, store: store)
            }
            if store.devices.isEmpty {
                ContentUnavailableView(
                    "No Devices",
                    systemImage: "house",
                    description: Text("This home has no devices, or they could not be loaded.")
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if store.phase == .ready {
                Button { Task { await store.reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .accessibilityLabel("Refresh")
                if isSnapshot {
                    Image(systemName: "ellipsis.circle")
                } else {
                Menu {
                    Toggle("Full Animations", isOn: $fullAnimations)
                    if systemReducesMotion {
                        Text("Plays airflow and lock motion even though Reduce Motion is on.")
                    }
                    if let bridge {
                        Divider()
                        if let hueBridgeName {
                            Button("Remove \(hueBridgeName)") {
                                Task {
                                    await bridge.unpair()
                                    self.hueBridgeName = nil
                                    await store.reload()
                                }
                            }
                        } else {
                            Button("Add Philips Hue…") { showsHueSetup = true }
                        }
                    }
                    Divider()
                    Button("Sign Out") { Task { await store.signOut() } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
                }
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
    }

    private var statusColor: Color {
        switch store.connection {
        case .live: .green
        case .connecting, .reconnecting: .orange
        case .offline: .red
        }
    }

    private var statusText: String {
        switch store.connection {
        case .live: "Live"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .offline: "Offline"
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(PressableStyle())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Tiles in rows that always fill the width. A row holds up to `columns` tiles;
/// a row with fewer tiles makes them wider. The tiles in a row share one height.
struct TileRows<Content: View>: View {
    let items: [Device]
    let columns: Int
    @ViewBuilder let content: (Device) -> Content

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                    HStack(spacing: 8) {
                        ForEach(items[start..<min(start + columns, items.count)]) { device in
                            content(device)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A compact tile for a device that has no card of its own.
/// A light switch is a button: click it to turn the light on or off.
struct DeviceChip: View {
    let device: Device
    let store: HomeStore

    @Environment(\.colorScheme) private var scheme
    @State private var width: CGFloat = 0

    private var isSwitch: Bool { device.kind == .switchBinary }
    private var isOn: Bool { isSwitch && device.attributes[SwitchAttribute.on] == "true" }

    var body: some View {
        if isSwitch {
            Button {
                store.send(.setOn(!isOn, device: device.id))
            } label: {
                tile
            }
            .buttonStyle(PressableStyle(scale: 0.95))
            .disabled(!device.isOnline)
            .accessibilityLabel(device.displayName)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityHint("Turns the light \(isOn ? "off" : "on")")
            .accessibilityAddTraits(.isToggle)
        } else {
            tile.accessibilityElement(children: .combine)
        }
    }

    private var tile: some View {
        Group {
            if width > LightTile.wideWidth {
                // A wide tile uses one row, like a wide light tile.
                HStack(spacing: 10) {
                    icon
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Palette.surface))
                    VStack(alignment: .leading, spacing: 1) {
                        name.font(.system(size: 12.5, weight: .semibold))
                        summary.font(.system(size: 11))
                    }
                    Spacer(minLength: 0)
                    pendingIndicator
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        icon
                        Spacer(minLength: 0)
                        pendingIndicator
                    }
                    .frame(height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        summary.font(.system(size: 12, weight: .semibold))
                        name.font(.system(size: 11))
                    }
                }
                .padding(10)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(isOn ? Color.primary : Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(device.isOnline ? 1 : 0.5)
        .animation(Motion.snappy, value: isOn)
    }

    private var icon: some View {
        Image(systemName: device.symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(iconColor)
            .contentTransition(.symbolEffect(.replace))
    }

    private var name: some View {
        Text(device.displayName)
            .foregroundStyle(isOn ? Palette.paper(scheme).opacity(0.65) : Color.secondary)
    }

    private var summary: some View {
        Text(device.summary)
            .foregroundStyle(device.needsAttention ? Palette.failure : isOn ? Palette.paper(scheme) : Color.primary)
    }

    @ViewBuilder
    private var pendingIndicator: some View {
        if store.isPending(device.id) {
            ProgressView().controlSize(.mini)
        }
    }

    private var iconColor: Color {
        if device.needsAttention { return Palette.failure }
        if isOn { return Palette.light }
        return device.isActive ? Color.primary : Color.secondary
    }
}

extension Device {
    var symbol: String {
        switch kind {
        case .thermostat: "thermometer.medium"
        case .lock: attributes[LockAttribute.locked] == "false" ? "lock.open.fill" : "lock.fill"
        case .switchBinary, .light: attributes["on"] == "true" ? "lightbulb.fill" : "lightbulb"
        case .dimmer: "lightbulb"
        case .leakSensor: "drop"
        case .motionSensor: "figure.walk.motion"
        case .unknown: "questionmark.square.dashed"
        }
    }

    var summary: String {
        guard isOnline else { return "Offline" }
        switch kind {
        case .lock: return attributes[LockAttribute.locked] == "true" ? "Locked" : attributes[LockAttribute.locked] == "false" ? "Unlocked" : "Unknown"
        case .switchBinary, .light: return attributes["on"] == "true" ? "On" : "Off"
        case .dimmer: return attributes["level"].map { "\($0)%" } ?? "Unknown"
        case .leakSensor: return attributes["leak"] == "true" ? "Leak!" : "Dry"
        case .motionSensor: return attributes["motion_binary"] == "true" ? "Motion" : "No motion"
        case .thermostat: return Thermostat(attributes: attributes).statusText
        case .unknown: return rawType
        }
    }

    /// A light that is on, or motion that is seen.
    var isActive: Bool {
        attributes["on"] == "true" || attributes["motion_binary"] == "true"
    }

    var needsAttention: Bool {
        !isOnline || (kind == .leakSensor && attributes["leak"] == "true")
    }
}
