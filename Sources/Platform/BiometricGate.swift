import Foundation
import LocalAuthentication
import Core

/// Confirms a dangerous action with Touch ID, or with the Mac password when
/// Touch ID is not available.
@MainActor
public struct BiometricGate: ConfirmationGate {
    public init() {}

    public func confirm(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
