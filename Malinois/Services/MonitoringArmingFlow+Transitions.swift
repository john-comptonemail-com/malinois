// Arming progression owned by MonitoringArmingFlow.
import Foundation
import AVFoundation
import LocalAuthentication

extension MonitoringArmingFlow {

    func beginArming() {
        guard state == .disarmed else { return }
        // Never snapshot `armedPro` from an unresolved entitlement — that arms a session
        // permanently degraded for no reason the owner can see. The UI disables the control
        // while this is true; the guard is here so no other caller can route around it.
        guard !armingBlockedByEntitlementCheck else { return }
        // Defensive: `handleTrip` checks `dryRunActive` BEFORE the armed guard, so a dry run
        // that somehow outlived its sheet would silently swallow every tamper. The sheet's
        // `onDisappear` is what normally ends it — this makes the engine's own invariant
        // ("never armed while dry-running") hold without relying on UI modality.
        if dryRunActive { stopDryRun() }
        firstArmBriefing = nil   // a screen left from an earlier arm never shows on this one (item 131)
        host?.armingPrepareWatch()
        // First arm only (BACKLOG 68): waive the Guided Access requirement for a brand-new
        // user's very first arm, automatically and logged, so nothing stands between install and
        // seeing the app work. `liftGuidedAccessRequirementForThisArm` no-ops if Guided Access is
        // already on (not blocked), so this never fires a spurious lift.
        if Self.shouldAutoLiftGuidedAccessOnFirstArm(hasArmedOnce: OnboardingState.hasArmedOnce,
                                                     requireGuidedAccess: settings.requireGuidedAccess,
                                                     guidedAccessOn: guidedAccessEnabled) {
            liftGuidedAccessRequirementForThisArm()
        }
        host?.armingPresentGuidedAccessCheck()
    }

    /// Pure (unit-tested). Arming is blocked only when the owner asked for the requirement
    /// *and* Guided Access is off *and* the requirement wasn't lifted for this one arm.
    /// Deliberately not consulted by crash recovery — see `reArmAfterRecovery`.
    nonisolated static func armingBlocked(requireGuidedAccess: Bool, guidedAccessOn: Bool,
                                          liftedThisArm: Bool = false) -> Bool {
        requireGuidedAccess && !liftedThisArm && !guidedAccessOn
    }

    /// Pure (unit-tested; BACKLOG 68, owner ruling 2026-09-04). The FIRST arm on a fresh install
    /// auto-applies the one-arm Guided Access lift, so a brand-new user reaches the grace
    /// countdown with no extra tap and no accessibility setup. Only the first arm, and only when
    /// the requirement would actually block (it is on and Guided Access is off) — so a user who
    /// has already turned Guided Access on gets no spurious lift and no `gaLifted` record. Every
    /// later arm enforces the requirement; the post-session nudge teaches Guided Access with
    /// context. The lift is logged like a manual one, so the first session's log is honest about
    /// having run without the requirement.
    nonisolated static func shouldAutoLiftGuidedAccessOnFirstArm(hasArmedOnce: Bool,
                                                                 requireGuidedAccess: Bool,
                                                                 guidedAccessOn: Bool) -> Bool {
        !hasArmedOnce && armingBlocked(requireGuidedAccess: requireGuidedAccess, guidedAccessOn: guidedAccessOn)
    }

    func liftGuidedAccessRequirementForThisArm() {
        guard armingBlockedByGuidedAccess else { return }
        guidedAccessLiftedThisArm = true
        if !unconsumedLiftLogged {
            unconsumedLiftLogged = true
            host?.armingLogStateChange("gaLifted")
        }
    }

    /// Expires an unused lift — called when the arming screen goes away and at disarm.
    func clearGuidedAccessLift() {
        guidedAccessLiftedThisArm = false
    }

    /// Whether arming must wait for the entitlement check to finish.
    ///
    /// `beginArming` snapshots `armedPro` for the whole session, and `status` starts `.free`
    /// while StoreKit resolves. Arming inside that window silently produced a session with no
    /// Sound, no Vision, no multi-cam and short clips — for its entire duration, even though
    /// entitlement resolved milliseconds later. Nothing said so; the owner had paid for
    /// features that simply did not run.
    ///
    /// Pure so the rule is pinned rather than implied by a view modifier. The wait is short and
    /// bounded by a local cache read (see `ProEntitlements.refresh`), and it is *visible* — Home
    /// says "Checking Pro status…" throughout — which is the difference between a delay and a
    /// silent downgrade.
    nonisolated static func armingBlockedByEntitlementCheck(entitlementResolved: Bool) -> Bool {
        !entitlementResolved
    }

    /// Step 2: the user confirmed the Guided Access coaching and wants to proceed to the
    /// grace countdown. Guided Access is recommended by default; if the owner has turned on
    /// "Require Guided Access", arming refuses while it's off.
    func confirmGuidedAccessAndStartGrace() {
        refreshGuidedAccess()
        guard !armingBlockedByGuidedAccess else { return }
        beginGraceCountdown()
    }

    /// The grace countdown itself, with no Guided Access gate. Crash recovery uses this
    /// directly: if the app died and Guided Access ended with it, refusing to re-arm would
    /// leave the device silently **unprotected** — the exact failure F-12 exists to prevent.
    /// Re-protecting on a weaker footing beats not re-protecting at all; the arming screen
    /// still shows that Guided Access is off.
    func beginGraceCountdown() {
        // Re-sample the siren volume here, entering the grace step — this is the screen
        // that actually renders the low-volume warning, and it comes right after the
        // coaching that tells the user to turn the volume up, so the warning reflects the
        // volume as of *now* rather than back at beginArming (V-06).
        refreshSirenVolumeWarning()
        startGraceCountdown()
    }

    func startGraceCountdown() {
        host?.armingEnterGrace()
        let total = max(0, settings.gracePeriodSeconds)
        graceRemaining = total
        graceEndsAt = Date().addingTimeInterval(Double(total))
        graceTimer?.invalidate()
        // Wall-clock driven, and scheduled in `.common` run-loop modes. The old version
        // decremented once per tick in `.default` mode — so a single missed tick (a
        // first-run main-thread hitch, or the run loop entering an animation/tracking mode
        // where `.default` timers pause) FROZE the number, the "stalls at N for ~10s" bug.
        // Deriving the number from real elapsed time makes a delayed tick self-correct, and
        // `.common` mode keeps it firing through UI animation. Ticks faster (0.2s) so it
        // recovers promptly. (Calibration was already wall-clock based, so it never stalled.)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let host = self.host, let endsAt = self.graceEndsAt else { return }
                let lifetime = FiniteWorkLifetime(owner: host)
                defer { lifetime.keepAlive() }
                let remaining = endsAt.timeIntervalSinceNow
                self.graceRemaining = max(0, Int(remaining.rounded(.up)))
                if remaining <= 0 {
                    self.graceTimer?.invalidate(); self.graceTimer = nil
                    self.graceEndsAt = nil
                    self.startCalibration()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        graceTimer = timer
    }

    func startCalibration() {
        host?.armingEnterCalibration()
        calibrationProgress = 0
        host?.armingBeginMonitorCalibration()
        let start = Date()
        calibrationTimer?.invalidate()
        calibrationRun &+= 1
        let run = calibrationRun
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // A tick's work can wait behind a disarm, or behind another tick past the end: it
                // acts only for its own run, still calibrating, and finishes it once (item 129, F2).
                guard let self, let host = self.host, self.calibrationRun == run, self.state == .calibrating else { return }
                let lifetime = FiniteWorkLifetime(owner: host)
                defer { lifetime.keepAlive() }
                let elapsed = Date().timeIntervalSince(start)
                self.calibrationProgress = min(1, elapsed / self.calibrationDuration)
                if elapsed >= self.calibrationDuration {
                    self.calibrationRun &+= 1
                    self.calibrationTimer?.invalidate(); self.calibrationTimer = nil
                    self.finishCalibrationAndArm()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // keep progress advancing through UI animation
        calibrationTimer = timer
    }

    func finishCalibrationAndArm() {
        host?.armingFinishMonitorCalibration()
        // Start watching NOW, before the review — the "calibration complete" screen
        // is for the owner's benefit and must not be an unprotected gap. The sensors
        // run during the review; a tamper is handled (handleTrip allows it, and
        // fireTrigger goes covert first — see below). With no tamper, the screen goes
        // covert after the card's dwell (`timing.calibrationReview`, 6 s). The review card
        // shows no Cancel button, so the covert step
        // isn't user-cancellable — but the guard below (still in the review + still
        // .calibrating) makes it a no-op if a disarm arrives from any path meanwhile.
        startWatching()
        showingCalibrationReview = true
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.calibrationReview) { [weak self] in
            guard let self, let host = self.host, self.showingCalibrationReview, self.state == .calibrating else { return }
            let lifetime = FiniteWorkLifetime(owner: host)
            defer { lifetime.keepAlive() }
            self.goCovert()
        }
    }

    /// Abort the arming flow (before Armed) without needing the PIN.
    func cancelArming() {
        guard state == .guidedAccessCheck || state == .arming || state == .calibrating else { return }
        // A crash-recovery re-arm is NOT user-initiated: cancelling it must require the
        // PIN, or a thief who caused the crash just taps "Cancel" to undo the auto
        // re-protection (R-04). The UI routes the cancel through PINEntryView → disarm().
        guard !armWasAutoRecovered else { return }
        // A countdown the owner started and someone cancelled: on the record (review 3, R3.2).
        // Cancelling needs no PIN — unlike a disarm — and used to leave nothing; the owner who
        // watched the countdown start and walked away believed the phone was armed. Pushed to
        // the owner's other devices on Pro through the disarm alert (`disarmSignalWanted`).
        if state == .arming || state == .calibrating { recordCancelledCountdown() }
        disarm()
    }

    /// A cancelled countdown on the record, one record per run (item 169's codex-1): ARM then Cancel needs no PIN, and
    /// each cancel used to add a status record and raise an alert, so a hundred cancels pushed the oldest status records
    /// out of the log, those not yet uploaded with them. A cancel within `cancelRunGap` of the run's last, with no watch
    /// live since, counts on the run's record instead: no new record, no new alert. The run is kept on disk
    /// (`cancelRunKey`), so a relaunch continues it; a watch going live ends it. A cancel that counts on the run's record
    /// has no journal line of its own, so it waits up to `cancelWriteWait` for the log's write (item 170's codex-2): on
    /// disk when the cancel returns if the queue is through by then; if not (a clip being stored ahead of it), the write
    /// lands after, and a kill before it loses this cancel's count (item 172's codex-1). The count stays on this phone,
    /// iCloud and the other devices keeping the run's first cancel (item 170's codex-1, the owner's (c)).
    private func recordCancelledCountdown(now: Date = Date()) {
        guard let host else { return }
        let defaults = UserDefaults.standard
        if let run = defaults.dictionary(forKey: Self.cancelRunKey),
           let id = (run["record"] as? String).flatMap(UUID.init(uuidString:)),
           let last = run["last"] as? TimeInterval,
           now.timeIntervalSince1970 >= last,   // one dated before the run's last (the clock moved back): a run of its own (codex-6)
           now.timeIntervalSince1970 - last < Self.cancelRunGap,
           var record = eventStore.events.first(where: { $0.id == id }) {
            record.cancelCount = (record.cancelCount ?? 1) + 1
            record.endDate = now
            eventStore.update(record)
            eventStore.waitForQueuedWrites(atMost: Self.cancelWriteWait)   // no journal line of its own (codex-2)
            defaults.set(["record": id.uuidString, "last": now.timeIntervalSince1970], forKey: Self.cancelRunKey)
            return
        }
        let record = host.armingLogStateChange("armingCancelled")
        defaults.set(["record": record.id.uuidString, "last": now.timeIntervalSince1970], forKey: Self.cancelRunKey)
    }
}
