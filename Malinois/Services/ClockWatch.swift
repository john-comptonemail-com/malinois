//
//  ClockWatch.swift
//  Malinois
//
//  Item 113 (from item 108, F4): a changed clock moves event times, the log's order, the armed timer
//  and the late-disarm rule, and nothing noticed it. While a watch is live, this compares the device
//  clock with a clock no setting can move and reports each jump of a minute or more, which the engine
//  logs as a quiet status entry.
//

import Foundation
import UIKit

/// Times a watch against `ContinuousClock`, which no setting moves and which keeps running while
/// the device sleeps, and reports each jump of the wall clock of at least `threshold`.
@MainActor
final class ClockWatch {
    /// The smallest jump worth a record (the owner's ruling). Automatic network time corrections
    /// are far smaller.
    nonisolated static let threshold: TimeInterval = 60

    private let wallNow: () -> Date
    private let steadyNow: () -> ContinuousClock.Instant
    private var reference: (wall: Date, steady: ContinuousClock.Instant)?
    private var observers: [NSObjectProtocol] = []
    private var onJump: ((Int) -> Void)?

    /// `wallNow` and `steadyNow` are for tests.
    init(wallNow: @escaping () -> Date = Date.init,
         steadyNow: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.wallNow = wallNow
        self.steadyNow = steadyNow
    }

    /// Whether a watch is being timed.
    var isRunning: Bool { reference != nil }

    /// Starts timing at go-live. `onJump` receives each jump in whole seconds, positive when the
    /// clock moved forward. Checked at each of iOS's clock-change notices, and whenever the app
    /// becomes active again, since setting the clock by hand means leaving Malinois, and iOS need
    /// not deliver the notice to an app in the background.
    func start(onJump: @escaping (Int) -> Void) {
        self.onJump = onJump
        reference = (wallNow(), steadyNow())
        guard observers.isEmpty else { return }
        for name in [Notification.Name.NSSystemClockDidChange, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.check() }
            })
        }
    }

    /// Stops at the disarm; the next watch starts afresh.
    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        reference = nil
        onJump = nil
    }

    /// Compares the clock's progress with the steady clock's since the last check, reports a jump
    /// of at least `threshold`, and measures afresh from now either way, so corrections under a
    /// minute never add up to a record.
    func check() {
        guard let reference else { return }
        let wall = wallNow(), steady = steadyNow()
        self.reference = (wall, steady)
        let elapsed = (steady - reference.steady).components
        let steadyElapsed = TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18
        if let jump = Self.jump(wallElapsed: wall.timeIntervalSince(reference.wall), steadyElapsed: steadyElapsed) {
            onJump?(jump)
        }
    }

    /// Pure (unit-tested): the jump in whole seconds, or nil under `threshold`.
    nonisolated static func jump(wallElapsed: TimeInterval, steadyElapsed: TimeInterval) -> Int? {
        let drift = wallElapsed - steadyElapsed
        guard abs(drift) >= threshold else { return nil }
        return Int(drift.rounded())
    }
}
