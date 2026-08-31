//
//  PowerMonitor.swift
//  Malinois
//
//  Trips instantly when the device's power connection CHANGES in either direction —
//  unplugged (the classic "grab and run") or plugged in (a device left on battery being
//  connected to a laptop or forensic tool to pull data off it). Uses UIDevice battery-state
//  notifications. Which direction is live depends only on the arm-time state, so a single
//  bidirectional tripwire is never inert the way two separate toggles would be.
//

import Foundation
import UIKit

@MainActor
final class PowerMonitor: SensorMonitor {

    let type: SensorType = .power
    var isEnabled: Bool = true
    var sensitivity: Sensitivity = .medium   // not used; unplug is binary
    var onTrip: ((SensorType) -> Void)?

    private var observer: NSObjectProtocol?
    private var hasTripped = false
    /// The last *known* powered-ness (nil = none observed yet). `.unknown` samples — the
    /// initial resolve when monitoring is enabled, and transient resolves mid-session — are
    /// ignored: they neither trip nor overwrite this. Tracking the last KNOWN value (rather
    /// than the immediately prior sample) is what fails closed across an intermediate
    /// `.unknown`, e.g. `.full → .unknown → .unplugged` still trips (F-20).
    private var lastKnownPowered: Bool?

    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        hasTripped = false
        lastKnownPowered = Self.poweredness(UIDevice.current.batteryState)   // baseline (nil if unknown now)
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.evaluate() }
            }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        hasTripped = false
        lastKnownPowered = nil
        // Release battery monitoring when disarmed — leaving it on is a small,
        // needless power draw. Re-enabled on the next start()/liveReading().
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    func rearm() { hasTripped = false }

    private func evaluate() {
        let state = UIDevice.current.batteryState
        defer { if let p = Self.poweredness(state) { lastKnownPowered = p } }   // only KNOWN states update the baseline
        guard !hasTripped else { return }
        if Self.powerChangeTrips(state: state, lastKnownPowered: lastKnownPowered) {
            hasTripped = true
            onTrip?(.power)
        }
    }

    /// Powered-ness of a battery state: true = on external power, false = on battery,
    /// nil = `.unknown` (indeterminate — never trips, never updates the baseline).
    nonisolated static func poweredness(_ state: UIDevice.BatteryState) -> Bool? {
        switch state {
        case .charging, .full: return true
        case .unplugged:       return false
        case .unknown:         return nil
        @unknown default:      return nil
        }
    }

    /// Pure (unit-tested): trip on a power-connection change in EITHER direction — the
    /// powered-ness of a known state differing from the last known powered-ness. `.unknown`
    /// never trips; establishing the first baseline (`lastKnownPowered == nil`) isn't a
    /// change. Because the caller only advances the baseline on known states, an
    /// intermediate `.unknown` can't mask a real change (F-20).
    nonisolated static func powerChangeTrips(state: UIDevice.BatteryState,
                                             lastKnownPowered: Bool?) -> Bool {
        guard let nowPowered = poweredness(state) else { return false }   // unknown → ignore
        guard let was = lastKnownPowered else { return false }            // first baseline → not a change
        return nowPowered != was
    }

    func liveReading() -> SensorReading? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let plugged = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        return SensorReading(
            value: plugged ? "Plugged in" : "On battery",
            detail: "trips when plugged in or unplugged",
            level: plugged ? 1 : 0,
            // Never "hot" from state alone: the real tripwire is edge-triggered (a power-
            // connection CHANGE, either direction — see `powerChangeTrips`), so sitting on
            // battery is not a trip condition. The actual transition still flashes the row
            // through the live monitor → `dryRunTrips`. (BACKLOG 13)
            hot: false)
    }
}
