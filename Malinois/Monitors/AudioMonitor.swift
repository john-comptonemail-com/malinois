//
//  AudioMonitor.swift
//  Malinois
//
//  Trips on sound above a rolling baseline — footsteps, a chair scrape, someone
//  picking the phone up. Uses AVAudioRecorder metering into /dev/null (we never
//  keep the audio; only the level matters).
//
//  During calibration we sample the ambient room level to set the baseline, then
//  trip when the level exceeds baseline + a sensitivity-dependent margin. A slow
//  rolling update lets the baseline track gradual changes (HVAC) without letting
//  a sharp transient (a footstep) raise the bar before it trips.
//

import Foundation
import AVFoundation

@MainActor
final class AudioMonitor: SensorMonitor {

    let type: SensorType = .audio
    var isEnabled: Bool = true
    var sensitivity: Sensitivity = .medium
    var onTrip: ((SensorType) -> Void)?

    var requiresCalibration: Bool { true }

    private var recorder: AVAudioRecorder?
    /// False when the recorder couldn't be built or started (F7): a dead mic path reports
    /// the -160 dBFS floor, which the calibration summary would otherwise praise as
    /// "Very quiet" — a failure dressed as excellence. The UI reads this to say so.
    private(set) var healthy = true
    private var meterTimer: Timer?

    private var baselineDB: Double = -50      // dBFS
    private var rollingDB: Double = -50
    private var hasTripped = false

    /// After start(), snap the rolling baseline to the current ambient for a
    /// short window (no trips) — so resuming after the siren, when the room may
    /// have changed, doesn't fire a burst of false positives against a stale
    /// calibration baseline.
    private var warmupSamples = 0
    private let warmupSampleCount = 15        // ~1.5s at 10 Hz
    private var warmupBuffer: [Double] = []

    // Calibration accumulation.
    private var calibrating = false
    private var calibrationSamples: [Double] = []

    // Event trace ring buffer (~3s at 10 Hz).
    private var traceBuffer: [Double] = []
    private let traceCapacity = 30

    /// dB above baseline required to trip. Internal so it can be unit-tested.
    var marginDB: Double {
        switch sensitivity {
        case .high:   return 8
        case .medium: return 14
        case .low:    return 22
        }
    }

    /// The rolling baseline may adapt upward for legitimate ambient changes (HVAC),
    /// but never more than this above the *calibrated* quiet. This caps "baseline
    /// poisoning" — a slow noise ramp designed to walk the trip bar up and mask
    /// handling sounds — to at most this many dB.
    private let maxBaselineDrift: Double = 12

    // MARK: - Session / recorder

    private func makeRecorderIfNeeded() {
        guard recorder == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)

        let url = URL(fileURLWithPath: "/dev/null")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: 12_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue
        ]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        recorder?.isMeteringEnabled = true
        let started = recorder?.record() ?? false
        healthy = (recorder != nil) && started
    }

    private var lastRestartAttempt: Date?
    private let restartBackoff: TimeInterval = 2

    private func currentLevel() -> Double {
        // Self-heal (F-14): a clip capture's mic input, a phone call, or a route change
        // can interrupt our metering recorder. Nothing restarts it otherwise, so it would
        // report a frozen/floor value for the rest of the session — a tripwire that
        // reports numbers and can't fire. Verify liveness on every tick and rebuild if it
        // stalled — but at most once per `restartBackoff`, so a genuinely unavailable mic
        // (a call in progress, another app holding it) doesn't turn into a 10 Hz session-
        // thrash loop (R-03). The engine also pauses us around clip capture (pauseAudioForCapture).
        if recorder?.isRecording != true,
           Date().timeIntervalSince(lastRestartAttempt ?? .distantPast) > restartBackoff {
            lastRestartAttempt = Date()
            restartRecorder()
        }
        recorder?.updateMeters()
        return Double(recorder?.averagePower(forChannel: 0) ?? -160)
    }

    private func restartRecorder() {
        recorder?.stop()
        recorder = nil
        makeRecorderIfNeeded()   // rebuilds the session + recorder and calls record()
    }

    // MARK: - Calibration

    func beginCalibration() {
        makeRecorderIfNeeded()
        calibrating = true
        calibrationSamples.removeAll()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.calibrating else { return }
                self.calibrationSamples.append(self.currentLevel())
            }
        }
    }

    func endCalibration() {
        calibrating = false
        meterTimer?.invalidate(); meterTimer = nil
        if !calibrationSamples.isEmpty {
            // Median (resists a loud transient during the window) AND a ceiling (F-06):
            // calibrating in a loud room can't set an unreachable bar. The calibrated
            // quiet is the anchor everything else clamps to, so it must be bounded too.
            baselineDB = Self.clampedCalibratedBaseline(Self.median(calibrationSamples) ?? baselineDB)
        }
        rollingDB = baselineDB
    }

    /// Ceiling on the calibrated quiet (dBFS). Above this, we assume the room was noisy
    /// at calibration and cap it so the sensor can still fire (F-06).
    nonisolated static let maxCalibratedBaselineDB: Double = -35
    nonisolated static func clampedCalibratedBaseline(_ measured: Double) -> Double {
        min(measured, maxCalibratedBaselineDB)
    }

    // MARK: - Watching

    func start() {
        makeRecorderIfNeeded()
        hasTripped = false
        traceBuffer.removeAll()
        rollingDB = baselineDB
        warmupSamples = warmupSampleCount
        warmupBuffer.removeAll()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }

    func stop() {
        meterTimer?.invalidate(); meterTimer = nil
        recorder?.stop(); recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        hasTripped = false
        traceBuffer.removeAll()
        calibrationSamples.removeAll()
        warmupSamples = 0
        warmupBuffer.removeAll()
    }

    func rearm() {
        hasTripped = false
        rollingDB = baselineDB   // reset the rolling baseline so it re-adapts
    }

    private func evaluate() {
        let level = currentLevel()
        traceBuffer.append(level)
        if traceBuffer.count > traceCapacity { traceBuffer.removeFirst() }

        // Warm-up: collect ambient samples without tripping, then set the baseline
        // to their MEDIAN. Using the median (not the latest sample) means a loud
        // transient during the window — a chair scrape as the owner walks away —
        // can't inflate the bar and suppress real trips right after arming.
        if warmupSamples > 0 {
            warmupSamples -= 1
            warmupBuffer.append(level)
            if warmupSamples == 0 {
                // Clamp the warm-up baseline too, not just the steady-state one:
                // sustained noise across the ~1.5s window (which recurs on every siren
                // stand-down) must not set the trip bar past calibrated + drift, which is
                // the guarantee SECURITY.md makes. Without this the median is unbounded.
                rollingDB = Self.clampedRolling(Self.median(warmupBuffer) ?? baselineDB,
                                                baseline: baselineDB, maxDrift: maxBaselineDrift)
                warmupBuffer.removeAll()
            }
            return
        }

        guard !hasTripped else { return }

        if level > rollingDB + marginDB {
            hasTripped = true
            onTrip?(.audio)
            return
        }
        // Slow rolling baseline (tracks gradual ambient changes only), clamped so a
        // deliberate noise ramp can't walk the trip bar up past calibrated + drift.
        rollingDB = Self.clampedRolling(rollingDB * 0.98 + level * 0.02,
                                        baseline: baselineDB, maxDrift: maxBaselineDrift)
    }

    /// Pure: the next rolling baseline, capped at `baseline + maxDrift` (unit-tested).
    nonisolated static func clampedRolling(_ proposed: Double, baseline: Double, maxDrift: Double) -> Double {
        min(proposed, baseline + maxDrift)
    }

    func recentTrace() -> [Double] { traceBuffer }

    /// The learned ambient baseline (dBFS) — surfaced in the calibration summary.
    var calibratedBaselineDB: Double { baselineDB }

    func liveReading() -> SensorReading? {
        guard healthy else {
            return SensorReading(value: "Mic unavailable",
                                 detail: "check microphone permission", level: 0, hot: false)
        }
        let level = traceBuffer.last ?? rollingDB
        let threshold = rollingDB + marginDB
        return SensorReading(
            value: String(format: "%.0f dBFS", level),
            detail: String(format: "trips above %.0f dBFS", threshold),
            level: min(max((level + 70) / 70, 0), 1),   // map -70…0 dBFS to 0…1
            hot: level > threshold)
    }

    /// Median of a sample set (nil if empty). Used to pick a robust warm-up
    /// baseline that ignores a single loud outlier. `nonisolated` (it's pure) so
    /// tests can call it off the main actor.
    nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
