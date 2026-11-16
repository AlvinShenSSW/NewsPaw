import Foundation

/// When the adult partition locks after the app is left (spec N09; RD18
/// decision 8). A device setting; the raw values are seconds as the
/// preferences store keeps them.
public enum LockTiming: Int, Sendable, CaseIterable {
    case immediately = 0
    case afterOneMinute = 60
    case afterFiveMinutes = 300
}

/// The lock rule of RD18 decision 8, as pure functions of what the scene
/// reported. The app follows the scene through four notifications — will
/// deactivate, did enter background, will enter foreground, did activate —
/// and asks here at did-enter-background and at did-activate.
public enum LockRule {
    /// How long an absence without did-enter-background may last under
    /// "immediately" before it locks (decision 8, last point): a glance at
    /// Control Centre does not lock, leaving the app does.
    public static let immediateFallback: TimeInterval = 5

    /// Whether the partition locks at did-enter-background.
    public static func locksOnEnteringBackground(_ timing: LockTiming) -> Bool {
        timing == .immediately
    }

    /// Whether the partition locks at did-activate.
    ///
    /// - Parameters:
    ///   - awayBegan: the first will-deactivate since the scene was last
    ///     active; `nil` when the scene was not away.
    ///   - now: the app's clock at did-activate.
    ///   - enteredBackground: whether did-enter-background arrived while
    ///     away.
    ///   - fallback: whether "immediately" also locks after an absence of
    ///     `immediateFallback` that never entered the background (measured
    ///     in assumption A7: some ways of leaving deliver no
    ///     did-enter-background).
    public static func locksOnActivating(
        _ timing: LockTiming, awayBegan: Date?, now: Date, enteredBackground: Bool, fallback: Bool
    ) -> Bool {
        guard let awayBegan else { return false }
        let away = now.timeIntervalSince(awayBegan)
        switch timing {
        case .immediately:
            if enteredBackground {
                return true
            }
            // A negative time (the clock was set back) locks, as below.
            return fallback && (away >= immediateFallback || away < 0)
        case .afterOneMinute, .afterFiveMinutes:
            return away >= TimeInterval(timing.rawValue) || away < 0
        }
    }
}

/// One absence of the scene, as decision 8 counts it: it begins at the
/// first will-deactivate after the scene was last active (a later one does
/// not move it) and ends at did-activate.
public struct Absence: Sendable, Equatable {
    /// When the scene stopped being active; `nil` while it is active.
    public private(set) var began: Date?
    /// Whether the scene entered the background during this absence.
    public private(set) var enteredBackground = false

    public init() {}

    public var isAway: Bool {
        began != nil
    }

    public mutating func willDeactivate(at now: Date) {
        if began == nil {
            began = now
        }
    }

    /// - Returns: whether the partition locks now.
    public mutating func didEnterBackground(at now: Date, timing: LockTiming) -> Bool {
        // A scene that enters the background without a will-deactivate
        // before it is away from this moment.
        willDeactivate(at: now)
        enteredBackground = true
        return LockRule.locksOnEnteringBackground(timing)
    }

    /// Ends the absence.
    ///
    /// - Returns: whether the partition locks now.
    public mutating func didActivate(at now: Date, timing: LockTiming, fallback: Bool) -> Bool {
        defer { self = Absence() }
        return LockRule.locksOnActivating(
            timing, awayBegan: began, now: now, enteredBackground: enteredBackground, fallback: fallback
        )
    }
}

/// Whether the cover is shown (RD18 decision 12): one rule, applied at
/// will-deactivate, at did-enter-background, at did-activate and at the
/// moment the adult workspace becomes shown.
public enum CoverRule {
    public static func isShown(adultIsShown: Bool, sceneIsActive: Bool) -> Bool {
        adultIsShown && !sceneIsActive
    }
}
