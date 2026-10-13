import SwiftUI
import Core

/// The menu bar icon: what the HVAC does now, the inside temperature, and the door.
public struct MenuBarLabel: View {
    let store: HomeStore

    public init(store: HomeStore) {
        self.store = store
    }

    public var body: some View {
        let thermostat = store.thermostats.first?.thermostat
        let lock = store.locks.first.flatMap { store.confirmedValue(LockAttribute.locked, of: $0.id) }.flatMap { Bool($0) }
        HStack(spacing: 4) {
            Image(systemName: symbol(for: thermostat))
                .contentTransition(.symbolEffect(.replace))
            if let temperature = thermostat?.currentTemp {
                Text("\(temperature)°")
            }
            if let lock {
                Image(systemName: lock ? "lock.fill" : "lock.open.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .accessibilityLabel(accessibilityText(thermostat, lock: lock))
    }

    private func symbol(for thermostat: Thermostat?) -> String {
        switch thermostat?.flow {
        case .heat: "flame.fill"
        case .cool: "snowflake"
        default: "thermometer.medium"
        }
    }

    private func accessibilityText(_ thermostat: Thermostat?, lock: Bool?) -> String {
        var parts: [String] = []
        if let temperature = thermostat?.currentTemp { parts.append("Inside \(temperature) degrees") }
        if let lock { parts.append(lock ? "Door locked" : "Door unlocked") }
        return parts.isEmpty ? "HomeBar" : parts.joined(separator: ", ")
    }
}
