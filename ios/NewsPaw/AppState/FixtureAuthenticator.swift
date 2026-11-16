#if DEBUG
import Foundation
import NewsPawKit
import Synchronization
import UIKit

/// The stand-in authenticator of the UI tests (RD18 decision 15): it
/// answers from the launch option's list, in order, and "unavailable" once
/// the list is used up, so a test that configures nothing cannot turn the
/// adult partition on. It never calls LocalAuthentication. Debug builds
/// only, and only under a UI-test library directory.
final class FixtureAuthenticator: DeviceAuthenticator {
    struct Step: Sendable {
        enum Moment: Sendable {
            /// At once.
            case now
            /// Once the scene is inactive, as the system's prompt answers
            /// (measured, RD18 assumption A2).
            case whenInactive
            /// Once the scene has been inactive and is active again.
            case whenReactivated
        }

        var answer: AuthenticationAnswer
        var moment: Moment

        /// `passed`, `cancelled@inactive`, `passed@reactivated`, …; `nil`
        /// for anything else.
        init?(_ text: String) {
            let parts = text.split(separator: "@", maxSplits: 1).map(String.init)
            switch parts.first {
            case "passed": answer = .passed
            case "cancelled": answer = .cancelled
            case "interrupted": answer = .interrupted
            case "failed": answer = .failed
            case "unavailable": answer = .unavailable
            default: return nil
            }
            switch parts.count > 1 ? parts[1] : "" {
            case "": moment = .now
            case "inactive": moment = .whenInactive
            case "reactivated": moment = .whenReactivated
            default: return nil
            }
        }
    }

    private let steps: Mutex<[Step]>

    init(_ steps: [Step]) {
        self.steps = Mutex(steps)
    }

    func authenticate(reason: String) async -> AuthenticationAnswer {
        guard let step = steps.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { return .unavailable }
        switch step.moment {
        case .now:
            break
        case .whenInactive:
            await Self.next(UIScene.willDeactivateNotification)
        case .whenReactivated:
            await Self.next(UIScene.willDeactivateNotification)
            await Self.next(UIScene.didActivateNotification)
        }
        return step.answer
    }

    /// Returns when `name` is next posted.
    @MainActor
    private static func next(_ name: Notification.Name) async {
        let observation = Observation()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            observation.token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated {
                    guard let token = observation.token else { return }
                    NotificationCenter.default.removeObserver(token)
                    observation.token = nil
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    private final class Observation {
        var token: (any NSObjectProtocol)?
    }
}
#endif
