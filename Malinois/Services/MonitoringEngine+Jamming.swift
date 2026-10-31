//
//  MonitoringEngine+Jamming.swift
//  Malinois
//
//  The jamming response (connectivity blackout): moved unchanged from MonitoringEngine.swift (BACKLOG 158's first
//  stage, 1.8.2's step 1), which sits at the lint size limit. Members the class needs elsewhere are internal; the
//  stored state stays in the class.
//

import Foundation
import OSLog
import Combine
import UIKit
import AVFoundation
import UserNotifications

extension MonitoringEngine {

    func handleConnectivityChange(_ online: Bool) {
        isOnline = online
        if online {
            offlineSince = nil
            blackoutTimer?.invalidate(); blackoutTimer = nil
            standDownBlackout()                 // benign outage resolved / jam lifted
            Task { await retryPendingSync() }   // auto-flush the instant a path returns
            // Recover the cross-device push subscription if it failed to set up at
            // arm (network briefly down then) — otherwise the owner's other devices
            // get no alert for the whole session. Idempotent; no-op if already set.
            // `cloudAllowed` so a mid-session upgrade also gets the subscription (P-01).
            // Never on the default switch a launch before the first unlock holds, and asked again
            // after each wait inside: the owner's choice can change meanwhile (item 165's A3,
            // Codex's codex-19).
            if alertSubscriptionWanted {
                #if DEBUG
                alertRefreshesAskedForTesting += 1
                #endif
                Task { await cloud.refreshSubscription(stillWanted: { [weak self] in self?.alertSubscriptionWanted ?? false }) }
            }
        } else {
            if offlineSince == nil { offlineSince = Date() }   // the transition, not a re-report
            // Debounce a total loss before treating it as suspected jamming — for any live
            // watch, not only while `.armed`: a loss that begins during a capture or the
            // calibration review is looked at again the moment the engine is armed
            // (`recheckBlackoutOnReturnToArmed`; item 65, finding 8). `evaluateBlackout`
            // keeps the armed gate, so nothing escalates from a state that can't.
            guard state.isActive, hadConnectivityAtArm, settings.jammingResponse else { return }
            scheduleBlackoutCheck(after: blackoutDebounce)
        }
    }

    /// Whether the account's alert subscriptions are wanted now: Pro (the session's or the account's), the owner's
    /// cross-device alerts on, and the stored settings loaded, not the defaults a launch before the first unlock holds.
    /// The reconnect's refresh and the arm's warm-up ask it after each wait (codex-19, codex-21).
    var alertSubscriptionWanted: Bool {
        settings.notifyOtherDevicesEffective(pro: cloudAllowed) && !settings.awaitingUnlock
    }

    private func scheduleBlackoutCheck(after delay: TimeInterval) {
        blackoutTimer?.invalidate()
        blackoutTimer = Timer.commonMode(interval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.evaluateBlackout() }
        }
    }

    /// Item 65, finding 8: the canary's one-shot check fires on the debounce after the path
    /// dropped; if the engine was busy then — a capture in flight, the calibration review — the
    /// check declined and nothing looked again, so a loss in the last seconds of any capture
    /// was never treated as jamming for that blackout. Called on every return to `.armed`:
    /// with the path still down and nothing escalated, the check runs once the loss has
    /// lasted the debounce — now, if it already has.
    func recheckBlackoutOnReturnToArmed() {
        guard state == .armed, !connectivity.isOnline, let since = offlineSince,
              !blackoutEscalated, hadConnectivityAtArm, settings.jammingResponse else { return }
        scheduleBlackoutCheck(after: Self.blackoutRecheckDelay(offlineFor: Date().timeIntervalSince(since),
                                                               debounce: blackoutDebounce))
    }

    /// Pure (unit-tested): the part of the debounce a loss still owes, never less than a beat.
    nonisolated static func blackoutRecheckDelay(offlineFor: TimeInterval, debounce: TimeInterval) -> TimeInterval {
        max(debounce - offlineFor, 0.05)
    }

    private func evaluateBlackout() {
        guard Self.shouldEscalateBlackout(armed: state == .armed,
                                          enabled: settings.jammingResponse,
                                          online: connectivity.isOnline,
                                          hadConnectivityAtArm: hadConnectivityAtArm,
                                          stationary: isStationary,
                                          alreadyEscalated: blackoutEscalated) else { return }
        // This path has no triggering capture, so request a best-effort frame. All paths
        // share the synchronous interference record written by `escalate` before alerting.
        escalate(.blackout, captureBlackoutFrame: true)
    }

    /// Pure decision (unit-tested): a stationary armed device that had a path at arm
    /// and has now totally lost it — feature on, not already escalated.
    static func shouldEscalateBlackout(armed: Bool, enabled: Bool, online: Bool,
                                       hadConnectivityAtArm: Bool, stationary: Bool,
                                       alreadyEscalated: Bool) -> Bool {
        armed && enabled && !online && hadConnectivityAtArm && stationary && !alreadyEscalated
    }

    /// The path must have been down at least this long before the trigger-time go-loud
    /// trusts the instantaneous offline reading (39.R2.2): a WiFi↔cellular handoff can leave
    /// the path unsatisfied for well under a second, and a genuine jam-then-grab timeline
    /// runs seconds to minutes — a 2 s floor filters the coincidence while barely delaying
    /// the deterrent. The 30 s blackout canary and the observed-failure path stand behind it.
    nonisolated static let offlineBlipFilter: TimeInterval = 2

    /// Pure decision (unit-tested): at trigger time, a real tamper whose evidence can't be
    /// exfiltrated should abandon covertness and go loud — but ONLY when a path we HAD at
    /// arm has since dropped (suspected jamming), and only once it has been down past the
    /// blip filter, so a sub-second handoff flap plus a coincidental trigger can't sound the
    /// siren (39.R2.2 — `jammingResponse` defaults ON, so the opt-in is soft). A device
    /// armed offline in a benign dead zone must not force-siren; its evidence is simply
    /// stored locally and uploads later. Mirrors `shouldEscalateBlackout`'s
    /// `hadConnectivityAtArm` gate (V-03).
    static func shouldGoLoudOnFailedExfil(jammingResponse: Bool, online: Bool,
                                          hadConnectivityAtArm: Bool,
                                          offlineFor: TimeInterval) -> Bool {
        jammingResponse && !online && hadConnectivityAtArm && offlineFor >= offlineBlipFilter
    }

    private var isStationary: Bool {
        lastMotionTrip.map { Date().timeIntervalSince($0) > stationaryWindow } ?? true
    }

    /// Abandon covertness. Each new blackout writes its signal-loss record before the
    /// warning/siren, including trigger-time and observed-upload failures. Repeated requests
    /// while escalated do not add records; reconnect/disarm allows a later incident.
    /// Only the timed canary requests a frame: trigger/upload paths already have an event
    /// and must not start another capture. Blackout lasts until disarm or reconnect; a flood
    /// shows a warning (siren only in Siren mode) that extends while tampering continues.
    func escalate(_ reason: Escalation, captureBlackoutFrame: Bool = false) {
        if escalation == .blackout { return }        // strongest state; don't downgrade
        if escalation == reason {
            if !reason.persists { scheduleAlertDismiss() }   // extend the flood window
            return
        }
        // Snapshot cloud authorization with the record, before any asynchronous work.
        let record = reason == .blackout ? logBlackoutRecord() : nil
        let sessionAllowed = cloudAllowed
        if reason == .blackout { blackoutEscalated = true }
        escalation = reason
        alertActive = true
        endCaptureLightForTheWarning()   // a lit clip's white screen would cover it (codex-1)
        refreshBrightness()
        if reason.forcesSiren || settings.responseMode == .siren {
            // No ramp on an escalation: suspected jamming means the evidence may never
            // escape, and a flood is an active attack — both need to be loud NOW.
            // goFullVolume() handles every prior state (not started, mid-ramp, or
            // interrupted by a call), so it overtakes a ramping siren or (re)starts a
            // stopped one at full volume.
            soundSiren(fullVolume: true)
        }
        if !reason.persists { scheduleAlertDismiss() }
        if let record {
            beginBindingUse(record.id)   // through the frame grab, until the upload has it (codex-6 on 0ed887f)
            Task {
                defer { endBindingUse(record.id) }
                if captureBlackoutFrame {
                    await captureBlackoutEvidence(for: record, cloudAllowed: sessionAllowed)
                } else {
                    await exfiltrate(record, cloudAllowedOverride: sessionAllowed)
                }
            }
        }
    }

    /// Stand down a *blackout* escalation when connectivity returns (a benign outage
    /// resolved, or the jam lifted after doing its deterrent job). disarm() clears
    /// everything separately; a flood fades on its own dismiss timer.
    private func standDownBlackout() {
        guard escalation == .blackout else { return }
        escalation = nil
        // Re-arm the escalation for the NEXT blackout. Without this the one-shot is
        // spent for the whole session, so an attacker can burn it with a brief jam,
        // let the path return (we stand down), then jam for real — silently.
        blackoutEscalated = false
        alertActive = false
        siren.stop()
        resumeAudioAfterSiren()
        refreshBrightness()
    }

    /// Writes the sensorless "Signal loss" record synchronously before any interference
    /// warning, even with the camera off, and schedules the Pro fact upload. Connectivity
    /// reflects the observed path: a network-class upload failure can escalate while that
    /// path still looks online, so it must not be labelled captured offline.
    /// Sensor traces preserve context; this records suspected interference, not its cause.
    func logBlackoutRecord() -> Event {
        let event = Event(startDate: Date(), endDate: Date(),
                          triggeredSensors: [],
                          motionTrace: monitors[.motion]?.recentTrace() ?? [],
                          audioTrace: monitors[.audio]?.recentTrace() ?? [],
                          visionTrace: monitors[.vision]?.recentTrace(),
                          cloudSyncState: .pending,
                          capturedOffline: !connectivity.isOnline,
                          thermalState: Self.thermalStateName(thermalState()))   // item 38, choice 3
        cloud.enrollment.registerLocalEvent(event)
        eventStore.add(event)
        eventCount = eventStore.events.count
        pushFactIfCloud(event)   // get the fact out immediately (Pro only)
        return event
    }

}
