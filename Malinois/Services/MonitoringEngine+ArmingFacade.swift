// Existing engine arming entries; timing/progression belongs to MonitoringArmingFlow.
import Foundation

extension MonitoringEngine {
    typealias ArmTapOutcome = MonitoringArmingFlow.ArmTapOutcome
    var calibrationDuration: TimeInterval { armingFlow.calibrationDuration }

    func beginArming() {
        armingFlow.beginArming()
    }

    /// Pure (unit-tested). Arming is blocked only when the owner asked for the requirement
    /// *and* Guided Access is off *and* the requirement wasn't lifted for this one arm.
    /// Deliberately not consulted by crash recovery — see `reArmAfterRecovery`.
    nonisolated static func armingBlocked(requireGuidedAccess: Bool, guidedAccessOn: Bool,
                                          liftedThisArm: Bool = false) -> Bool {
        MonitoringArmingFlow.armingBlocked(requireGuidedAccess: requireGuidedAccess, guidedAccessOn: guidedAccessOn, liftedThisArm: liftedThisArm)
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
        MonitoringArmingFlow.shouldAutoLiftGuidedAccessOnFirstArm(
            hasArmedOnce: hasArmedOnce,
            requireGuidedAccess: requireGuidedAccess,
            guidedAccessOn: guidedAccessOn
        )
    }

    func liftGuidedAccessRequirementForThisArm() {
        armingFlow.liftGuidedAccessRequirementForThisArm()
    }

    /// Expires an unused lift — called when the arming screen goes away and at disarm.
    func clearGuidedAccessLift() {
        armingFlow.clearGuidedAccessLift()
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
        MonitoringArmingFlow.armingBlockedByEntitlementCheck(entitlementResolved: entitlementResolved)
    }

    /// Step 2: the user confirmed the Guided Access coaching and wants to proceed to the
    /// grace countdown. Guided Access is recommended by default; if the owner has turned on
    /// "Require Guided Access", arming refuses while it's off.
    func confirmGuidedAccessAndStartGrace() {
        armingFlow.confirmGuidedAccessAndStartGrace()
    }

    /// The grace countdown itself, with no Guided Access gate. Crash recovery uses this
    /// directly: if the app died and Guided Access ended with it, refusing to re-arm would
    /// leave the device silently **unprotected** — the exact failure F-12 exists to prevent.
    /// Re-protecting on a weaker footing beats not re-protecting at all; the arming screen
    /// still shows that Guided Access is off.
    func beginGraceCountdown() {
        armingFlow.beginGraceCountdown()
    }

    /// Abort the arming flow (before Armed) without needing the PIN.
    func cancelArming() {
        armingFlow.cancelArming()
    }

    /// Pure (unit-tested; ADR 0054's decision 4): whether the ARM tap asks for the PIN first. Due with no correct entry
    /// on record (an install updating to 1.8.1 is asked once: option A), once the interval has passed since the last
    /// one, or when the stored time lies ahead of the clock (it went back: ask rather than trust). A clock moved
    /// forward only brings the ask sooner, and one moved back can only postpone it, which costs nothing: arming is the
    /// safe direction.
    nonisolated static func armPINCheckDue(lastEntry: Date?, now: Date, interval: TimeInterval = armPINCheckInterval) -> Bool {
        MonitoringArmingFlow.armPINCheckDue(lastEntry: lastEntry, now: now, interval: interval)
    }

    /// Home's ARM tap (ADR 0054): the PIN first when the check is due, and otherwise the arming at once, as after a
    /// correct PIN at the arm gate. Decided here rather than in HomeView, so its tests drive it (item 162's G1).
    @discardableResult
    func armTapped() -> ArmTapOutcome {
        armingFlow.armTapped()
    }

    /// The ARM tap's work once the PIN check, when it was due, has passed: the camera question on the first tap that
    /// needs the camera (item 69, ADR 0011), then the arming screen (`beginArming`). Asked while still on Home, so
    /// never under Guided Access, where iOS records a blocked question as a refusal; a refusal still arms, with the
    /// existing "Camera access is denied" notice. Vision needs the camera as much as capture does.
    func armAfterPINCheck() {
        armingFlow.armAfterPINCheck()
    }

    /// Reads again whether this iPhone has no device passcode, for the arming screen's line: when the screen appears,
    /// and when the app is back on it (from Settings, where the owner may just have set one).
    func refreshDevicePasscode() {
        armingFlow.refreshDevicePasscode()
    }

    /// Pure (unit-tested): whether iOS's answer says no device passcode is set. Only that answer counts: a check that
    /// cannot run for another reason (the biometrics locked out, no screen to show it on) says nothing about it.
    nonisolated static func passcodeMissing(canEvaluate: Bool, error: NSError?) -> Bool {
        MonitoringArmingFlow.passcodeMissing(canEvaluate: canEvaluate, error: error)
    }

    /// The Guided Access step's Start countdown (item 131). Before a new install's first arm, before its first arm
    /// under Guided Access, and before any install's first arm on 1.8.1 or later (the Voice Control part, item 144
    /// (e)), the one-time screen comes first (`firstArmBriefing`) and its button starts the countdown; otherwise the
    /// countdown starts at once, as before. The automatic re-arm after a crash calls the
    /// countdown directly and never comes here, so it never waits for a tap.
    func startCountdownTapped() {
        armingFlow.startCountdownTapped()
    }

    /// The screen's "I understand": what it showed is acknowledged for good, and the countdown starts through the
    /// same gate as Start countdown, so "Require Guided Access" still holds if Guided Access ended meanwhile.
    func acknowledgeFirstArmBriefing() {
        armingFlow.acknowledgeFirstArmBriefing()
    }

    /// The screen appeared or went away: the arming flow's hold on auto-lock follows it (`keepsDeviceAwake`), and its
    /// minute without a touch starts afresh or ends.
    func firstArmBriefingDidChange() {
        armingFlow.firstArmBriefingDidChange()
    }

    /// A touch on the screen, a scroll or a tap: the minute starts afresh. Only a date moves, so a scroll's stream of
    /// touches costs nothing; the wait reads it when it ends.
    func noteFirstArmBriefingActivity() {
        armingFlow.noteFirstArmBriefingActivity()
    }

}
