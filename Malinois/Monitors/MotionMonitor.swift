//
//  MotionMonitor.swift
//  Malinois
//
//  The primary tripwire. Uses CoreMotion device-motion to learn the resting
//  gravity vector and a noise floor during calibration, then trips on either:
//    • the gravity vector tilting beyond a threshold angle (device lifted/tilted)
//    • a user-acceleration spike above the learned noise floor (device bumped)
//
//  Tuned so a light table bump trips it, but a passing truck / HVAC vibration
//  on a resting table does not.
//

import Foundation
import CoreMotion

@MainActor
final class MotionMonitor: SensorMonitor {

    let type: SensorType = .motion
    var isEnabled: Bool = true
    var sensitivity: Sensitivity = .medium
    var onTrip: ((SensorType) -> Void)?

    var requiresCalibration: Bool { true }

    private let manager = CMMotionManager()
    private let queue = OperationQueue()

    // Calibration results.
    private var restingGravity: (x: Double, y: Double, z: Double) = (0, 0, -1)
    /// The pose learned at calibration. Unlike `restingGravity` this is NEVER moved by
    /// a re-baseline, so cumulative drift from it can be checked (anti-ratcheting).
    private var sessionRestingGravity: (x: Double, y: Double, z: Double) = (0, 0, -1)
    private var noiseFloor: Double = 0.02      // g; std of user-accel at rest
    private var lastGravity: (x: Double, y: Double, z: Double)?   // most recent sample

    // Calibration accumulation.
    private var calibrating = false
    private var gravitySamples: [(Double, Double, Double)] = []
    private var accelSamples: [Double] = []

    // Event trace ring buffer (last ~3s at 20 Hz).
    private var traceBuffer: [Double] = []
    private let traceCapacity = 60

    private var hasTripped = false

    // MARK: - Delivery watchdog (BACKLOG 5)

    /// Motion is the only continuous-stream tripwire (20 Hz). If, while watching, no sample
    /// arrives for `stallThreshold`, the stream has stalled — an OS throttle under pressure, an
    /// interruption nothing reports — and the PRIMARY tripwire is silently deaf with no sign of
    /// it. Mirrors AudioMonitor's self-heal: restart the updates, bounded by a backoff so a
    /// genuinely unavailable sensor can't thrash.
    private var lastSampleAt: Date?
    private var watchStartedAt: Date?
    private var watchdog: Timer?
    private var lastRestartAttempt: Date?
    nonisolated static let stallThreshold: TimeInterval = 3
    private let watchdogInterval: TimeInterval = 1.5
    private let restartBackoff: TimeInterval = 2
    /// Stalls detected this watch; the engine logs each. Kept for future UI.
    private(set) var stallCount = 0
    /// Called on the main actor after a stall is detected and the restart issued.
    var onStall: ((Int) -> Void)?

    /// Pure (unit-tested): has the stream gone quiet past the threshold? Measured from the last
    /// sample, or from when the watch started if nothing has arrived yet — a stream that never
    /// delivers its first sample is just as deaf as one that stopped.
    nonisolated static func isStalled(lastSample: Date?, startedAt: Date, now: Date,
                                      threshold: TimeInterval = stallThreshold) -> Bool {
        now.timeIntervalSince(lastSample ?? startedAt) > threshold
    }

    private func checkForStall() {
        guard let startedAt = watchStartedAt,
              Self.isStalled(lastSample: lastSampleAt, startedAt: startedAt, now: Date()),
              Date().timeIntervalSince(lastRestartAttempt ?? .distantPast) > restartBackoff else { return }
        lastRestartAttempt = Date()
        stallCount += 1
        manager.stopDeviceMotionUpdates()
        startUpdates()
        // Reset the stall clock so a recovering stream isn't re-reported every tick.
        watchStartedAt = Date()
        lastSampleAt = nil
        onStall?(stallCount)
    }

    /// The update stream itself, separated out so the watchdog can restart it in place.
    private func startUpdates() {
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let g = motion.gravity
            let a = motion.userAcceleration
            let mag = sqrt(a.x*a.x + a.y*a.y + a.z*a.z)
            Task { @MainActor in
                self.lastSampleAt = Date()
                self.evaluate(gravity: g, accelMagnitude: mag)
            }
        }
    }

    init() {
        manager.deviceMotionUpdateInterval = 1.0 / 20.0   // 20 Hz
        queue.maxConcurrentOperationCount = 1
    }

    // MARK: - Thresholds (internal so they can be unit-tested against the README)

    /// Max gravity-tilt (degrees) tolerated before tripping.
    var tiltThresholdDegrees: Double {
        switch sensitivity {
        case .high:   return 1.5
        case .medium: return 3.0
        case .low:    return 6.0
        }
    }

    /// Spike multiplier over the noise floor.
    var spikeMultiplier: Double {
        switch sensitivity {
        case .high:   return 3.0
        case .medium: return 5.0
        case .low:    return 9.0
        }
    }

    /// Absolute floor so a dead-quiet calibration can't set an impossibly low bar.
    var minimumSpike: Double {
        switch sensitivity {
        case .high:   return 0.03
        case .medium: return 0.06
        case .low:    return 0.12
        }
    }

    /// Ceiling on the learned noise floor (F-06). Without it, calibrating on a
    /// vibrating surface (deliberately or not) sets a bar the sensor can never reach —
    /// a poisoned baseline that silently disables the spike path for the session.
    nonisolated static let maxNoiseFloor: Double = 0.05

    /// Cumulative tilt from the pose at *calibration* that always trips, no matter how
    /// many small re-baselines happened since (F-15). This is what stops "ratcheting":
    /// tilting a few degrees at a time, each under `tiltThresholdDegrees`, to rotate the
    /// device to any orientation without ever firing.
    nonisolated static let sessionTiltLimitDegrees: Double = 15

    // MARK: - Calibration

    func beginCalibration() {
        guard manager.isDeviceMotionAvailable else { return }
        calibrating = true
        hasTripped = false
        gravitySamples.removeAll()
        accelSamples.removeAll()
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let g = motion.gravity
            let a = motion.userAcceleration
            let mag = sqrt(a.x*a.x + a.y*a.y + a.z*a.z)
            Task { @MainActor in
                guard self.calibrating else { return }
                self.gravitySamples.append((g.x, g.y, g.z))
                self.accelSamples.append(mag)
            }
        }
    }

    func endCalibration() {
        calibrating = false
        manager.stopDeviceMotionUpdates()

        if !gravitySamples.isEmpty {
            let n = Double(gravitySamples.count)
            let sum = gravitySamples.reduce((0.0, 0.0, 0.0)) {
                ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2)
            }
            restingGravity = (sum.0 / n, sum.1 / n, sum.2 / n)
            sessionRestingGravity = restingGravity   // the immovable anchor for this watch
        }
        if accelSamples.count > 1 {
            let mean = accelSamples.reduce(0, +) / Double(accelSamples.count)
            let variance = accelSamples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                / Double(accelSamples.count - 1)
            // Clamped at BOTH ends: a dead-quiet calibration can't set an impossibly low
            // bar, and a vibrating one can't set an unreachable bar (F-06).
            noiseFloor = Self.clampedNoiseFloor(sqrt(variance))
        }
    }

    /// Pure (unit-tested): the learned noise floor, bounded at both ends.
    nonisolated static func clampedNoiseFloor(_ measured: Double) -> Double {
        min(max(measured, 0.005), maxNoiseFloor)
    }

    /// Pure (unit-tested): angle in degrees between two gravity vectors.
    nonisolated static func tiltDegrees(_ a: (x: Double, y: Double, z: Double),
                                        _ b: (x: Double, y: Double, z: Double)) -> Double {
        let dot = a.x*b.x + a.y*b.y + a.z*b.z
        let magA = sqrt(a.x*a.x + a.y*a.y + a.z*a.z)
        let magB = sqrt(b.x*b.x + b.y*b.y + b.z*b.z)
        guard magA > 0, magB > 0 else { return 0 }
        return acos(max(-1, min(1, dot / (magA * magB)))) * 180 / .pi
    }

    /// Pure (unit-tested): does the current pose trip on tilt? Either it deviates from the
    /// (re-baselineable) resting pose past the sensitivity threshold, or its cumulative
    /// tilt from the session anchor exceeds the fixed limit. A stationary device whose two
    /// anchors both sit at its current pose must return false — the R-01 regression was
    /// exactly this returning true forever because the session anchor never moved.
    nonisolated static func tiltTrips(current: (x: Double, y: Double, z: Double),
                                      resting: (x: Double, y: Double, z: Double),
                                      session: (x: Double, y: Double, z: Double),
                                      tiltThreshold: Double, sessionLimit: Double) -> Bool {
        tiltDegrees(current, resting) > tiltThreshold || tiltDegrees(current, session) > sessionLimit
    }

    // MARK: - Watching

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        hasTripped = false
        traceBuffer.removeAll()
        watchStartedAt = Date()
        lastSampleAt = nil
        stallCount = 0
        startUpdates()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForStall() }
        }
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        watchStartedAt = nil
        manager.stopDeviceMotionUpdates()
        hasTripped = false
    }

    /// Latch-only re-arm (refractory sweep / during an until-clear recording). Keeps the
    /// resting reference where it is — re-baselining here would let an attacker ratchet
    /// the device round in sub-threshold steps, each one aging out and re-anchoring.
    func rearm() {
        hasTripped = false
    }

    /// Post-trigger re-arm: adopt the current position as the new resting reference, so
    /// a device moved and left in a new spot doesn't trip forever on gravity deviation.
    /// The session anchor advances TOO — a trigger already fired means the tamper was
    /// captured and pushed, so there's nothing left to hide by re-anchoring, and leaving
    /// the anchor fixed here caused a stationary phone resting >15° from its calibration
    /// pose to re-trip on every sample forever (R-01). The anti-ratcheting defence lives
    /// in `rearm()` (the refractory sweep), which still moves NEITHER anchor.
    func rearmAndRebaseline() {
        if let lastGravity {
            restingGravity = lastGravity
            sessionRestingGravity = lastGravity
        }
        hasTripped = false
    }

    private func evaluate(gravity g: CMAcceleration, accelMagnitude mag: Double) {
        lastGravity = (g.x, g.y, g.z)   // remembered for re-baselining on rearm()

        // Maintain trace ring buffer regardless of trip state.
        traceBuffer.append(mag)
        if traceBuffer.count > traceCapacity { traceBuffer.removeFirst() }

        guard !hasTripped else { return }

        let current = (x: g.x, y: g.y, z: g.z)

        // Tilt: from the (re-baselineable) resting pose past the sensitivity threshold,
        // OR cumulative tilt from the session anchor past the fixed limit. The refractory
        // sweep moves neither anchor, so a slow ratchet still accumulates and fires here.
        if Self.tiltTrips(current: current, resting: restingGravity, session: sessionRestingGravity,
                          tiltThreshold: tiltThresholdDegrees, sessionLimit: Self.sessionTiltLimitDegrees) {
            trip(); return
        }

        // 2) Acceleration spike above the noise floor.
        let spikeThreshold = max(noiseFloor * spikeMultiplier, minimumSpike)
        if mag > spikeThreshold { trip() }
    }

    private func trip() {
        hasTripped = true
        onTrip?(.motion)
    }

    func recentTrace() -> [Double] { traceBuffer }

    /// The learned resting noise floor (g) — surfaced in the calibration summary.
    var calibratedNoiseFloor: Double { noiseFloor }

    func liveReading() -> SensorReading? {
        let mag = traceBuffer.last ?? 0
        let threshold = max(noiseFloor * spikeMultiplier, minimumSpike)
        return SensorReading(
            value: String(format: "%.3f g", mag),
            detail: String(format: "trips above %.3f g (or a %.1f° tilt)", threshold, tiltThresholdDegrees),
            level: min(mag / (threshold * 1.5), 1),
            hot: mag > threshold)
    }
}
