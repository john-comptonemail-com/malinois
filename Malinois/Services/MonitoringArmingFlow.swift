import Foundation

@MainActor
protocol MonitoringArmingHost: AnyObject {
    // All queried on demand, including after permission or queued timer callbacks.
    var armingState: MonitoringState { get }
    var armingEntitlementResolved: Bool { get }
    var armingGuidedAccessEnabled: Bool { get }
    var armingWasAutoRecovered: Bool { get }
    var armingDryRunActive: Bool { get }
    var armingFirstArmBriefing: FirstArmBriefing.Parts? { get }
    var armingDevicePasscodeMissingNow: Bool { get }

    func armingStopDryRun()
    func armingSetFirstArmBriefing(_ parts: FirstArmBriefing.Parts?)
    func armingRefreshGuidedAccess()
    func armingRefreshSirenVolumeWarning()
    func armingRefreshIdleTimer()
    func armingSetDevicePasscodeMissing(_ missing: Bool)

    // Exact existing beginArming fragments, in their original order around the flow's GA-lift choice.
    func armingPrepareWatch()
    func armingPresentGuidedAccessCheck()
    // Publish .arming then persist the inherited countdown marker, synchronously.
    func armingEnterGrace()
    func armingEnterCalibration()
    // Root owns monitor iteration and the calibration summary, which dry run also writes.
    func armingBeginMonitorCalibration()
    func armingFinishMonitorCalibration()
    func armingStartWatching()
    // Called only after flow publishes review=false; root's physical actions stay contiguous.
    func armingEnterCovertWatch()
    func armingDisarm()
    @discardableResult func armingLogStateChange(_ kind: String) -> Event
}

/// Owns arming progression and timers. The engine remains its weak physical/recovery and publication host.
@MainActor
final class MonitoringArmingFlow {
    weak var host: (any MonitoringArmingHost)?
    let settings: AppSettings
    let eventStore: EventStore
    let camera: any EvidenceCamera
    let timing: EngineTiming

    init(settings: AppSettings, eventStore: EventStore, camera: any EvidenceCamera, timing: EngineTiming) {
        self.settings = settings
        self.eventStore = eventStore
        self.camera = camera
        self.timing = timing
    }

    var onGraceRemainingChange: ((Int) -> Void)?
    var onCalibrationProgressChange: ((Double) -> Void)?
    var onShowingCalibrationReviewChange: ((Bool) -> Void)?
    var onGuidedAccessLiftedThisArmChange: ((Bool) -> Void)?
    var graceRemaining = 0 { willSet { onGraceRemainingChange?(newValue) } }
    var calibrationProgress = 0.0 { willSet { onCalibrationProgressChange?(newValue) } }
    var showingCalibrationReview = false { willSet { onShowingCalibrationReviewChange?(newValue) } }
    var guidedAccessLiftedThisArm = false { willSet { onGuidedAccessLiftedThisArmChange?(newValue) } }

    var graceTimer: Timer?

    var graceEndsAt: Date?

    var calibrationTimer: Timer?

    /// Counts calibration runs, so a tick acts only for its own (item 129, F2).
    var calibrationRun = 0

    /// The screen's minute without a touch (MonitoringArmingFlow+Briefing.swift): its timer, and the last touch.
    var firstArmBriefingTimer: Timer?

    var firstArmBriefingLastTouch = Date()

    /// R3-8: leave-and-return re-arms the lift button, and every unauthenticated tap used
    /// to mint a fresh pushed audit record — repeatable without consequence. One record
    /// per unconsumed spree: this latches on the first logged lift and releases only when
    /// a watch goes LIVE (consuming the spree), so the "someone poked at it" signal survives
    /// while the repetition is deduplicated. It used to release when an arm merely BEGAN, so
    /// ARM → lift → Cancel minted a record per cycle — five hundred cycles filled the count
    /// cap and evicted genuine evidence first (item 73, review 3 R3.4). Going live is out of
    /// a snoop's reach: the countdown has to complete.
    var unconsumedLiftLogged = false

    var calibrationDuration: TimeInterval { timing.calibrationDuration }

    var state: MonitoringState { host?.armingState ?? .disarmed }
    var guidedAccessEnabled: Bool { host?.armingGuidedAccessEnabled ?? false }
    var armWasAutoRecovered: Bool { host?.armingWasAutoRecovered ?? false }
    var dryRunActive: Bool { host?.armingDryRunActive ?? false }
    var firstArmBriefing: FirstArmBriefing.Parts? {
        get { host?.armingFirstArmBriefing }
        set { host?.armingSetFirstArmBriefing(newValue) }
    }
    var armingBlockedByGuidedAccess: Bool {
        Self.armingBlocked(requireGuidedAccess: settings.requireGuidedAccess,
                           guidedAccessOn: guidedAccessEnabled,
                           liftedThisArm: guidedAccessLiftedThisArm)
    }
    var armingBlockedByEntitlementCheck: Bool {
        Self.armingBlockedByEntitlementCheck(entitlementResolved: host?.armingEntitlementResolved ?? false)
    }
    var armPINCheckIsDue: Bool {
        Self.armPINCheckDue(lastEntry: KeychainService.lastCorrectEntry, now: Date())
    }
    nonisolated static let armPINCheckInterval = MonitoringEngine.armPINCheckInterval
    nonisolated static let cancelRunKey = MonitoringEngine.cancelRunKey
    nonisolated static let cancelRunGap = MonitoringEngine.cancelRunGap
    nonisolated static let cancelWriteWait = MonitoringEngine.cancelWriteWait
    func stopDryRun() { host?.armingStopDryRun() }
    func refreshGuidedAccess() { host?.armingRefreshGuidedAccess() }
    func refreshSirenVolumeWarning() { host?.armingRefreshSirenVolumeWarning() }
    func refreshIdleTimer() { host?.armingRefreshIdleTimer() }
    func startWatching() { host?.armingStartWatching() }
    func disarm() { host?.armingDisarm() }

    /// Strong before finite permission work is scheduled; weak timer admission takes its token only inside the callback.
    struct FiniteWorkLifetime {
        private let owner: (any MonitoringArmingHost)?
        init(owner: (any MonitoringArmingHost)?) { self.owner = owner }
        func keepAlive() { withExtendedLifetime(owner) {} }
    }
    func retainHostForFiniteWork() -> FiniteWorkLifetime { FiniteWorkLifetime(owner: host) }
    func consumeLiftSpree() { unconsumedLiftLogged = false }
    /// Original disarm timer fragment; review clearing remains at its separate, later position.
    func stopCountdownAndCalibration() {
        graceTimer?.invalidate(); graceTimer = nil; graceEndsAt = nil
        calibrationTimer?.invalidate(); calibrationTimer = nil
    }
    func clearReview() { showingCalibrationReview = false }
    /// Shared by review completion and the trip responder's early transition.
    func goCovert() {
        showingCalibrationReview = false
        host?.armingEnterCovertWatch()
    }
}
