import SwiftUI
import Core

/// A light. Click to turn it on or off. Drag across a light that can dim to set
/// its brightness: the fill follows the pointer, like Control Center.
struct LightTile: View {
    let device: Device
    let store: HomeStore

    @State private var width: CGFloat = 1
    @State private var isDragging = false
    @State private var isPressed = false
    @State private var showsControls = false

    private var light: LightState { device.lightState ?? LightState(attributes: [:]) }
    private var level: Int { light.brightness ?? 100 }

    var body: some View {
        let glow = LightColor.color(for: light)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.surface)
            // The fill shows the brightness, in the colour of the light.
            if light.isOn {
                Rectangle()
                    .fill(LinearGradient(colors: [glow.opacity(0.45), glow.opacity(0.25)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * CGFloat(level) / 100)
                    .animation(isDragging ? nil : Motion.snappy, value: level)
                    .transition(.opacity)
            }
            content(glow: glow)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
        .scaleEffect(isPressed && !isDragging ? 0.97 : 1)
        .animation(Motion.press, value: isPressed)
        .animation(Motion.snappy, value: light.isOn)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .gesture(gesture)
        .opacity(device.isOnline ? 1 : 0.5)
        .allowsHitTesting(device.isOnline)
        .popover(isPresented: $showsControls, arrowEdge: .bottom) {
            LightControls(device: device, store: store)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.displayName)
        .accessibilityValue(light.isOn ? (light.isDimmable ? "On, \(level) percent" : "On") : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityAdjustableAction { direction in
            guard light.isDimmable else { return }
            switch direction {
            case .increment: store.send(.setBrightness(min(level + 10, 100), device: device.id))
            case .decrement: store.send(.setBrightness(max(level - 10, 1), device: device.id))
            @unknown default: break
            }
        }
    }

    /// Tiles wider than this use one row: icon, name and status, then controls.
    static let wideWidth: CGFloat = 230

    @ViewBuilder
    private func content(glow: Color) -> some View {
        if width > Self.wideWidth {
            HStack(spacing: 10) {
                bulb(glow)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(light.isOn ? glow.opacity(0.22) : Palette.surface))
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                    statusText
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                accessories
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    bulb(glow)
                    Spacer(minLength: 0)
                    accessories
                }
                .frame(height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    statusText
                        .font(.system(size: 12, weight: .semibold))
                    Text(device.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .padding(10)
        }
    }

    private func bulb(_ glow: Color) -> some View {
        Image(systemName: light.isOn ? "lightbulb.fill" : "lightbulb")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(light.isOn ? glow : Color.secondary)
            .contentTransition(.symbolEffect(.replace))
    }

    private var statusText: some View {
        Text(light.isOn ? (light.isDimmable ? "\(level)%" : "On") : "Off")
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(light.isOn ? level : 0)))
    }

    /// The waiting spinner and, for colour lights, the palette button.
    private var accessories: some View {
        HStack(spacing: 4) {
            if store.isPending(device.id) {
                ProgressView().controlSize(.mini)
            }
            if light.supportsColor || light.supportsTemperature {
                Button { showsControls = true } label: {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(PressableStyle(scale: 0.85))
                .help("Colour and brightness")
                .accessibilityLabel("Colour for \(device.displayName)")
            }
        }
    }

    /// A click toggles the light. A drag sets the brightness where the pointer is.
    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                isPressed = true
                guard light.isDimmable, isDragging || abs(drag.translation.width) > 4 else { return }
                isDragging = true
                let requested = Int((drag.location.x / width * 100).rounded())
                let clamped = min(max(requested, 1), 100)
                if clamped != level || !light.isOn {
                    if clamped != requested, clamped != level { Haptics.bump() }
                    store.send(.setBrightness(clamped, device: device.id))
                }
            }
            .onEnded { _ in
                if !isDragging { toggle() }
                isDragging = false
                isPressed = false
            }
    }

    private func toggle() {
        store.send(.setOn(!light.isOn, device: device.id))
    }
}

/// Brightness, shades of white, and colours for one light.
public struct LightControls: View {
    let device: Device
    let store: HomeStore

    @State private var width: CGFloat = 1

    public init(device: Device, store: HomeStore) {
        self.device = device
        self.store = store
    }

    private var light: LightState { device.lightState ?? LightState(attributes: [:]) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(device.displayName).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(light.isOn ? "Turn Off" : "Turn On") {
                    store.send(.setOn(!light.isOn, device: device.id))
                }
                .buttonStyle(MonoButtonStyle(isFilled: !light.isOn))
            }

            if light.isDimmable {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Brightness")
                    brightnessSlider
                }
            }

            if let range = light.mirekRange {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "White")
                    HStack(spacing: 8) {
                        ForEach(LightColor.whites, id: \.kelvin) { white in
                            let mirek = min(max(1_000_000 / white.kelvin, range.lowerBound), range.upperBound)
                            Swatch(color: LightColor.kelvin(Double(white.kelvin)), title: white.name,
                                   isSelected: light.isOn && !light.showsColor && abs((light.mirek ?? 0) - mirek) <= 8) {
                                store.send(.setColorTemperature(mirek: mirek, device: device.id))
                            }
                        }
                    }
                }
            }

            if light.supportsColor {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Colour")
                    HStack(spacing: 8) {
                        ForEach(LightColor.presets, id: \.name) { preset in
                            Swatch(color: LightColor.xy(preset.xy), title: preset.name,
                                   isSelected: light.isOn && light.showsColor && LightColor.isNear(light.color, preset.xy)) {
                                store.send(.setColor(preset.xy, device: device.id))
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private var brightnessSlider: some View {
        let level = light.isOn ? (light.brightness ?? 100) : 0
        return ZStack(alignment: .leading) {
            Capsule().fill(Palette.surface)
            Capsule()
                .fill(LightColor.color(for: light).opacity(0.85))
                .frame(width: max(width * CGFloat(level) / 100, level > 0 ? 24 : 0))
            HStack {
                Image(systemName: "sun.min.fill")
                Spacer()
                Image(systemName: "sun.max.fill")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
        }
        .frame(height: 24)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { drag in
                let value = min(max(Int((drag.location.x / width * 100).rounded()), 1), 100)
                if value != light.brightness || !light.isOn {
                    store.send(.setBrightness(value, device: device.id))
                }
            }
        )
        .accessibilityElement()
        .accessibilityLabel("Brightness")
        .accessibilityValue("\(level) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: store.send(.setBrightness(min(level + 10, 100), device: device.id))
            case .decrement: store.send(.setBrightness(max(level - 10, 1), device: device.id))
            @unknown default: break
            }
        }
    }
}

private struct Swatch: View {
    let color: Color
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .padding(3)
                .overlay(Circle().strokeBorder(Color.primary, lineWidth: isSelected ? 2 : 0))
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(Motion.snappy, value: isSelected)
    }
}

/// Approximate screen colours for light colours, and the swatch presets.
enum LightColor {
    static let whites: [(name: String, kelvin: Int)] = [
        ("Candle", 2200), ("Warm", 2700), ("Neutral", 4000), ("Daylight", 5000), ("Cool", 6500),
    ]

    /// Colours that most Hue colour gamuts can show. The bridge moves any colour
    /// outside a light's gamut to the nearest one it can show.
    static let presets: [(name: String, xy: ColorXY)] = [
        ("Red", ColorXY(x: 0.675, y: 0.322)),
        ("Orange", ColorXY(x: 0.58, y: 0.39)),
        ("Yellow", ColorXY(x: 0.48, y: 0.47)),
        ("Green", ColorXY(x: 0.2, y: 0.7)),
        ("Blue", ColorXY(x: 0.16, y: 0.06)),
        ("Purple", ColorXY(x: 0.27, y: 0.12)),
        ("Pink", ColorXY(x: 0.45, y: 0.22)),
    ]

    /// The colour a light shows now. A plain switch glows warm white.
    static func color(for light: LightState) -> Color {
        if light.showsColor, let point = light.color { return xy(point) }
        if let mirek = light.mirek, mirek > 0 { return kelvin(1_000_000 / Double(mirek)) }
        return kelvin(2900)
    }

    static func isNear(_ a: ColorXY?, _ b: ColorXY) -> Bool {
        guard let a else { return false }
        return hypot(a.x - b.x, a.y - b.y) < 0.03
    }

    /// CIE xy to sRGB, at full brightness.
    static func xy(_ color: ColorXY) -> Color {
        guard color.y > 0 else { return .white }
        let bigY = 1.0
        let bigX = bigY / color.y * color.x
        let bigZ = bigY / color.y * (1 - color.x - color.y)
        var r = bigX * 3.2406 - bigY * 1.5372 - bigZ * 0.4986
        var g = -bigX * 0.9689 + bigY * 1.8758 + bigZ * 0.0415
        var b = bigX * 0.0557 - bigY * 0.2040 + bigZ * 1.0570
        let peak = max(r, g, b, 1e-6)
        (r, g, b) = (max(r, 0) / peak, max(g, 0) / peak, max(b, 0) / peak)
        func gamma(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        return Color(red: gamma(r), green: gamma(g), blue: gamma(b))
    }

    /// A colour temperature to sRGB (Tanner Helland's approximation).
    static func kelvin(_ kelvin: Double) -> Color {
        let t = min(max(kelvin, 1000), 40000) / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        func unit(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
        return Color(red: unit(r), green: unit(g), blue: unit(b))
    }
}
