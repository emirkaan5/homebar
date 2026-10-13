import SwiftUI
import AppKit
import Network
import Core
import UI
import SmartRentProvider
import HueProvider
import Platform

@main
struct HomeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: appDelegate.store, bridge: appDelegate.bridge)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `--demo` runs fake devices in a window and plays the animations on a loop.
    static let isDemo = CommandLine.arguments.contains("--demo")
    /// `--mock` (or HOMEBAR_MOCK=1) runs the app with fake devices and no account.
    static let usesMock = isDemo || CommandLine.arguments.contains("--mock") || ProcessInfo.processInfo.environment["HOMEBAR_MOCK"] == "1"

    /// Philips Hue lights next to the SmartRent devices. Fake ones with `--mock`;
    /// `--hue-unpaired` starts them unpaired, to try the setup.
    let bridge: any BridgeSetup & AccessoryProvider = AppDelegate.usesMock
        ? MockLights(paired: !CommandLine.arguments.contains("--hue-unpaired"))
        : HueProvider(secrets: KeychainStore())

    private(set) lazy var store: HomeStore = {
        if AppDelegate.usesMock {
            // Fake devices only: the demo may skip Touch ID because no real door is involved.
            // `--signed-out` starts the fake account signed out, to try the sign-in form.
            let main = MockProvider(signedIn: !CommandLine.arguments.contains("--signed-out"), latency: .milliseconds(700))
            return HomeStore(provider: CompositeProvider(primary: main, accessories: [bridge]),
                             gate: AppDelegate.isDemo ? AllowGate() : BiometricGate())
        }
        let main = SmartRentProvider(secrets: KeychainStore())
        return HomeStore(provider: CompositeProvider(primary: main, accessories: [bridge]), gate: BiometricGate())
    }()

    private let pathMonitor = NWPathMonitor()
    private var wasOffline = false
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            Snapshot.render(to: CommandLine.arguments[index + 1])
            return
        }

        NSApp.setActivationPolicy(.accessory)
        Task { await store.start() }
        // `--window` also shows the panel in a normal window, for when the menu bar is hidden.
        if CommandLine.arguments.contains("--window") || Self.isDemo { showWindow() }
        if Self.isDemo { Task { await playDemo() } }

        // Connect again at once after sleep or a network change.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [store] _ in
            Task { @MainActor in await store.reconnect() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        pathMonitor.start(queue: .main)
    }

    private func showWindow() {
        let controller = NSHostingController(rootView: PanelView(store: store, bridge: bridge, alwaysVisible: true))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = "HomeBar"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 360, height: 760))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    /// Locks and unlocks the fake door and changes the fake temperature, over and over.
    private func playDemo() async {
        try? await Task.sleep(for: .seconds(2))
        let thermostat = MockProvider.thermostatID
        while !Task.isCancelled {
            for _ in 0..<3 {
                store.adjustSetpoint(.cooling, of: thermostat, by: -1)
                try? await Task.sleep(for: .milliseconds(350))
            }
            try? await Task.sleep(for: .seconds(1.5))
            await store.setLocked(false, device: "mock-lock")
            store.send(.setOn(true, device: "mock-light"))
            try? await Task.sleep(for: .seconds(2.5))
            for _ in 0..<3 {
                store.adjustSetpoint(.cooling, of: thermostat, by: 1)
                try? await Task.sleep(for: .milliseconds(350))
            }
            try? await Task.sleep(for: .seconds(1.5))
            await store.setLocked(true, device: "mock-lock")
            store.send(.setOn(false, device: "mock-light"))
            try? await Task.sleep(for: .seconds(2.5))
        }
    }

    private func networkChanged(online: Bool) {
        defer { wasOffline = !online }
        if online && wasOffline {
            Task { await store.reconnect() }
        }
    }
}

/// Allows every action. Only for snapshots with fake devices.
@MainActor
struct AllowGate: ConfirmationGate {
    func confirm(_ reason: String) async -> Bool { true }
}

/// Renders the panel with fake devices to PNG files, for a quick visual check.
@MainActor
enum Snapshot {
    static func render(to path: String) {
        Task { @MainActor in
            let store = HomeStore(provider: CompositeProvider(primary: MockProvider(latency: .milliseconds(50)), accessories: [MockLights()]),
                                  gate: AllowGate())
            await store.start()
            try? await Task.sleep(for: .milliseconds(300))
            write(store, path, suffix: "cool-light", scheme: .light)
            write(store, path, suffix: "cool-dark", scheme: .dark)
            // The same kinds of devices as the SmartRent account, without Hue.
            let plain = HomeStore(provider: CompositeProvider(primary: MockProvider(latency: .milliseconds(50)), accessories: [MockLights(paired: false)]),
                                  gate: AllowGate())
            await plain.start()
            write(plain, path, suffix: "smartrent-dark", scheme: .dark)
            if let lamp = store.lights.first(where: { $0.id == "hue:mock-lamp" }) {
                render(LightControls(device: lamp, store: store), path, suffix: "light-controls", scheme: .dark)
            }

            // A second home in another state: auto mode while heating, the door unlocked, a light on.
            let auto = HomeStore(provider: CompositeProvider(primary: MockProvider(latency: .milliseconds(50)), accessories: [MockLights()]),
                                 gate: AllowGate())
            await auto.start()
            auto.send(.setMode(.auto, device: MockProvider.thermostatID))
            auto.setSetpoint(.cooling, of: MockProvider.thermostatID, to: 79)
            auto.setSetpoint(.heating, of: MockProvider.thermostatID, to: 76)
            await auto.setLocked(false, device: "mock-lock")
            auto.send(.setOn(true, device: "mock-light"))
            try? await Task.sleep(for: .seconds(1.5))
            write(auto, path, suffix: "auto-dark", scheme: .dark)

            // The README hero: three panels side by side.
            let gallery = HStack(alignment: .top, spacing: 36) {
                framed(PanelView(store: store, isSnapshot: true), scheme: .dark)
                framed(PanelView(store: auto, isSnapshot: true), scheme: .dark)
                framed(PanelView(store: store, isSnapshot: true), scheme: .light)
            }
            .padding(48)
            .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
            render(gallery, path, suffix: "gallery", scheme: .dark, page: false)
            NSApplication.shared.terminate(nil)
        }
    }

    /// A panel as it looks under the menu bar: rounded corners and a soft shadow.
    private static func framed(_ panel: some View, scheme: ColorScheme) -> some View {
        panel
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            // Flatten first, so the shadow falls around the panel, not around every view inside it.
            .compositingGroup()
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }

    private static func write(_ store: HomeStore, _ path: String, suffix: String, scheme: ColorScheme) {
        render(PanelView(store: store, isSnapshot: true), path, suffix: suffix, scheme: scheme)
    }

    private static func render(_ content: some View, _ path: String, suffix: String, scheme: ColorScheme, page: Bool = true) {
        let view = content
            .background(page ? (scheme == .dark ? Color.black : Color.white) : Color.clear)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let url = URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(suffix).png"))
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            print("Wrote \(url.path)")
        }
    }
}
