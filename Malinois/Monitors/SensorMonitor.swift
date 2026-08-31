//
//  SensorMonitor.swift
//  Malinois
//
//  Common surface for every tripwire. The MonitoringEngine owns a collection of
//  these, calibrates the ones that need it, starts them when Armed, and receives
//  trips through `onTrip`.
//

import Foundation

@MainActor
protocol SensorMonitor: AnyObject {
    /// Which sensor this is.
    var type: SensorType { get }

    /// Whether the engine should run this monitor.
    var isEnabled: Bool { get set }

    /// Coarse sensitivity; each monitor maps it to concrete thresholds.
    var sensitivity: Sensitivity { get set }

    /// Called on the main actor when this sensor trips. The engine assigns this with
    /// `[weak self]`; keep that convention — capturing the engine strongly here would
    /// create an engine ⇄ monitor retain cycle.
    var onTrip: ((SensorType) -> Void)? { get set }

    /// True if this monitor needs a calibration pass before Armed.
    var requiresCalibration: Bool { get }

    /// Begin sampling for calibration (no trips fire during calibration).
    func beginCalibration()

    /// Finish calibration; compute and store the baseline from samples gathered
    /// since beginCalibration().
    func endCalibration()

    /// Start watching (trips may now fire).
    func start()

    /// Stop watching and release hardware.
    func stop()

    /// Clear the one-shot trip latch ONLY, keeping the learned baseline. Used by the
    /// refractory sweep (and during an until-clear recording) where a trip aged out
    /// without firing — re-baselining there would let an attacker "ratchet" the device
    /// past the threshold in small sub-threshold steps.
    func rearm()

    /// Clear the latch AND adopt the current pose/level as the new baseline. Called
    /// only after a real trigger, so a device moved and left in a new spot doesn't
    /// trip forever. Defaults to `rearm()` for monitors with no baseline to move.
    func rearmAndRebaseline()

    /// A recent trace sample for the event window (implementation-specific unit).
    /// Motion returns user-accel magnitude (g); audio returns dBFS. Others return
    /// an empty array.
    func recentTrace() -> [Double]

    /// A live reading for the dry-run / test view — the current value plus the
    /// trip threshold. Nil for sensors with nothing continuous to show (e.g. touch).
    func liveReading() -> SensorReading?
}

extension SensorMonitor {
    var requiresCalibration: Bool { false }
    func beginCalibration() {}
    func endCalibration() {}
    /// Most monitors have no movable baseline — re-arming is the same either way.
    func rearmAndRebaseline() { rearm() }
    func recentTrace() -> [Double] { [] }
    func liveReading() -> SensorReading? { nil }
}

/// A snapshot of a sensor's current state for the live "Test sensors" view.
struct SensorReading {
    /// The current value, formatted (e.g. "0.12 g", "-48 dBFS", "On battery").
    let value: String
    /// A hint about where it trips (e.g. "trips > 0.06 g").
    let detail: String
    /// 0…1 for a progress bar.
    let level: Double
    /// True when the current value is at or past the trip point.
    let hot: Bool
}

/// Human-readable calibration result, surfaced after the 3-second calibration and
/// in the test view, so the user can see whether the spot is stable/quiet enough.
struct CalibrationSummary {
    let motionQuality: String?
    let motionDetail: String?
    let audioQuality: String?
    let audioDetail: String?

    var isEmpty: Bool { motionQuality == nil && audioQuality == nil }
}
