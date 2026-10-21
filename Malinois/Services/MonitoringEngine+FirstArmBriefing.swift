//
//  MonitoringEngine+FirstArmBriefing.swift
//  Malinois
//
//  The one-time screen before the first arm (BACKLOG 131): the Guided Access step's Start countdown shows it when
//  a part is due, and its button starts the countdown.
//

import Foundation

extension MonitoringEngine {
    /// The Guided Access step's Start countdown (item 131). Before a new install's first arm, and before its first
    /// arm under Guided Access, the one-time screen comes first (`firstArmBriefing`) and its button starts the
    /// countdown; otherwise the countdown starts at once, as before. The automatic re-arm after a crash calls the
    /// countdown directly and never comes here, so it never waits for a tap.
    func startCountdownTapped() {
        guard state == .guidedAccessCheck else { return }
        refreshGuidedAccess()
        let parts = FirstArmBriefing.partsDue(ownerStarted: !armWasAutoRecovered, guidedAccessOn: guidedAccessEnabled,
                                              disarmAcknowledged: OnboardingState.acknowledgedDisarmBriefing,
                                              guidedAccessAcknowledged: OnboardingState.acknowledgedGuidedAccessBriefing)
        guard !parts.isEmpty else { confirmGuidedAccessAndStartGrace(); return }
        firstArmBriefing = parts
    }

    /// The screen's "I understand": what it showed is acknowledged for good, and the countdown starts through the
    /// same gate as Start countdown, so "Require Guided Access" still holds if Guided Access ended meanwhile.
    func acknowledgeFirstArmBriefing() {
        guard let parts = firstArmBriefing else { return }
        if parts.disarm { OnboardingState.acknowledgedDisarmBriefing = true }
        if parts.guidedAccess { OnboardingState.acknowledgedGuidedAccessBriefing = true }
        firstArmBriefing = nil
        guard state == .guidedAccessCheck else { return }
        confirmGuidedAccessAndStartGrace()
    }
}
