import SwiftUI
import Core

struct LockCard: View {
    let device: Device
    let store: HomeStore

    var body: some View {
        let lock = device.doorLock ?? DoorLock(attributes: [:])
        // The graphic shows only what the lock has confirmed, never the request.
        let confirmed = store.confirmedValue(LockAttribute.locked, of: device.id).flatMap { Bool($0.lowercased()) }
        let isPending = store.isPending(device.id, attribute: LockAttribute.locked)
        let target = lock.isLocked

        HStack(spacing: 14) {
            LockGraphic(isLocked: confirmed, target: target, isPending: isPending, failures: store.failures[device.id, default: 0])
                .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Text(stateText(confirmed: confirmed, target: target, isPending: isPending))
                        .foregroundStyle(stateTint(confirmed))
                        .contentTransition(.opacity)
                        .animation(Motion.tint, value: isPending)
                    if !isPending, let reported = lock.lastEventDate {
                        // The server clock can be a little ahead of the Mac. Never show a time in the future.
                        let date = min(reported, .now)
                        Text("· \(date, format: .relative(presentation: .named, unitsStyle: .narrow))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                if let method = lock.lastEvent?.method {
                    Text(method)
                        .font(.system(size: 11))
                        .foregroundStyle(lock.lastEvent?.isProblem == true ? Palette.failure : .secondary)
                        .lineLimit(1)
                }
                if let battery = device.batteryLevel, battery <= 20 {
                    Label("Battery \(battery)%", systemImage: "battery.25percent")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.unlocked)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            actionButton(confirmed: confirmed, isPending: isPending)
        }
        .card()
    }

    @ViewBuilder
    private func actionButton(confirmed: Bool?, isPending: Bool) -> some View {
        if confirmed == true {
            // Unlocking is the dangerous action, so it is the quieter button and asks for Touch ID.
            Button {
                Task { await store.setLocked(false, device: device.id) }
            } label: {
                Label("Unlock", systemImage: "touchid")
            }
            .buttonStyle(MonoButtonStyle(isFilled: false))
            .disabled(isPending || !device.isOnline)
        } else {
            Button {
                Task { await store.setLocked(true, device: device.id) }
            } label: {
                Label("Lock", systemImage: "lock.fill")
            }
            .buttonStyle(MonoButtonStyle(isFilled: true))
            .disabled(isPending || !device.isOnline)
        }
    }

    private func stateText(confirmed: Bool?, target: Bool?, isPending: Bool) -> String {
        if !device.isOnline { return "Offline" }
        if isPending { return target == true ? "Locking…" : "Unlocking…" }
        switch confirmed {
        case true?: return "Locked"
        case false?: return "Unlocked"
        case nil: return "Unknown"
        }
    }

    private func stateTint(_ confirmed: Bool?) -> Color {
        guard device.isOnline else { return Palette.failure }
        switch confirmed {
        case true?: return Palette.locked
        case false?: return Palette.unlocked
        case nil: return .secondary
        }
    }
}

/// A deadbolt thumb-turn, centred in a ring.
///
/// A change plays in three beats:
/// 1. Lean: while the command waits, the knob leans 12° toward the new position
///    and the ring turns as a dashed line.
/// 2. Turn: when the lock confirms, the knob sweeps round with a strong
///    ease-in-out. A fan of the new colour trails behind its ends, and the ring's
///    new colour sweeps round the circle in the same direction.
/// 3. Click: the knob overshoots and springs back into the detent. The plate
///    gives a little, a ripple goes out, the detent marks light up, and the
///    trackpad bumps.
///
/// Locking turns clockwise to horizontal; unlocking turns back to vertical.
/// A failure shakes the knob back and flashes the ring red.
struct LockGraphic: View {
    /// What the lock has confirmed.
    let isLocked: Bool?
    /// What was requested, while a command waits.
    let target: Bool?
    let isPending: Bool
    let failures: Int

    @Environment(\.reducesMotion) private var reduceMotion

    /// The knob angle on screen. Vertical (0°) is unlocked, horizontal (90°) is locked.
    @State private var angle = 0.0
    /// The state the graphic has finished turning to. It changes at the click.
    @State private var settled: Bool?
    @State private var trailStart = 0.0
    @State private var trailEnd = 0.0
    @State private var trailOpacity = 0.0
    @State private var sweep = 0.0
    @State private var isTurning = false
    @State private var clicks = 0

    private struct Inputs: Equatable {
        let isLocked: Bool?
        let target: Bool?
        let isPending: Bool
    }

    var body: some View {
        let ringTint = Self.tint(settled)
        let newTint = Self.tint(isLocked)
        ZStack {
            Circle().fill(ringTint.opacity(0.13))
            if isPending {
                PendingRing(tint: ringTint, spins: !reduceMotion)
            } else {
                Circle().strokeBorder(ringTint, lineWidth: 2)
            }
            // The new colour sweeping round the ring, in the direction of the turn.
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(newTint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(1)
                .rotationEffect(.degrees(-90))
                .scaleEffect(x: isLocked == false ? -1 : 1)
                .opacity(isTurning ? 1 : 0)
            // The ripple at the click.
            Circle()
                .strokeBorder(ringTint, lineWidth: 2)
                .keyframeAnimator(initialValue: Ripple(), trigger: clicks) { ring, ripple in
                    ring.scaleEffect(ripple.scale).opacity(ripple.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(1, duration: 0.02)
                        CubicKeyframe(1.55, duration: 0.6)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(0.7, duration: 0.02)
                        CubicKeyframe(0, duration: 0.6)
                    }
                }
            // A red flash on failure.
            Circle()
                .strokeBorder(Palette.failure, lineWidth: 2.5)
                .keyframeAnimator(initialValue: 0.0, trigger: failures) { ring, opacity in
                    ring.opacity(opacity)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(1, duration: 0.08)
                        LinearKeyframe(1, duration: 0.4)
                        CubicKeyframe(0, duration: 0.35)
                    }
                }
            ThumbTurn(angle: angle, lit: settled, tint: ringTint, trail: (trailStart, trailEnd),
                      trailTint: newTint, trailOpacity: trailOpacity, clicks: clicks)
        }
        .modifier(Shake(travel: reduceMotion ? 0 : 4, progress: CGFloat(failures)))
        .animation(.linear(duration: 0.45), value: failures)
        .onAppear {
            settled = isLocked
            angle = Self.restAngle(isLocked)
        }
        .onChange(of: Inputs(isLocked: isLocked, target: target, isPending: isPending)) { old, new in
            if old.isLocked != new.isLocked {
                turn(from: old.isLocked, to: new.isLocked)
            } else if !isTurning {
                withAnimation(reduceMotion ? nil : Motion.snappy) { angle = leanAngle(new) }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Turning

    private func turn(from old: Bool?, to new: Bool?) {
        let rest = Self.restAngle(new)
        // No turn to show when the state was unknown, or when motion is reduced.
        guard !reduceMotion, let old, let new, old != new else {
            withAnimation(Motion.tint) {
                angle = rest
                settled = new
            }
            return
        }
        let overshoot = new ? 9.0 : -9.0
        isTurning = true
        trailStart = angle
        trailEnd = angle
        trailOpacity = 1
        sweep = 0
        // The turn: fast through the middle, decisive at both ends.
        withAnimation(.timingCurve(0.77, 0, 0.175, 1, duration: 0.42)) {
            angle = rest + overshoot
            trailEnd = rest + overshoot
            sweep = 1
        } completion: {
            // The click: spring back into the detent. The sweep has already painted
            // the ring in the new colour, so the ring changes under it at once. A fade
            // from orange to green would pass through olive.
            settled = new
            withAnimation(.spring(response: 0.26, dampingFraction: 0.5)) { angle = rest }
            withAnimation(.easeOut(duration: 0.35)) {
                trailOpacity = 0
            } completion: {
                isTurning = false
                sweep = 0
            }
            clicks += 1
            Haptics.bump()
        }
    }

    private func leanAngle(_ inputs: Inputs) -> Double {
        let rest = Self.restAngle(inputs.isLocked)
        guard inputs.isPending, let target = inputs.target, target != inputs.isLocked else { return rest }
        return rest + (target ? 12 : -12)
    }

    private static func restAngle(_ locked: Bool?) -> Double {
        switch locked {
        case true?: 90
        case false?: 0
        case nil: 45
        }
    }

    private static func tint(_ locked: Bool?) -> Color {
        switch locked {
        case true?: Palette.locked
        case false?: Palette.unlocked
        case nil: .secondary
        }
    }

    private struct Ripple {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }
}

/// The plate and the knob. Every part shares one centre, so the graphic stays
/// centred in its ring at every angle.
private struct ThumbTurn: View {
    let angle: Double
    /// The state whose detent marks are lit.
    let lit: Bool?
    let tint: Color
    let trail: (start: Double, end: Double)
    let trailTint: Color
    let trailOpacity: Double
    let clicks: Int

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // The plate.
            Circle()
                .fill(Color.primary.opacity(0.08))
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
                .frame(width: 40, height: 40)
            // The motion trail: the area that both ends of the knob have swept.
            TurnTrail(start: trail.start, end: trail.end)
                .fill(RadialGradient(colors: [trailTint.opacity(0), trailTint.opacity(0.5)],
                                     center: .center, startRadius: 3, endRadius: 15))
                .frame(width: 30, height: 30)
                .opacity(trailOpacity)
            // Four detent marks. The pair that the knob rests on lights up.
            ForEach(0..<4, id: \.self) { index in
                let isHorizontal = index % 2 == 1
                let isLit = lit.map { $0 == isHorizontal } ?? false
                Circle()
                    .fill(isLit ? tint : Color.primary.opacity(0.22))
                    .frame(width: 3, height: 3)
                    .offset(y: -17.5)
                    .rotationEffect(.degrees(Double(index) * 90))
            }
            // The knob, with a groove for grip, over a soft shadow.
            ZStack {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(Color.primary)
                    .frame(width: 10, height: 27)
                Capsule()
                    .fill(Palette.paper(scheme).opacity(0.55))
                    .frame(width: 1.5, height: 13)
            }
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .rotationEffect(.degrees(angle))
            // The screw in the middle.
            Circle()
                .fill(Palette.paper(scheme))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.4), lineWidth: 0.5))
                .frame(width: 4, height: 4)
        }
        .frame(width: 40, height: 40)
        // The plate gives a little at the click.
        .keyframeAnimator(initialValue: 1.0, trigger: clicks) { plate, scale in
            plate.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                CubicKeyframe(0.93, duration: 0.06)
                SpringKeyframe(1.0, duration: 0.4, spring: Spring(response: 0.3, dampingRatio: 0.55))
            }
        }
    }
}

/// Two opposite sectors: the area swept by both ends of the knob between two angles.
private struct TurnTrail: Shape {
    var start: Double
    var end: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set {
            start = newValue.first
            end = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        guard abs(end - start) > 0.5 else { return path }
        for half in [0.0, 180.0] {
            // The knob's 0° points up, which is -90° for a path.
            path.move(to: center)
            path.addArc(center: center, radius: radius,
                        startAngle: .degrees(start + half - 90), endAngle: .degrees(end + half - 90),
                        clockwise: end < start)
            path.closeSubpath()
        }
        return path
    }
}

private struct PendingRing: View {
    let tint: Color
    let spins: Bool
    @State private var angle = 0.0

    var body: some View {
        Circle()
            .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            .rotationEffect(.degrees(angle))
            .onAppear {
                guard spins else { return }
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { angle = 360 }
            }
    }
}

/// Moves a view left and right three times as `progress` goes up by one.
private struct Shake: GeometryEffect {
    var travel: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(progress * .pi * 6), y: 0))
    }
}
