// Arming progression owned by MonitoringArmingFlow.
import Foundation
import AVFoundation
import LocalAuthentication

extension MonitoringArmingFlow {

    /// The Guided Access step's Start countdown (item 131). Before a new install's first arm, before its first arm
    /// under Guided Access, and before any install's first arm on 1.8.1 or later (the Voice Control part, item 144
    /// (e)), the one-time screen comes first (`firstArmBriefing`) and its button starts the countdown; otherwise the
    /// countdown starts at once, as before. The automatic re-arm after a crash calls the
    /// countdown directly and never comes here, so it never waits for a tap.
    func startCountdownTapped() {
        guard state == .guidedAccessCheck else { return }
        refreshGuidedAccess()
        let parts = FirstArmBriefing.partsDue(ownerStarted: !armWasAutoRecovered, guidedAccessOn: guidedAccessEnabled,
                                              disarmAcknowledged: OnboardingState.acknowledgedDisarmBriefing,
                                              guidedAccessAcknowledged: OnboardingState.acknowledgedGuidedAccessBriefing,
                                              voiceControlAcknowledged: OnboardingState.acknowledgedVoiceControlBriefing)
        guard !parts.isEmpty else { confirmGuidedAccessAndStartGrace(); return }
        firstArmBriefing = parts
    }

    /// The screen's "I understand": what it showed is acknowledged for good, and the countdown starts through the
    /// same gate as Start countdown, so "Require Guided Access" still holds if Guided Access ended meanwhile.
    func acknowledgeFirstArmBriefing() {
        guard let parts = firstArmBriefing else { return }
        if parts.disarm { OnboardingState.acknowledgedDisarmBriefing = true }
        if parts.guidedAccess { OnboardingState.acknowledgedGuidedAccessBriefing = true }
        if parts.voiceControl { OnboardingState.acknowledgedVoiceControlBriefing = true }
        firstArmBriefing = nil
        guard state == .guidedAccessCheck else { return }
        confirmGuidedAccessAndStartGrace()
    }

    /// The screen appeared or went away: the arming flow's hold on auto-lock follows it (`keepsDeviceAwake`), and its
    /// minute without a touch starts afresh or ends.
    func firstArmBriefingDidChange() {
        refreshIdleTimer()
        firstArmBriefingTimer?.invalidate()
        firstArmBriefingTimer = nil
        guard firstArmBriefing != nil else { return }
        firstArmBriefingLastTouch = Date()
        waitForFirstArmBriefingTouch(timing.firstArmBriefingTimeout)
    }

    /// A touch on the screen, a scroll or a tap: the minute starts afresh. Only a date moves, so a scroll's stream of
    /// touches costs nothing; the wait reads it when it ends.
    func noteFirstArmBriefingActivity() {
        firstArmBriefingLastTouch = Date()
    }

    /// Waits `interval`, then cancels the arm if the minute has passed without a touch, or waits what is left of it.
    /// A phone asleep meanwhile fires it late, and the idle time still counts from the last touch.
    private func waitForFirstArmBriefingTouch(_ interval: TimeInterval) {
        firstArmBriefingTimer = Timer.commonMode(interval: max(interval, 0.05), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let host = self.host else { return }
                let lifetime = FiniteWorkLifetime(owner: host)
                defer { lifetime.keepAlive() }
                self.firstArmBriefingWaitEnded()
            }
        }
    }

    /// The minute without a touch ran out: the arm is cancelled back to Home, disarmed, with the parts still due
    /// (nothing was acknowledged) and no record (the countdown never started). A screen gone meanwhile, or a touch
    /// inside the minute, ends or extends the wait instead.
    private func firstArmBriefingWaitEnded() {
        guard firstArmBriefing != nil, state == .guidedAccessCheck else { return }
        let idle = Date().timeIntervalSince(firstArmBriefingLastTouch)
        guard idle >= timing.firstArmBriefingTimeout else {
            waitForFirstArmBriefingTouch(timing.firstArmBriefingTimeout - idle)
            return
        }
        firstArmBriefing = nil
        cancelArming()
    }
}
