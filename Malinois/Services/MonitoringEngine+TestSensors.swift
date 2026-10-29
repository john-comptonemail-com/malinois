//
//  MonitoringEngine+TestSensors.swift
//  Malinois
//
//  Test Sensors (the dry run): moved unchanged from MonitoringEngine.swift (BACKLOG 158's first stage, 1.8.2's step
//  1), which sits at the lint size limit. Members the class needs elsewhere are internal; the stored state stays in
//  the class.
//

import Foundation
import OSLog
import Combine
import UIKit
import AVFoundation
import UserNotifications

extension MonitoringEngine {

    /// Starts a live sensor test: calibrate, run the enabled monitors, and publish
    /// their readings — but create no events and never engage the covert screen, so
    /// the user can tune sensitivity and confirm placement without polluting the log.
    func startDryRun() {
        guard state == .disarmed, !dryRunActive else { return }
        // Snapshot Pro for the dry run, exactly as beginArming does — otherwise `armedPro`
        // is still false from launch and `effectiveSensors` would silently disable the
        // (Pro) audio monitor for an in-trial user testing their sensors (P-03).
        armedPro = entitlements.proActive
        dryRunActive = true
        dryRunReadings = [:]
        dryRunTrips = [:]
        dryRunCounts = [:]
        lastCalibration = nil
        applyEnabledAndSensitivity()
        // The vision row needs frames: warm the camera for the test if vision is effective.
        syncVisionTap()
        if visionTapWanted { warmActiveCamera() }
        // Settle window first (BACKLOG 12): count down visibly, THEN calibrate — the user is
        // still holding the phone from tapping the button, and that handling is exactly the
        // noise the calibration must not learn.
        startDryRunSettle()
    }

    /// Re-learns the baselines without ending the test.
    ///
    /// Placement testing is iterative — set the phone down, read the numbers, move it, read
    /// again — and every move invalidates the baseline those numbers are measured against.
    /// Vision is the clearest case: its baseline *is* the scene, so after a move the row
    /// reports a large permanent change that means nothing at all. The only way to re-baseline
    /// used to be closing the sheet and reopening it, which also discarded the trip tally the
    /// owner was watching.
    ///
    /// Trip counts are kept on purpose; the settle countdown runs again because tapping the
    /// button is itself handling, and that is exactly the noise calibration must not learn.
    func recalibrateDryRun() {
        guard dryRunActive, dryRunCountdown == nil else { return }
        dryRunGeneration += 1   // a calibration in flight is abandoned: its completion must not fire
        for (_, m) in monitors { m.stop() }
        dryRunTimer?.invalidate(); dryRunTimer = nil
        dryRunTrips = [:]
        lastCalibration = nil
        startDryRunSettle()
    }

    /// The settle countdown, then calibration. Shared by the initial start and by a
    /// re-calibration so the two can never drift apart.
    private func startDryRunSettle() {
        dryRunCountdown = Self.dryRunSettleSeconds
        dryRunSettleTimer?.invalidate()
        dryRunSettleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.dryRunActive, let remaining = self.dryRunCountdown else { return }
                if remaining > 1 {
                    self.dryRunCountdown = remaining - 1
                } else {
                    self.dryRunSettleTimer?.invalidate(); self.dryRunSettleTimer = nil
                    self.dryRunCountdown = nil
                    self.beginDryRunCalibration()
                }
            }
        }
    }

    /// The calibrate-then-watch half of the dry run, after the settle countdown has elapsed.
    private func beginDryRunCalibration() {
        for (_, m) in monitors where m.isEnabled && m.requiresCalibration { m.beginCalibration() }
        let generation = dryRunGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + calibrationDuration) { [weak self] in
            // Stale after a Recalibrate or a stop: the monitors were stopped and a new settle
            // countdown is running — ending "this" calibration would end the NEW one early and
            // start the monitors mid-settle (item 65, finding 17).
            guard let self, self.dryRunActive, self.dryRunGeneration == generation else { return }
            for (_, m) in self.monitors where m.isEnabled && m.requiresCalibration { m.endCalibration() }
            self.lastCalibration = self.makeCalibrationSummary()
            for (_, m) in self.monitors where m.isEnabled { m.start() }
            self.dryRunTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sampleDryRun() }
            }
        }
    }

    private func sampleDryRun() {
        guard dryRunActive else { return }
        var readings: [SensorType: SensorReading] = [:]
        for type in SensorType.tripwires {
            if let m = monitors[type], m.isEnabled, let r = m.liveReading() { readings[type] = r }
        }
        dryRunReadings = readings
    }

    func stopDryRun() {
        dryRunActive = false
        dryRunGeneration += 1   // no calibration completion outlives the dry run
        dryRunTimer?.invalidate(); dryRunTimer = nil
        dryRunSettleTimer?.invalidate(); dryRunSettleTimer = nil
        dryRunCountdown = nil
        camera.shutDown()   // the dry run may have warmed it for the vision row
        for (_, m) in monitors { m.stop() }
        dryRunReadings = [:]
        dryRunTrips = [:]
        dryRunCounts = [:]
        // Release the dry run's Pro snapshot (32.R3). A dry run requires being disarmed, so
        // no disarm() follows to clear it — and left set, `cloudAllowed` stayed true after a
        // trial lapsed, letting a connectivity flap re-establish the push subscription for a
        // now-free user: the same leak the disarm path already closed (P-01), reintroduced
        // through the side door. Arming re-snapshots, so nothing else reads this stale.
        armedPro = false
    }

    /// The test view's touch pad reports here. Touch has no switch (item 83), so every tap counts.
    func dryRunReportTouch() {
        guard dryRunActive else { return }
        dryRunTrips[.touch] = Date()
        dryRunCounts[.touch, default: 0] += 1
    }
}
