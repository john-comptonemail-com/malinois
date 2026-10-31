//
//  MonitoringEngine+Screen.swift
//  Malinois
//
//  Screen brightness, the idle timer, the covert screen, the boot stamp and the disarm entry's forwarding: moved
//  unchanged from MonitoringEngine.swift (BACKLOG 158's first stage, 1.8.2's step 1), which sits at the lint size
//  limit. Members the class needs elsewhere are internal; the stored state stays in the class.
//

import Foundation
import OSLog
import Combine
import UIKit
import AVFoundation
import UserNotifications

extension MonitoringEngine {

    /// Sets the display brightness from the current state — highest priority first:
    /// capture flash → disarm PIN entry → tamper alert → recording → covert black.
    func refreshBrightness() {
        // Covert enforcement belongs to the covert screen only. While disarmed, never force
        // brightness (don't black out Home) — and during grace/calibration the normal arming
        // UI is on screen: the countdown is the owner's cancel window (V-04), and blacking it
        // out defeats it. Found on device 2026-08-29, the first time the recovery countdown
        // appeared at cold launch: this used to gate on `state.isActive`, which includes
        // `.arming`, so the scene-activation refresh landed mid-countdown and applied the
        // ladder's black to the one screen the owner is supposed to read and cancel.
        guard Self.enforcesCovertBrightness(state) else { return }
        UIScreen.main.brightness = Self.brightnessLevel(captureFlash: captureFlash,
                                                        padOpen: disarmEntryActive,
                                                        alertActive: alertActive,
                                                        recording: camera.isRecordingActive,
                                                        previous: previousBrightness)
    }

    /// Pure (unit-tested): which states the covert brightness ladder applies to — exactly the
    /// ones that render the covert screen. Everything else (Home, the arming flow) shows the
    /// normal UI at the owner's own brightness. Deliberately narrower than `isActive`, which
    /// exists for the app-switcher cover and answers a different question.
    nonisolated static func enforcesCovertBrightness(_ state: MonitoringState) -> Bool {
        state == .armed || state == .triggered
    }

    /// Pure (unit-tested). The covert screen's brightness ladder. The `recording` rung is
    /// the 2.5.14 requirement: while any capture session is live the screen must never be
    /// fully dark, or the REC indicator would be invisible and the app "blank during
    /// recording". Only with the camera genuinely off does covert drop to true black.
    nonisolated static func brightnessLevel(captureFlash: Bool, padOpen: Bool,
                                            alertActive: Bool, recording: Bool,
                                            previous: CGFloat) -> CGFloat {
        if captureFlash { return 1.0 }
        if padOpen { return max(previous, 0.6) }
        if alertActive { return alertScreenBrightness }
        if recording { return recordingScreenBrightness }
        return 0
    }

    /// Restores/re-applies covert brightness across app backgrounding, so a
    /// backgrounded-while-armed device isn't left globally dimmed (or, on return,
    /// bright). Called from RootView on scene-phase changes.
    func handleScenePhase(_ active: Bool) {
        if active {
            seedCloudOwnershipIfReadable()
            // A launch recovery still waiting runs first (item 88): the passes below act on the
            // flags it reads (the owed re-arm, the lapse-logged flag), and were written when it
            // always ran inside `init`, before them. Cleared first, the lapse flag made the
            // recovery record the same lapse twice. The app on screen ends its wait, as the
            // notice would a moment later (item 85); the notice then finds nothing to do.
            if launchRecoveryWaiting { runDeferredRecovery(appIsActive: true) }
            // Run an owed crash-recovery re-arm now that the owner is actually looking, so
            // the grace countdown's cancel window is visible (V-04). Reads the persisted flag
            // so a re-arm deferred on a background launch — even across a terminate — is
            // honored on the first foreground (M4). `performRecoveryReArm` re-checks and
            // clears the flag, so this is idempotent if the phase fires more than once.
            if state == .disarmed, UserDefaults.standard.bool(forKey: Self.pendingReArmKey) {
                performRecoveryReArm()
            }
            // Flush anything still pending. A background-task expiration mid-upload leaves an
            // event `.pending`, and the other retry paths are reconnect, crash recovery, and
            // opening the Event Log — so a benign expiration on the owner's own device sat
            // unsynced until they happened to browse the log (M3). No-op off Pro, and cheap
            // when nothing is pending.
            Task { await retryPendingSync() }
            // Re-sample Guided Access (BACKLOG 24). `guidedAccessStatusDidChangeNotification`
            // is only delivered to a running process, so a toggle made while the app was
            // suspended is missed entirely and never replayed on resume. Without this, Home's
            // "Guided Access ready / off" row kept showing the pre-background value until the
            // owner happened to enter the arming flow, which is the one place that re-sampled.
            // A security app showing a stale security indicator is the wrong kind of wrong.
            refreshGuidedAccess()
            // Back on the arming screen from Settings: a passcode set there takes its line away (1.8.2's step 34).
            if state == .guidedAccessCheck { refreshDevicePasscode() }
            // Back on screen disarmed under Guided Access (woken after a sleep, or launched into a
            // session): the screen hold starts afresh (item 92).
            if state == .disarmed, guidedAccessEnabled { resetGuidedAccessScreenHold() }
            // A live watch back from a lapse says how long nothing was watched (item 153's MAL-06), before the
            // tripwires' own checks below, so the log reads in order: interrupted, resumed, and any trip.
            if let started = backgroundLapseStartedAt {
                backgroundLapseStartedAt = nil
                if armedSince != nil {
                    logStateChange(Event.resumedKind(seconds: Int((lapseNow - started) / .seconds(1))))
                }
            }
            // The tripwires missed whatever happened while the process was suspended — a
            // Guided Access lock, an answered call — and iOS replays none of it. Let each
            // running monitor compare the live state with its baseline (review 3, R3.3): the
            // power monitor trips on a plug or unplug that spanned the lapse; the motion monitor's
            // next sample is compared with its calibrated pose, and its stall clock restarts.
            if state.isActive {
                for (_, m) in monitors where m.isEnabled { m.resumeAfterSuspension() }
            }
            // Enforce the automatic cloud-retention policy, at most daily (32.R2).
            Task { await enforceCloudRetentionIfDue() }
            // Notification permission may have changed in iOS Settings while suspended (34.H7).
            Task { await refreshNotificationHealth() }
            // Back in the foreground: any logged lapse has ended, so a kill from here is a
            // separate interruption and must be recorded as one.
            UserDefaults.standard.removeObject(forKey: Self.backgroundLapseLoggedKey)
            refreshBrightness()                       // re-apply covert/alert
        } else if state.isActive {
            UIScreen.main.brightness = Self.restoredBrightness(previous: previousBrightness)   // don't leave system dimmed
        }
    }

    /// The clock a lapse is timed on (item 153's MAL-06): `ContinuousClock`, which no setting moves and which keeps
    /// running while the device sleeps, so a lock's whole length counts.
    var lapseNow: ContinuousClock.Instant {
        #if DEBUG
        if let lapseClockForTesting { return lapseClockForTesting() }
        #endif
        return ContinuousClock.now
    }

    /// Auto-lock is disabled for every state except `.disarmed`, and disarmed while the Guided
    /// Access screen hold runs — see `keepsDeviceAwake`. Centralised so the flag can't be set in
    /// one path and forgotten in another.
    func refreshIdleTimer() {   // internal for MonitoringEngine+FirstArmBriefing.swift
        UIApplication.shared.isIdleTimerDisabled = Self.keepsDeviceAwake(
            state, guidedAccessOn: guidedAccessEnabled, holdRunning: guidedAccessScreenHoldTimer != nil,
            briefingShowing: firstArmBriefing != nil)
    }

    /// Pure (unit-tested). Whether the display must be kept from sleeping.
    ///
    /// Every state but `.disarmed` keeps it awake. `.arming` and `.calibrating` are the ones worth
    /// stating outright: they were missing, and their absence meant a phone set face down could
    /// lock and suspend the app before the watch ever started. Disarmed hands auto-lock back,
    /// except while the Guided Access screen hold runs (item 92); with Guided Access off,
    /// whatever the hold says, it is handed back. While "Before you arm" shows, the arming flow
    /// holds nothing either (ADR 0050's decision 8): the phone may sleep as on Home, and under
    /// Guided Access item 92's hold applies as on Home.
    nonisolated static func keepsDeviceAwake(_ state: MonitoringState, guidedAccessOn: Bool = false,
                                             holdRunning: Bool = false, briefingShowing: Bool = false) -> Bool {
        (state != .disarmed && !briefingShowing) || (guidedAccessOn && holdRunning)
    }

    /// Item 92: disarmed under Guided Access, keeps the screen on for
    /// `timing.guidedAccessScreenHold` from now, replacing any hold already running; in any other
    /// case, ends the hold. iOS can wake a phone that slept under Guided Access into a stuck
    /// notification screen that only ending Guided Access clears (README, Known iOS quirks).
    /// Called when Guided Access comes on or goes off, at the end of every disarm (a cancelled
    /// countdown included), and when the app comes back on screen disarmed under Guided Access.
    func resetGuidedAccessScreenHold() {
        guidedAccessScreenHoldTimer?.invalidate()
        guidedAccessScreenHoldTimer = nil
        if state == .disarmed, guidedAccessEnabled {
            guidedAccessScreenHoldNumber += 1
            let number = guidedAccessScreenHoldNumber
            guidedAccessScreenHoldTimer = Timer.commonMode(interval: timing.guidedAccessScreenHold,
                                                           repeats: false) { [weak self] _ in
                Task { @MainActor in self?.endGuidedAccessScreenHold(number) }
            }
        }
        refreshIdleTimer()
    }

    /// The hold numbered `number` has run its time, and the phone may sleep again, unless a
    /// newer hold replaced it or Guided Access ended it first.
    private func endGuidedAccessScreenHold(_ number: Int) {
        guard number == guidedAccessScreenHoldNumber, guidedAccessScreenHoldTimer != nil else { return }
        guidedAccessScreenHoldTimer = nil
        refreshIdleTimer()
    }

    /// The persistent side of going live (review 1, F1): the armed marker — storing the
    /// pre-arm brightness the next launch restores — and the boot stamp beside it, so a
    /// force-quit, a Voice Control close, or a crash is detected and classified at the next
    /// launch. Planted the moment the watch is live, under the calibration card, not when the
    /// screen goes black six seconds later: the sensors are live and "armed" is on the record
    /// from the earlier moment, and a kill inside that window used to leave nothing behind.
    /// `previousBrightness` was captured at `beginArming` — deliberately not re-sampled here,
    /// where the display may already have been dimmed by the ambient sensor.
    func markWatchLive() {
        UserDefaults.standard.set(Double(previousBrightness), forKey: Self.armedMarkerKey)
        plantBootStamp()   // beside the marker: lets the next launch tell a restart from a kill (53)
        // The recovered watch is now protected; the armed marker covers it from here (F1).
        retireRecoveryMarker(Self.recoveryInProgressKey)
        retireRecoveryMarker(Self.armingInProgressKey)   // the armed marker takes over (R3.2)
    }

    /// The display side of going covert: keep the device awake and take the screen to black.
    /// Nothing persistent happens here any more — see `markWatchLive`.
    func engageCovertScreen() {
        refreshIdleTimer()
        refreshBrightness()
    }

    /// The display side of the disarm. Auto-lock is not touched here: the disarm hands it back
    /// once the state is `.disarmed`, or holds it a while under Guided Access (item 92).
    func releaseCovertScreen() {
        UIScreen.main.brightness = Self.restoredBrightness(previous: previousBrightness)   // the user's level, floored
        retireRecoveryMarker(Self.armedMarkerKey)   // clean exit
        retireRecoveryMarker(Self.recoveryInProgressKey)   // and no owed recovery (F1)
        retireRecoveryMarker(Self.armingInProgressKey)   // and no countdown in flight (R3.2)
        clearBootStamp()
    }

    /// Stores the current boot stamp beside whichever persistent session marker is being set
    /// (BACKLOG 53). A kernel that will not answer leaves no stamp, so the next launch
    /// classifies nothing rather than guessing.
    func plantBootStamp() {
        guard let stamp = BootStamp.current() else { clearBootStamp(); return }
        UserDefaults.standard.set(stamp.bootTime, forKey: Self.armedBootTimeKey)
        UserDefaults.standard.set(stamp.takenAt, forKey: Self.armedBootStampAtKey)
    }

    private func clearBootStamp() {
        UserDefaults.standard.removeObject(forKey: Self.armedBootTimeKey)
        UserDefaults.standard.removeObject(forKey: Self.armedBootStampAtKey)
    }

    /// Reads and clears the planted stamp; `nil` when none was planted (a marker from a build
    /// before BACKLOG 53, or a kernel that would not answer at arm).
    func consumeBootStamp() -> BootStamp? {
        defer { clearBootStamp() }
        let defaults = UserDefaults.standard
        guard let bootTime = defaults.object(forKey: Self.armedBootTimeKey) as? Double,
              let takenAt = defaults.object(forKey: Self.armedBootStampAtKey) as? Double else { return nil }
        return BootStamp(bootTime: bootTime, takenAt: takenAt)
    }

    /// Raise the screen so the hidden disarm PIN pad is actually visible.
    /// NOTE: this does NOT stop the siren — only a verified PIN (disarm) does,
    /// otherwise anyone could silence the alarm just by holding the screen.
    /// The alert *message* is hidden during PIN entry by ArmedView's showPINPad.
    /// Called on the disarm HOLD press-down (before the pad opens). Opens the owner-
    /// attribution candidate window so the touch that starts the hold — and anything
    /// captured during the 5 s hold — is attributed to the owner if a correct PIN follows.
    /// Called on the disarm HOLD press-down (before the pad opens). Opens the owner-
    /// attribution candidate window (R-02). Delegates to `DisarmEntryCoordinator`.
    func noteDisarmCandidate() { disarmEntry.noteCandidate() }

    /// The hold was released before the pad opened (a tap, not a disarm). No-op once open.
    func cancelDisarmCandidate() { disarmEntry.cancelCandidate() }

    /// The pad opened: raise brightness, pause proximity blanking, start the inactivity timer.
    func beginDisarmEntry() { disarmEntry.begin() }

    /// The PIN pad on each digit: keep the pad alive (R-09), bounded by the ceiling.
    func noteDisarmActivity() { disarmEntry.noteActivity() }

    /// PIN entry dismissed without a disarm (cancel or inactivity timeout): back to covert.
    func endDisarmEntry() { disarmEntry.end() }

}
