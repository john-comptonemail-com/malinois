//
//  VisionMonitor.swift
//  Malinois
//
//  The vision tripwire (BACKLOG 16, Pro): the camera watches its own field of view for
//  movement while the session is warm — which, by the readiness policy, means plugged in
//  (Auto) or Instant mode. That coupling is the point: the feature exists only in the mode
//  where the RECORDING indicator already shows and power is external, so it costs no
//  covertness and no battery that isn't already spent. On battery the camera is cold, no
//  frames arrive, and this monitor is simply quiet (the arming screen says so).
//
//  Frames arrive from CameraController's video tap (~2 fps, 32×24 luminance). Nothing is
//  stored during monitoring — the detector keeps two tiny baselines in memory; recording
//  only begins when a trip fires the normal capture path.
//

import Foundation

@MainActor
final class VisionMonitor: SensorMonitor {
    let type: SensorType = .vision
    var isEnabled: Bool = true
    var sensitivity: Sensitivity = .medium
    var onTrip: ((SensorType) -> Void)?
    var requiresCalibration: Bool { true }

    private var detector = VisionDetector()
    private var calibrating = false
    private var watching = false
    private var hasTripped = false
    private var suppressedUntil: Date?
    private var lastFrameAt: Date?
    private var settleFramesRemaining = 0
    private var lastChanged: Double = 0

    /// Whether the camera's frame tap is actually delivering, set by the engine after a
    /// warm-up. `nil` = the camera is cold (nothing was attached), `false` = a tap was asked
    /// for and did not come up — either the multi-cam session (camera position Both), or an
    /// inactive connection. The distinction matters: "no frames" with the camera cold is
    /// expected and explained on the arming screen, while "no frames" with the camera warm is
    /// a tripwire the owner enabled and is not getting.
    var tapActive: Bool?

    /// A gap this long between frames means the camera was cold and just came back (Auto
    /// flipped to charging); the scene may have changed meanwhile, so re-anchor quietly.
    static let frameGapForResettle: TimeInterval = 5
    /// Frames to absorb after a resume/suppression before judging again.
    static let settleFrames = 3

    var tripFraction: Double { VisionDetector.tripFraction(for: sensitivity) }

    /// Entry point for every frame from the camera tap (main actor).
    func ingest(_ frame: VisionFrame) {
        let now = Date()
        let gap = lastFrameAt.map { now.timeIntervalSince($0) }
        lastFrameAt = now

        if let until = suppressedUntil {
            guard now >= until else { return }
            suppressedUntil = nil
            detector.rebaseline(to: frame)
            settleFramesRemaining = Self.settleFrames
            return
        }
        if calibrating {
            detector.calibrate(frame)
            return
        }
        guard watching else { return }
        if let gap, gap > Self.frameGapForResettle {
            detector.rebaseline(to: frame)
            settleFramesRemaining = Self.settleFrames
            return
        }
        if settleFramesRemaining > 0 {
            settleFramesRemaining -= 1
            detector.rebaseline(to: frame)
            return
        }
        switch detector.evaluate(frame, tripFraction: tripFraction) {
        case .calibrating:
            break
        case .ok(let changed):
            lastChanged = changed
        case .trip(let changed, _):
            lastChanged = changed
            guard !hasTripped else { return }
            hasTripped = true
            onTrip?(.vision)
        }
    }

    // MARK: - SensorMonitor

    func beginCalibration() { calibrating = true; detector.beginCalibration() }
    func endCalibration()   { calibrating = false; detector.endCalibration() }

    func start() {
        watching = true
        hasTripped = false
        lastFrameAt = nil
        settleFramesRemaining = 0
    }

    func stop() {
        watching = false
        hasTripped = false
        suppressedUntil = nil
    }

    func rearm() { hasTripped = false }

    /// After a real trigger the scene may legitimately be different (someone is now standing
    /// there). Adopt it, exactly as motion adopts a new resting pose, so it doesn't trip
    /// forever — their *next* movement trips again.
    func rearmAndRebaseline() {
        hasTripped = false
        detector.rebaseline()
    }

    /// Ignore frames for a while — around a capture (the scene being recorded, the screen
    /// flash, a camera reconfigure) — then re-anchor on resume.
    func suppress(for interval: TimeInterval) {
        suppressedUntil = Date().addingTimeInterval(interval)
    }

    func recentTrace() -> [Double] { detector.trace }

    func liveReading() -> SensorReading? {
        guard lastFrameAt != nil else {
            if tapActive == false {
                // Never claim a cause that hasn't been established: with the camera warm and
                // the tap not delivering, "needs the camera warm" would be a wrong answer to
                // the owner's real question.
                return SensorReading(value: "Not running",
                                     detail: "the camera can't run this tripwire in its current setup — see the arming screen",
                                     level: 0, hot: false)
            }
            return SensorReading(value: "No frames",
                                 detail: "needs the camera warm — plugged in (Auto) or Instant mode",
                                 level: 0, hot: false)
        }
        return SensorReading(
            value: String(format: "%.0f%% of view changed", lastChanged * 100),
            detail: String(format: "trips above %.0f%%", tripFraction * 100),
            level: min(lastChanged / max(tripFraction * 2, 0.01), 1),
            hot: lastChanged > tripFraction)
    }
}
