import SwiftUI
import AppKit

/// Shared motion values, so that every part of the panel moves the same way.
/// The panel opens many times a day, so motion stays short and has a purpose:
/// press feedback, state changes, and the device animations.
enum Motion {
    /// Press feedback. Fast and ease-out, so a press shows at once.
    static let press = Animation.easeOut(duration: 0.12)
    /// The default for state changes: a critically damped spring with no overshoot.
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 1)
    /// The lock knob turning. A small overshoot reads as a detent clicking into place.
    static let turn = Animation.spring(response: 0.42, dampingFraction: 0.66)
    /// Colour changes.
    static let tint = Animation.easeInOut(duration: 0.25)
}

/// The panel is black and white. Colour appears only where it means something:
/// heating and cooling, the state of the lock, the connection, and alerts.
enum Palette {
    static let heat = Color(red: 1.0, green: 0.5, blue: 0.18)
    static let cool = Color(red: 0.3, green: 0.72, blue: 1.0)
    static let auto = Color(red: 0.66, green: 0.55, blue: 1.0)
    static let fan = Color(red: 0.3, green: 0.85, blue: 0.8)
    static let light = Color(red: 1.0, green: 0.82, blue: 0.3)
    static let locked = Color(nsColor: .systemGreen)
    static let unlocked = Color(nsColor: .systemOrange)
    static let failure = Color(nsColor: .systemRed)

    /// The page colour: pure black in dark mode, pure white in light mode.
    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : .white
    }

    static let surface = Color.primary.opacity(0.06)
    static let hairline = Color.primary.opacity(0.1)
}

/// Scales a control down a little while it is pressed.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// A black-and-white pill button. The filled style is for the main action.
struct MonoButtonStyle: ButtonStyle {
    let isFilled: Bool
    /// A taller button that fills its row, for forms.
    var isWide = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: isWide ? 13 : 12, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 13)
            .padding(.vertical, isWide ? 10 : 7)
            .frame(maxWidth: isWide ? .infinity : nil)
            .foregroundStyle(isFilled ? Palette.paper(scheme) : Color.primary)
            .background {
                if isFilled {
                    Capsule().fill(Color.primary)
                } else {
                    Capsule().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// The surface of each card: a quiet fill with a hairline edge.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// Small uppercase label above a value.
struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// Whether to replace movement with gentler changes. It follows the system
/// Reduce Motion setting unless the person chose Full Animations in the panel menu.
private struct ReducesMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var reducesMotion: Bool {
        get { self[ReducesMotionKey.self] }
        set { self[ReducesMotionKey.self] = newValue }
    }
}

/// The key for the Full Animations choice in UserDefaults.
enum MotionPreference {
    static let key = "fullAnimations"
}

enum Haptics {
    /// A light detent, for each step of a drag.
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// A stronger bump, for a limit or a completed action.
    static func bump() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
