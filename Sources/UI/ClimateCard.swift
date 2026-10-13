import SwiftUI
import Core

struct ClimateCard: View {
    let device: Device
    let store: HomeStore
    let isPanelVisible: Bool

    var body: some View {
        let thermostat = device.thermostat ?? Thermostat(attributes: [:])
        VStack(spacing: 12) {
            HStack {
                Text(device.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                StatusPill(
                    text: thermostat.statusText,
                    tint: thermostat.flow.tint,
                    isPending: store.isPending(device.id),
                    isOffline: !device.isOnline
                )
            }

            ThermostatDial(device: device, store: store, isPanelVisible: isPanelVisible)

            SegmentedPicker(
                options: thermostat.supportedModes.map { mode in
                    .init(value: mode, title: mode.title, symbol: mode.symbol, tint: mode.tint)
                },
                selection: thermostat.mode,
                isEnabled: device.isOnline
            ) { mode in
                if mode != thermostat.mode { store.send(.setMode(mode, device: device.id)) }
            }

            HStack(spacing: 10) {
                Eyebrow(text: "Fan")
                SegmentedPicker(
                    options: FanMode.allCases.map { fan in
                        .init(value: fan, title: fan.title, symbol: fan == .on ? "fan.fill" : "fan", tint: Palette.fan)
                    },
                    selection: thermostat.fanMode,
                    isEnabled: device.isOnline
                ) { fan in
                    if fan != thermostat.fanMode { store.send(.setFanMode(fan, device: device.id)) }
                }
                .frame(width: 150)
                Spacer(minLength: 0)
                if let humidity = thermostat.humidity {
                    Label("\(humidity)%", systemImage: "humidity")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Humidity \(humidity) percent")
                }
            }
        }
        .card()
    }
}

/// A small status label with a coloured dot, such as "● Cooling".
struct StatusPill: View {
    let text: String
    let tint: Color
    var isPending = false
    var isOffline = false

    var body: some View {
        HStack(spacing: 5) {
            if isPending {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(isOffline ? Color.red : tint).frame(width: 6, height: 6)
            }
            Text(isOffline ? "Offline" : text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Palette.surface, in: Capsule())
        .animation(Motion.tint, value: text)
    }
}

extension ThermostatMode {
    var symbol: String {
        switch self {
        case .heat: "flame.fill"
        case .cool: "snowflake"
        case .auto: "arrow.up.arrow.down"
        case .auxHeat: "flame"
        case .off: "power"
        }
    }

    var tint: Color {
        switch self {
        case .heat, .auxHeat: Palette.heat
        case .cool: Palette.cool
        case .auto: Palette.auto
        case .off: .secondary
        }
    }
}

extension Thermostat {
    /// The animation follows what the system does now, not only the selected mode.
    var flow: Airflow {
        guard mode != .off else { return .idle }
        switch operatingState {
        case .heating: return .heat
        case .cooling: return .cool
        case .fanOnly, .idle, .unknown: return .idle
        }
    }

    var intensity: Double {
        let target: Int? = switch flow {
        case .heat: heatingSetpoint
        case .cool: coolingSetpoint
        case .idle: nil
        }
        guard let target, let currentTemp else { return 0.3 }
        return min(Double(abs(target - currentTemp)) / 6, 1)
    }

    var statusText: String {
        switch (mode, operatingState) {
        case (.off, _), (nil, _): "Off"
        case (_, .heating): "Heating"
        case (_, .cooling): "Cooling"
        case (_, .fanOnly): "Fan only"
        default: "Idle"
        }
    }
}

extension Device {
    /// "Front Door - Lock" becomes "Front Door".
    var displayName: String {
        let parts = name.components(separatedBy: " - ")
        return parts.count > 1 && !parts[0].isEmpty ? parts[0] : name
    }
}
