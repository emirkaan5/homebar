import SwiftUI
import Core

/// A round thermostat dial. Drag a knob around the ring to change a set point;
/// the knob stays under the pointer from where it was grabbed. In auto mode the
/// ring has a heat knob and a cool knob.
struct ThermostatDial: View {
    let device: Device
    let store: HomeStore
    let isPanelVisible: Bool

    @State private var dragging: SetpointKind?
    @State private var grabOffset = 0.0
    @State private var lastValue: Int?
    /// Gusts that are still in the air. Each set point change adds one.
    @State private var gusts: [Gust] = []
    @State private var nextGustID = 0
    @Environment(\.colorScheme) private var scheme

    /// The ring starts at the lower left and turns clockwise 270° to the lower right.
    nonisolated private static let startAngle = 135.0
    nonisolated private static let sweep = 270.0
    private static let ringWidth: CGFloat = 10

    var body: some View {
        let thermostat = device.thermostat ?? Thermostat(attributes: [:])
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = side / 2 - 14
            let layout = Layout(center: center, radius: radius, range: thermostat.setpointRange)

            ZStack {
                disc(thermostat, layout: layout)
                ticks(thermostat, layout: layout)
                ring(layout: layout)
                activeArc(thermostat, layout: layout)
                if let current = thermostat.currentTemp {
                    currentMarker(at: layout.point(for: current))
                }
                ForEach(knobs(thermostat), id: \.self) { kind in
                    knob(kind, thermostat: thermostat, layout: layout)
                }
                centerText(thermostat)
                    .position(center)
                if let kind = singleKnob(thermostat) {
                    stepButtons(kind)
                        .position(x: center.x, y: center.y + radius - 4)
                }
            }
            .contentShape(Circle().inset(by: -14))
            .gesture(drag(thermostat, layout: layout))
            .opacity(device.isOnline ? 1 : 0.5)
            .allowsHitTesting(device.isOnline)
        }
        .frame(height: 236)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(thermostat: device.thermostat, by: 1) }
        .onKeyPress(.downArrow) { step(thermostat: device.thermostat, by: -1) }
        // The vent blows whenever a set point changes: from this panel, or from another app.
        .onChange(of: device.thermostat?.heatingSetpoint) { old, new in
            if old != nil, new != nil { blow(.heating) }
        }
        .onChange(of: device.thermostat?.coolingSetpoint) { old, new in
            if old != nil, new != nil { blow(.cooling) }
        }
        .task(id: gusts.last?.id) {
            // Drop gusts that have finished, so the animation can stop.
            try? await Task.sleep(for: .seconds(Gust.duration + 0.05))
            guard !Task.isCancelled else { return }
            gusts.removeAll { Date.now.timeIntervalSince($0.start) > Gust.duration }
        }
    }

    // MARK: Geometry

    private struct Layout {
        let center: CGPoint
        let radius: CGFloat
        let range: ClosedRange<Int>

        func angle(for value: Int) -> Double {
            let span = Double(range.upperBound - range.lowerBound)
            let fraction = min(max(Double(value - range.lowerBound) / span, 0), 1)
            return ThermostatDial.startAngle + ThermostatDial.sweep * fraction
        }

        func point(for value: Int, radius: CGFloat? = nil) -> CGPoint {
            point(at: angle(for: value), radius: radius ?? self.radius)
        }

        func point(at degrees: Double, radius: CGFloat) -> CGPoint {
            let radians = degrees * .pi / 180
            return CGPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
        }

        /// The value under an angle. Angles in the gap at the bottom go to the nearer end.
        func value(at degrees: Double) -> Int {
            var along = (degrees - ThermostatDial.startAngle).truncatingRemainder(dividingBy: 360)
            if along < 0 { along += 360 }
            if along > ThermostatDial.sweep {
                along = along > ThermostatDial.sweep + (360 - ThermostatDial.sweep) / 2 ? 0 : ThermostatDial.sweep
            }
            let span = Double(range.upperBound - range.lowerBound)
            return range.lowerBound + Int((along / ThermostatDial.sweep * span).rounded())
        }

        func angle(of point: CGPoint) -> Double {
            atan2(point.y - center.y, point.x - center.x) * 180 / .pi
        }

        func distance(of point: CGPoint) -> CGFloat {
            hypot(point.x - center.x, point.y - center.y)
        }
    }

    private func arc(from start: Double, to end: Double, layout: Layout) -> Path {
        Path { path in
            path.addArc(center: layout.center, radius: layout.radius,
                        startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        }
    }

    // MARK: Layers

    /// The inner disc: a vent grille at the top, and the air coming out of it.
    private func disc(_ thermostat: Thermostat, layout: Layout) -> some View {
        let diameter = (layout.radius - 22) * 2
        return ZStack(alignment: .top) {
            Circle().fill(Color.primary.opacity(0.035))
            AirflowView(flow: thermostat.flow, intensity: thermostat.intensity, gusts: gusts, isActive: isPanelVisible)
                // The air fades behind the numbers, so that it seems to pass behind them.
                .mask {
                    RadialGradient(
                        stops: [.init(color: .black.opacity(0.15), location: 0), .init(color: .black.opacity(0.15), location: 0.4), .init(color: .black, location: 0.8)],
                        center: .center, startRadius: 0, endRadius: diameter / 2
                    )
                }
            VentGrille(gustID: gusts.last?.id)
                .padding(.top, diameter * 0.15 - 13)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .position(layout.center)
    }

    /// Plays a gust of air from the vent: warm for heat, cool for cooling.
    private func blow(_ kind: SetpointKind) {
        let now = Date.now
        if let last = gusts.last, now.timeIntervalSince(last.start) < 0.12 { return }
        nextGustID += 1
        gusts.append(Gust(id: nextGustID, start: now, flow: kind == .heating ? .heat : .cool))
        if gusts.count > 6 { gusts.removeFirst(gusts.count - 6) }
    }

    private func adjust(_ kind: SetpointKind, by delta: Int) {
        store.adjustSetpoint(kind, of: device.id, by: delta)
    }

    private func ticks(_ thermostat: Thermostat, layout: Layout) -> some View {
        let tint = thermostat.flow.tint
        let low = min(thermostat.currentTemp ?? 0, activeTarget(thermostat) ?? 0)
        let high = max(thermostat.currentTemp ?? 0, activeTarget(thermostat) ?? 0)
        return Canvas { context, _ in
            for value in layout.range {
                let isMajor = value % 5 == 0
                let inner = layout.point(for: value, radius: layout.radius - (isMajor ? 20 : 17))
                let outer = layout.point(for: value, radius: layout.radius - 13)
                var line = Path()
                line.move(to: inner)
                line.addLine(to: outer)
                let isActive = activeTarget(thermostat) != nil && (low...high).contains(value)
                let color = isActive ? tint.opacity(0.8) : Color.primary.opacity(isMajor ? 0.28 : 0.14)
                context.stroke(line, with: .color(color), lineWidth: isMajor ? 1.5 : 1)
            }
        }
        .allowsHitTesting(false)
    }

    private func ring(layout: Layout) -> some View {
        arc(from: Self.startAngle, to: Self.startAngle + Self.sweep, layout: layout)
            .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
    }

    /// The part of the ring between the room temperature and the target, while the system works toward it.
    @ViewBuilder
    private func activeArc(_ thermostat: Thermostat, layout: Layout) -> some View {
        if let target = activeTarget(thermostat), let current = thermostat.currentTemp, target != current {
            let start = layout.angle(for: min(target, current))
            let end = layout.angle(for: max(target, current))
            let path = arc(from: start, to: end, layout: layout)
            let tint = thermostat.flow.tint
            ZStack {
                path.stroke(tint.opacity(0.45), style: StrokeStyle(lineWidth: Self.ringWidth + 6, lineCap: .round))
                    .blur(radius: 6)
                path.stroke(tint, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
            }
            .animation(Motion.snappy, value: target)
        }
    }

    private func currentMarker(at point: CGPoint) -> some View {
        Circle()
            .fill(Color.primary.opacity(0.85))
            .frame(width: 6, height: 6)
            .overlay(Circle().stroke(Palette.paper(scheme), lineWidth: 2))
            .position(point)
            .accessibilityHidden(true)
    }

    private func knob(_ kind: SetpointKind, thermostat: Thermostat, layout: Layout) -> some View {
        let value = thermostat.setpoint(kind) ?? layout.range.lowerBound
        let tint = kind == .heating ? Palette.heat : Palette.cool
        let isDragging = dragging == kind
        return Circle()
            .fill(Color.primary)
            .frame(width: 24, height: 24)
            .overlay(Circle().fill(tint).frame(width: 10, height: 10))
            .overlay(Circle().strokeBorder(Palette.paper(scheme), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: isDragging ? 6 : 3, y: 1)
            .scaleEffect(isDragging ? 1.18 : 1)
            .animation(Motion.snappy, value: isDragging)
            .position(layout.point(for: value))
            .accessibilityElement()
            .accessibilityLabel(kind == .heating ? "Heat set point" : "Cool set point")
            .accessibilityValue("\(value) degrees")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(kind, by: 1)
                case .decrement: adjust(kind, by: -1)
                @unknown default: break
                }
            }
    }

    private func centerText(_ thermostat: Thermostat) -> some View {
        VStack(spacing: 1) {
            switch thermostat.mode {
            case .heat, .auxHeat, .cool:
                let kind: SetpointKind = thermostat.mode == .cool ? .cooling : .heating
                Eyebrow(text: kind == .heating ? "Heat to" : "Cool to")
                bigNumber(thermostat.setpoint(kind))
            case .auto:
                Eyebrow(text: "Keep between")
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    bigNumber(thermostat.heatingSetpoint, size: 40)
                    Text("–").font(.system(size: 28, weight: .ultraLight, design: .rounded)).foregroundStyle(.tertiary)
                    bigNumber(thermostat.coolingSetpoint, size: 40)
                }
            case .off, nil:
                Eyebrow(text: "Inside")
                bigNumber(thermostat.currentTemp)
            }
            Text(caption(thermostat))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private func bigNumber(_ value: Int?, size: CGFloat = 56, tint: Color = .primary) -> some View {
        Text(value.map { "\($0)°" } ?? "--")
            .font(.system(size: size, weight: .light, design: .rounded))
            .tracking(size > 44 ? -1.5 : -1)
            .monospacedDigit()
            .foregroundStyle(tint)
            .contentTransition(.numericText(value: Double(value ?? 0)))
            .animation(Motion.snappy, value: value)
    }

    private func caption(_ thermostat: Thermostat) -> String {
        if thermostat.mode == .off || thermostat.mode == nil { return "System off" }
        return thermostat.currentTemp.map { "Inside \($0)°" } ?? ""
    }

    private func stepButtons(_ kind: SetpointKind) -> some View {
        HStack(spacing: 40) {
            stepButton("minus", label: "Lower") { adjust(kind, by: -1) }
            stepButton("plus", label: "Raise") { adjust(kind, by: 1) }
        }
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Palette.surface, in: Circle())
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(label)
    }

    // MARK: Interaction

    private func knobs(_ thermostat: Thermostat) -> [SetpointKind] {
        switch thermostat.mode {
        case .heat, .auxHeat: thermostat.heatingSetpoint == nil ? [] : [.heating]
        case .cool: thermostat.coolingSetpoint == nil ? [] : [.cooling]
        case .auto: [.heating, .cooling].filter { thermostat.setpoint($0) != nil }
        case .off, nil: []
        }
    }

    private func singleKnob(_ thermostat: Thermostat) -> SetpointKind? {
        let kinds = knobs(thermostat)
        return kinds.count == 1 ? kinds[0] : nil
    }

    /// The set point the system works toward now, if any.
    private func activeTarget(_ thermostat: Thermostat) -> Int? {
        switch thermostat.flow {
        case .heat: thermostat.heatingSetpoint
        case .cool: thermostat.coolingSetpoint
        case .idle: nil
        }
    }

    private func drag(_ thermostat: Thermostat, layout: Layout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let pointer = layout.angle(of: gesture.location)
                if dragging == nil {
                    // Start only on the ring, and take the knob nearest to the pointer.
                    guard abs(layout.distance(of: gesture.startLocation) - layout.radius) < 22 else { return }
                    let candidates = knobs(thermostat).map { kind in
                        (kind, Self.difference(pointer, layout.angle(for: thermostat.setpoint(kind) ?? 0)))
                    }
                    guard let nearest = candidates.min(by: { abs($0.1) < abs($1.1) }) else { return }
                    dragging = nearest.0
                    // A press on the knob keeps its offset; a press elsewhere on the ring moves the knob there.
                    grabOffset = abs(nearest.1) < 12 ? nearest.1 : 0
                    lastValue = thermostat.setpoint(nearest.0)
                }
                guard let kind = dragging else { return }
                let requested = layout.value(at: pointer - grabOffset)
                guard let value = store.setSetpoint(kind, of: device.id, to: requested), value != lastValue else { return }
                lastValue = value
                if value != requested { Haptics.bump() } else { Haptics.tick() }
            }
            .onEnded { _ in
                dragging = nil
                lastValue = nil
            }
    }

    private func step(thermostat: Thermostat?, by delta: Int) -> KeyPress.Result {
        guard let thermostat, let kind = singleKnob(thermostat) ?? knobs(thermostat).first else { return .ignored }
        adjust(kind, by: delta)
        return .handled
    }

    /// The signed smallest difference between two angles, in -180…180.
    private static func difference(_ a: Double, _ b: Double) -> Double {
        var delta = (a - b).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }
}
