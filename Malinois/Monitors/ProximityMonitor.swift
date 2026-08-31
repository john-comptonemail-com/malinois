//
//  ProximityMonitor.swift
//  Malinois
//
//  Trips when an object (a hand reaching for the phone) *comes* near the front proximity
//  sensor — the transition into near, not the standing state of being near (BACKLOG 29).
//
//  The distinction is the whole sensor. Trip-on-covered meant that a phone placed face down —
//  an ordinary covert placement, screen hidden — fired the instant the watch went live, every
//  time, on nothing. It was also useless there: a pickup goes near→far, which this sensor does
//  not trip on, so the one gesture it exists to catch was invisible from that position. Noisy
//  and blind at once, and the spurious trip then suppressed the vision tripwire for ~5.5 s,
//  taking down the tripwire that *would* have worked.
//
//  Note: enabling proximity monitoring also blanks the display when covered, which dovetails
//  with Malinois's covert black-screen mode.
//

import Foundation
import UIKit

@MainActor
final class ProximityMonitor: SensorMonitor {

    let type: SensorType = .proximity
    var isEnabled: Bool = true
    var sensitivity: Sensitivity = .medium   // sensor is binary; no threshold
    var onTrip: ((SensorType) -> Void)?

    private var observer: NSObjectProtocol?
    private var hasTripped = false

    /// The last known sensor state. `nil` means no resting state has been established yet, and
    /// a transition can't be judged without one — so nothing trips until it is seeded.
    private var lastNear: Bool?

    /// How long to wait before reading the resting state. `proximityState` is only meaningful
    /// once monitoring is enabled and is not reliably populated in the same turn, so reading it
    /// immediately can record "far" for a phone that is in fact face down — which would then
    /// trip on the first notification, reinstating the bug this fixes.
    static let restingStateSettle: TimeInterval = 0.5

    func start() {
        UIDevice.current.isProximityMonitoringEnabled = true
        hasTripped = false
        lastNear = nil
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.proximityStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.evaluate() }
            }
        // Seed the resting state a beat later — the equivalent of the baseline the other
        // sensors calibrate. Without it a phone sitting face UP would absorb the first cover as
        // its baseline and miss the very intrusion it was watching for.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.restingStateSettle * 1_000_000_000))
            guard let self, self.observer != nil, self.lastNear == nil else { return }
            self.lastNear = UIDevice.current.proximityState
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        UIDevice.current.isProximityMonitoringEnabled = false
        hasTripped = false
        lastNear = nil
    }

    /// Keeps the resting state: re-arming means "watch again", not "forget where you were".
    func rearm() { hasTripped = false }

    private func evaluate() {
        let near = UIDevice.current.proximityState
        let previous = lastNear
        lastNear = near
        guard !hasTripped, Self.shouldTrip(previous: previous, current: near) else { return }
        hasTripped = true
        onTrip?(.proximity)
    }

    /// Pure (unit-tested). A trip is the **transition** into near.
    ///
    /// `previous == nil` — no resting state yet — never trips: with nothing to compare against,
    /// the only honest answer is that nothing has changed.
    nonisolated static func shouldTrip(previous: Bool?, current: Bool) -> Bool {
        guard let previous else { return false }
        return current && !previous
    }

    func liveReading() -> SensorReading? {
        let near = UIDevice.current.proximityState
        return SensorReading(
            value: near ? "Object near" : "Clear",
            // Not "trips when covered" any more: a sensor that is *already* covered — a phone
            // face down — is at rest, and rest is not a trip.
            detail: near ? "at rest here; trips when something new comes near"
                         : "trips when something comes near",
            level: near ? 1 : 0,
            hot: near)
    }
}
