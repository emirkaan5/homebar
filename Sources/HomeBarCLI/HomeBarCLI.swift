import Foundation
import Core
import SmartRentProvider
import Platform

/// A command-line client. `devices` is the Phase 0 check: it signs in and prints the device list.
@main
struct HomeBarCLI {
    static let usage = """
    usage: homebar-cli [--mock] [--home <id>] [--device <id>] <command>

      login                      Sign in with your SmartRent account. The session is saved in the Keychain.
      logout                     Delete the saved session.
      devices                    List your homes and devices.
      status                     Show the thermostat.
      mode <heat|cool|auto|off>  Set the thermostat mode.
      heat <degrees>             Set the heating set point.
      cool <degrees>             Set the cooling set point.
      fan <auto|on>              Set the fan mode.
      light <on|off>             Turn the first light switch on or off.
      lock                       Lock the door.
      unlock                     Unlock the door. Asks for Touch ID or your Mac password first.
      watch                      Print live updates until you press Control-C.
      inspect                    Print hub field names and all device attributes (read-only).

    --home and --device select one when the account has more than one.
    --mock uses fake devices and no account.
    """

    static func main() async {
        // Print each line at once, also when the output goes to a pipe or a file (for `watch`).
        setvbuf(stdout, nil, _IOLBF, 0)
        var arguments = Array(CommandLine.arguments.dropFirst())
        func option(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            defer { arguments.removeSubrange(index...index + 1) }
            return arguments[index + 1]
        }
        let homeID = option("--home")
        let deviceID = option("--device")
        let usesMock = arguments.contains("--mock")
        arguments.removeAll { $0 == "--mock" }

        guard let command = arguments.first else {
            print(usage)
            exit(2)
        }
        let provider: any HomeProvider = usesMock ? MockProvider() : SmartRentProvider(secrets: KeychainStore())
        let cli = HomeBarCLI(provider: provider, homeID: homeID, deviceID: deviceID)

        do {
            try await cli.run(command, Array(arguments.dropFirst()))
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    let provider: any HomeProvider
    let homeID: String?
    let deviceID: String?

    func run(_ command: String, _ arguments: [String]) async throws {
        switch command {
        case "login":
            try await login()
        case "logout":
            await provider.signOut()
            print("Signed out. The saved session is deleted.")
        case "devices":
            try await requireSession()
            try await listDevices()
        case "status":
            try await requireSession()
            let (_, thermostat) = try await findThermostat()
            printStatus(thermostat)
        case "mode", "heat", "cool", "fan":
            guard let value = arguments.first else { Self.fail("\(command) needs a value.\n\n\(Self.usage)") }
            try await requireSession()
            let (devices, thermostat) = try await findThermostat()
            try await sendAndConfirm(try makeCommand(command, value, thermostat.id), devices: devices)
        case "light":
            guard let value = arguments.first, ["on", "off"].contains(value) else { Self.fail("light needs on or off.") }
            try await requireSession()
            let devices = try await provider.devices(in: try await findHome().id)
            let lights = devices.filter { $0.kind == .switchBinary }
            guard let light = deviceID.flatMap({ id in lights.first { $0.id == id } }) ?? lights.first else {
                Self.fail("No light switch was found in this home.")
            }
            try await sendAndConfirm(.setOn(value == "on", device: light.id), devices: devices)
        case "lock", "unlock":
            try await requireSession()
            let devices = try await provider.devices(in: try await findHome().id)
            let locks = devices.filter { $0.kind == .lock }
            let lock = deviceID.flatMap { id in locks.first { $0.id == id } } ?? locks.first
            guard let lock else { Self.fail("No lock was found in this home.") }
            if command == "unlock" {
                guard await BiometricGate().confirm("unlock \(lock.name)") else { Self.fail("Unlock was cancelled.") }
            }
            try await sendAndConfirm(.setLocked(command == "lock", device: lock.id), devices: devices, timeout: .seconds(40))
        case "watch":
            try await requireSession()
            try await watch()
        case "inspect":
            try await requireSession()
            try await inspect()
        default:
            print(Self.usage)
            exit(2)
        }
    }

    // MARK: Commands

    private func login() async throws {
        let email = Self.prompt("SmartRent email: ")
        let password = Self.promptSecret("Password (hidden): ")
        guard !email.isEmpty, !password.isEmpty else { Self.fail("Enter an email and a password.") }
        switch try await provider.signIn(email: email, password: password) {
        case .signedIn:
            break
        case .needsTwoFactor(let challenge):
            let code = Self.prompt("Two-factor code: ")
            try await provider.completeTwoFactor(challenge: challenge, code: code)
        }
        print("Signed in. The session is saved in your Keychain. Next, run: homebar-cli devices")
    }

    private func listDevices() async throws {
        let homes = try await provider.homes()
        if homes.isEmpty { print("No homes were found on this account.") }
        for home in homes {
            print("\(home.name)  [home \(home.id)]")
            let devices = try await provider.devices(in: home.id)
            if devices.isEmpty { print("  (no devices)") }
            for device in devices {
                let kind = device.kind == .unknown ? device.rawType : device.kind.rawValue
                let offline = device.isOnline ? "" : "  (offline)"
                print("  \(kind.padding(toLength: 14, withPad: " ", startingAt: 0)) \(device.name)  [device \(device.id)]\(offline)")
            }
        }
    }

    private func printStatus(_ device: Device) {
        guard let t = device.thermostat else { return }
        func degrees(_ value: Int?) -> String { value.map { "\($0)°" } ?? "--" }
        print("\(device.name)  [device \(device.id)]\(device.isOnline ? "" : "  (offline)")")
        print("  Inside      \(degrees(t.currentTemp))\(t.humidity.map { "   humidity \($0)%" } ?? "")")
        print("  Mode        \(t.mode?.title ?? "unknown")   fan \(t.fanMode?.title ?? "unknown")")
        print("  Now         \(t.operatingState)")
        print("  Set points  heat \(degrees(t.heatingSetpoint))   cool \(degrees(t.coolingSetpoint))")
    }

    private func makeCommand(_ command: String, _ value: String, _ id: Device.ID) throws -> DeviceCommand {
        switch command {
        case "mode":
            guard let mode = ThermostatMode(rawValue: value.lowercased()) else { Self.fail("Mode must be heat, cool, auto, off, or aux_heat.") }
            return .setMode(mode, device: id)
        case "fan":
            guard let fan = FanMode(rawValue: value.lowercased()) else { Self.fail("Fan must be auto or on.") }
            return .setFanMode(fan, device: id)
        default:
            guard let degrees = Int(value), (10...95).contains(degrees) else { Self.fail("Enter a whole number of degrees.") }
            return command == "heat" ? .setHeatingSetpoint(degrees, device: id) : .setCoolingSetpoint(degrees, device: id)
        }
    }

    /// Connects, sends the command, and waits until the thermostat reports the new value.
    private func sendAndConfirm(_ command: DeviceCommand, devices: [Device], timeout limit: Duration = .seconds(25)) async throws {
        let stream = await provider.updates(for: devices.map(\.id))
        let timeout = Task {
            try await Task.sleep(for: limit)
            Self.fail("The device did not confirm in time. The change may still arrive.")
        }
        var sent = false
        for await event in stream {
            switch event {
            case .connection(.live) where !sent:
                sent = true
                try await provider.send(command)
                print("Sent \(command.change.name) = \(command.change.value). Waiting for the device to confirm…")
            case .attribute(let id, let name, let value, _) where sent && id == command.deviceID && name == command.change.name:
                timeout.cancel()
                print("Confirmed: \(name) = \(value)")
                return
            case .sessionExpired:
                Self.fail("Your session expired. Run: homebar-cli login")
            default:
                continue
            }
        }
    }

    private func watch() async throws {
        let home = try await findHome()
        let devices = try await provider.devices(in: home.id)
        let names = Dictionary(devices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        print("Watching \(devices.count) devices in \(home.name). Press Control-C to stop.")
        for await event in await provider.updates(for: devices.map(\.id)) {
            let time = Date().formatted(date: .omitted, time: .standard)
            switch event {
            case .connection(let state): print("\(time)  connection: \(state)")
            case .attribute(let id, let name, let value, _): print("\(time)  \(names[id] ?? id): \(name) = \(value)")
            case .sessionExpired: Self.fail("Your session expired. Run: homebar-cli login")
            }
        }
    }

    /// Prints field names of each hub (not values, which can include an address)
    /// and every attribute of every device.
    private func inspect() async throws {
        guard let smartRent = provider as? SmartRentProvider else { Self.fail("inspect works only with a SmartRent account.") }
        let (hubs, devices) = try await smartRent.rawData()
        for hub in hubs {
            let id = hub["id"]?.stringValue ?? "?"
            print("hub \(id) fields: \(Self.describeKeys(hub))")
            for device in devices[id] ?? [] {
                print("  device \(device["id"]?.stringValue ?? "?")  type=\(device["type"]?.stringValue ?? "?")  name=\(device["name"]?.stringValue ?? "?")")
                let fields = (device.objectValue ?? [:]).filter { $0.key != "attributes" }.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value.stringValue ?? $0.value["name"]?.stringValue ?? "<\(Self.kind($0.value))>")" }
                print("    " + fields.joined(separator: "  "))
                for attribute in device["attributes"]?.arrayValue ?? [] {
                    let fields = (attribute.objectValue ?? [:]).sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value.stringValue ?? "<\(Self.kind($0.value))>")" }
                    print("    - " + fields.joined(separator: "  "))
                }
            }
        }
    }

    private static func describeKeys(_ value: JSONValue, prefix: String = "") -> String {
        (value.objectValue ?? [:]).sorted { $0.key < $1.key }.map { key, child in
            child.objectValue != nil ? describeKeys(child, prefix: prefix + key + ".") : prefix + key + ":" + kind(child)
        }.joined(separator: ", ")
    }

    private static func kind(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "bool"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    // MARK: Helpers

    private func requireSession() async throws {
        if provider is SmartRentProvider {
            // A rebuilt binary must be allowed to read the Keychain item again.
            // Report that, instead of "not signed in".
            do {
                _ = try KeychainStore().read(SmartRentProvider.sessionKey)
            } catch {
                Self.fail("macOS did not let homebar-cli read your saved session (\(error.localizedDescription)). "
                    + "Run the command in the Terminal app and click Always Allow when macOS asks, or run: homebar-cli login")
            }
        }
        guard await provider.restoreSession() else { Self.fail("You are not signed in. Run: homebar-cli login") }
    }

    private func findHome() async throws -> Home {
        let homes = try await provider.homes()
        if let homeID {
            guard let home = homes.first(where: { $0.id == homeID }) else { Self.fail("No home has the ID \(homeID). Run: homebar-cli devices") }
            return home
        }
        guard let home = homes.first else { Self.fail("No homes were found on this account.") }
        if homes.count > 1 { print("Using \(home.name). Use --home <id> to select a different home.") }
        return home
    }

    private func findThermostat() async throws -> (all: [Device], thermostat: Device) {
        let devices = try await provider.devices(in: try await findHome().id)
        let thermostats = devices.filter { $0.kind == .thermostat }
        if let deviceID {
            guard let match = thermostats.first(where: { $0.id == deviceID }) else { Self.fail("No thermostat has the ID \(deviceID).") }
            return (devices, match)
        }
        guard let first = thermostats.first else { Self.fail("No thermostat was found in this home.") }
        if thermostats.count > 1 { print("Using \(first.name). Use --device <id> to select a different thermostat.") }
        return (devices, first)
    }

    static func prompt(_ text: String) -> String {
        print(text, terminator: "")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Reads a password without showing it on the screen.
    static func promptSecret(_ text: String) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        defer { _ = buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard let result = readpassphrase(text, &buffer, buffer.count, 0) else { return "" }
        return String(cString: result)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}
