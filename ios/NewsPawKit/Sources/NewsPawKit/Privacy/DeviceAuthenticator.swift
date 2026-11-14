import Foundation
import LocalAuthentication

/// What a device authentication answered (RD18 decision 2).
public enum AuthenticationAnswer: Sendable, Hashable {
    /// The owner was authenticated, for this request only.
    case passed
    /// The owner dismissed the prompt.
    case cancelled
    /// The system took the prompt away, or the app left the foreground.
    case interrupted
    /// The owner was not authenticated.
    case failed
    /// The device has no passcode, so it cannot authenticate anyone.
    case unavailable
}

/// Device authentication (spec N09): Face ID, Touch ID or the device
/// passcode. The replaceable interface between the gate and
/// LocalAuthentication; tests use a stub.
public protocol DeviceAuthenticator: Sendable {
    /// Asks the owner to authenticate. `reason` is the sentence the system
    /// shows in its prompt, already localised by the app.
    func authenticate(reason: String) async -> AuthenticationAnswer
}

/// The system's authentication: the policy "device owner authentication"
/// (biometrics, falling back to the device passcode) on a new context for
/// every request, so that one success is never reused for a later one.
public struct SystemDeviceAuthenticator: DeviceAuthenticator {
    public init() {}

    public func authenticate(reason: String) async -> AuthenticationAnswer {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return Self.answer(forRefusal: error)
        }
        do {
            let passed = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return passed ? .passed : .failed
        } catch {
            return Self.answer(forRefusal: error as NSError)
        }
    }

    /// The answer for an error of LocalAuthentication: "passcode not set"
    /// is unavailable, the owner's cancel is cancelled, the system's and
    /// the app's cancel are interrupted, and everything else is failed.
    static func answer(forRefusal error: NSError?) -> AuthenticationAnswer {
        guard let error, error.domain == LAError.errorDomain else { return .failed }
        switch LAError.Code(rawValue: error.code) {
        case .passcodeNotSet: return .unavailable
        case .userCancel: return .cancelled
        case .systemCancel, .appCancel: return .interrupted
        default: return .failed
        }
    }
}
