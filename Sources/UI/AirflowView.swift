import SwiftUI

/// What the air from the vent is doing.
enum Airflow: Equatable, Sendable {
    case heat, cool, idle

    var tint: Color {
        switch self {
        case .heat: Palette.heat
        case .cool: Palette.cool
        case .idle: .secondary
        }
    }
}

/// A burst of air that plays once, when the person changes a set point.
struct Gust: Equatable, Identifiable, Sendable {
    let id: Int
    let start: Date
    let flow: Airflow

    static let duration = 1.3
}

/// Air from an HVAC vent, drawn as wind streaks.
///
/// - Steady streaks show what the system does now (heating, cooling, idle).
/// - Each gust fans out of the vent fast and slows down, like a puff of air.
///
/// Every streak is a pure function of time, so there is no per-frame state.
/// The view stops drawing when it has nothing to show or the panel is closed.
struct AirflowView: View {
    let flow: Airflow
    /// 0…1. More and faster streaks when the room is far from the set point.
    let intensity: Double
    let gusts: [Gust]
    let isActive: Bool

    @Environment(\.reducesMotion) private var reduceMotion
    @State private var previousFlow: Airflow = .idle
    @State private var changedAt: Date = .distantPast

    private static let maximumLife = 2.5

    private var isAnimating: Bool {
        isActive && !reduceMotion && (flow != .idle || previousFlow != .idle || !gusts.isEmpty)
    }

    var body: some View {
        ZStack {
            // A soft glow behind the vent, so the state reads even without motion.
            RadialGradient(colors: [flow.tint.opacity(flow == .idle ? 0 : 0.22), .clear],
                           center: UnitPoint(x: 0.5, y: 0.1), startRadius: 0, endRadius: 140)
                .animation(Motion.tint, value: flow)
            if reduceMotion, let gust = gusts.last {
                // Without movement, a gust is a short glow at the vent.
                GustGlow(tint: gust.flow.tint)
                    .id(gust.id)
            }
            if isAnimating {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    Canvas { context, size in
                        let now = timeline.date
                        let vent = Self.vent(in: size)
                        drawSteadyAir(in: &context, size: size, vent: vent, now: now)
                        for gust in gusts {
                            drawGust(gust, in: &context, size: size, vent: vent, now: now)
                        }
                    }
                }
            }
        }
        .onChange(of: flow) { old, _ in
            previousFlow = old
            changedAt = .now
        }
        .task(id: flow) {
            try? await Task.sleep(for: .seconds(Self.maximumLife + 0.1))
            if !Task.isCancelled { previousFlow = flow }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The line the air leaves from: the bottom of the grille.
    static func vent(in size: CGSize) -> CGRect {
        let width = size.width * 0.34
        return CGRect(x: (size.width - width) / 2, y: size.height * 0.15, width: width, height: 1)
    }

    // MARK: Steady air

    private func drawSteadyAir(in context: inout GraphicsContext, size: CGSize, vent: CGRect, now: Date) {
        let time = now.timeIntervalSinceReferenceDate
        let count = Int(10 + 10 * intensity)
        let travel = size.height - vent.minY
        let speed = 0.8 + 0.4 * intensity

        for index in 0..<count {
            let life = 1.6 + 0.9 * Self.noise(index, 1)
            let age = (time + Self.noise(index, 2) * life).truncatingRemainder(dividingBy: life)
            let style = now.addingTimeInterval(-age) < changedAt ? previousFlow : flow
            guard style != .idle else { continue }
            let progress = age / life
            let startX = vent.minX + Self.noise(index, 3) * vent.width
            let phase = Self.noise(index, 4) * 2 * .pi
            let envelope = min(progress / 0.15, 1) * min((1 - progress) / 0.4, 1)

            let position: (Double) -> CGPoint = { p in
                // Warm air slows and drifts up at the end. Cold air falls faster.
                let fall = style == .heat ? 1.05 * p - 0.45 * p * p * p : p + 0.3 * p * p
                return CGPoint(
                    x: startX + (startX - vent.midX) * 0.6 * p + sin(p * 7 + phase) * 6 * p,
                    y: vent.minY + 6 + travel * speed * fall * 0.85
                )
            }
            drawStreak(in: &context, at: progress, step: 0.035, position: position,
                       color: style.tint, opacity: 0.55 * envelope, width: 1.4)
        }
    }

    // MARK: Gusts

    private func drawGust(_ gust: Gust, in context: inout GraphicsContext, size: CGSize, vent: CGRect, now: Date) {
        let elapsed = now.timeIntervalSince(gust.start)
        guard elapsed >= 0, elapsed < Gust.duration else { return }

        // A flash at the vent as the air leaves.
        let flash = max(0, 1 - elapsed / 0.45)
        if flash > 0 {
            let glow = CGRect(x: vent.midX - vent.width * 0.7, y: vent.minY - 10, width: vent.width * 1.4, height: 26)
            context.fill(Path(ellipseIn: glow), with: .color(gust.flow.tint.opacity(0.35 * flash)))
        }

        let travel = (size.height - vent.minY) * 1.05
        for index in 0..<24 {
            let delay = Self.noise(index, 7 + gust.id % 5) * 0.22
            let local = (elapsed - delay) / (Gust.duration - 0.22)
            guard local > 0, local < 1 else { continue }
            // The streaks fan out from the vent, up to 55° to each side.
            let spread = (Self.noise(index, 8) * 2 - 1) * 55 * .pi / 180
            let startX = vent.minX + Self.noise(index, 9) * vent.width
            let wave = Self.noise(index, 10) * 2 * .pi
            let reach = 0.75 + 0.35 * Self.noise(index, 11)

            let position: (Double) -> CGPoint = { p in
                // Ease out: the air leaves fast and slows, like a puff.
                let eased = 1 - pow(1 - p, 3)
                let distance = travel * reach * eased
                return CGPoint(
                    x: startX + sin(spread) * distance + cos(spread) * sin(eased * 9 + wave) * 4,
                    y: vent.minY + 4 + cos(spread) * distance
                )
            }
            let fade = pow(1 - local, 1.4) * min(local / 0.08, 1)
            drawStreak(in: &context, at: local, step: 0.05, position: position,
                       color: gust.flow.tint, opacity: 0.95 * fade, width: 2)
        }
    }

    // MARK: Drawing

    /// Draws a streak as a short trail behind its head that thins and fades toward the tail.
    private func drawStreak(
        in context: inout GraphicsContext, at progress: Double, step: Double,
        position: (Double) -> CGPoint, color: Color, opacity: Double, width: CGFloat
    ) {
        guard opacity > 0.01 else { return }
        let segments = 6
        var previous = position(progress)
        for segment in 1...segments {
            let p = max(progress - Double(segment) * step, 0)
            let point = position(p)
            var line = Path()
            line.move(to: previous)
            line.addLine(to: point)
            let falloff = 1 - Double(segment - 1) / Double(segments)
            context.stroke(line, with: .color(color.opacity(opacity * falloff)),
                           style: StrokeStyle(lineWidth: width * falloff + 0.4, lineCap: .round))
            previous = point
            if p == 0 { break }
        }
    }

    /// A stable pseudo-random value in 0..<1.
    private static func noise(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }
}

/// A glow at the vent that brightens and fades once. Opacity only, for Reduce Motion.
private struct GustGlow: View {
    let tint: Color
    @State private var opacity = 0.0

    var body: some View {
        RadialGradient(colors: [tint.opacity(0.55), .clear], center: UnitPoint(x: 0.5, y: 0.15), startRadius: 0, endRadius: 90)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.15)) { opacity = 1 } completion: {
                    withAnimation(.easeOut(duration: 0.9)) { opacity = 0 }
                }
            }
    }
}

/// The vent grille at the top of the dial. Its slats swing open during a gust.
struct VentGrille: View {
    let gustID: Int?

    @Environment(\.reducesMotion) private var reduceMotion

    /// How far the slats swing open during a gust.
    private var openAngle: Double { reduceMotion ? 0 : 38 }

    var body: some View {
        ZStack {
            Capsule().fill(Color.primary.opacity(0.08))
            Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
            HStack(spacing: 3.5) {
                ForEach(0..<6, id: \.self) { _ in
                    Capsule().fill(Color.primary.opacity(0.55)).frame(width: 2, height: 7)
                }
            }
            .keyframeAnimator(initialValue: 0.0, trigger: gustID) { slats, tilt in
                slats
                    .rotation3DEffect(.degrees(tilt), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    .scaleEffect(x: 1, y: 1 + tilt / 120)
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    CubicKeyframe(openAngle, duration: 0.12)
                    SpringKeyframe(0.0, duration: 0.7, spring: Spring(response: 0.45, dampingRatio: 0.55))
                }
            }
        }
        .frame(width: 46, height: 13)
        .accessibilityHidden(true)
    }
}
