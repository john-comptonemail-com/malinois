//
//  MonitoringEngine+RatingRequest.swift
//  Malinois
//
//  Apple's rating request (BACKLOG 137; 1.8.2's step 27, the owner's ruling: yes; ADR 0058). Malinois asks with
//  StoreKit's standard request (guideline 5.6.1 allows no other) at a calm moment: after a disarm that ended a live
//  watch with no incident in it, from the third such disarm on; never while arming, after a tamper, on Home's PIN pad or
//  under Guided Access (`HomeView.mayAskForRating`). iOS decides whether to show it, at most three times a year. The
//  count stays on this device; nothing is sent. Kept apart from MonitoringEngine.swift, which sits at the lint limit.
//

import Foundation

extension MonitoringEngine {
    /// How many calm disarms come before the first ask.
    nonisolated static let calmDisarmsBeforeRatingRequest = 3

    /// The calm disarms so far, kept on this device.
    static let calmDisarmsKey = "com.malinois.rating.calmDisarms"

    /// Pure (unit-tested): whether a calm disarm with this many behind it, itself included, asks: from the third on.
    nonisolated static func ratingRequestDue(calmDisarms: Int) -> Bool {
        calmDisarms >= calmDisarmsBeforeRatingRequest
    }

    /// Called by `disarm()` for a watch that went live at `start`. A calm one, with no incident in it but the owner's own
    /// handling at the pad (which the disarm has just marked as the owner's) and other devices' copies, is counted, and
    /// from the third on flags Home's request (`ratingRequestPending`). A watch with an incident does not count; it
    /// resets nothing, and it leaves no request waiting (codex-16 on 1.8.2: one flagged by an earlier calm watch, which
    /// Guided Access kept Home from making, lapses too; `beginArming` clears it as well).
    func noteDisarmForRatingRequest(watchStartedAt start: Date) {
        let tampered = eventStore.events.contains {
            !$0.isStateChange && !$0.isMirrored && $0.ownerAttributed != true && $0.startDate >= start
        }
        guard !tampered else {
            ratingRequestPending = false
            return
        }
        let defaults = UserDefaults.standard
        let calm = defaults.integer(forKey: Self.calmDisarmsKey) + 1
        defaults.set(calm, forKey: Self.calmDisarmsKey)
        if Self.ratingRequestDue(calmDisarms: calm) { ratingRequestPending = true }
    }

    /// Home made the request: the flag goes until the next calm disarm.
    func ratingRequestHandled() { ratingRequestPending = false }
}
