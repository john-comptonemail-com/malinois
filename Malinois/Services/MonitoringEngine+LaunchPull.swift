//
//  MonitoringEngine+LaunchPull.swift
//  Malinois
//
//  The launch pull's pure rules: how much it asks iCloud for, and what Home says while it runs; and the pull that
//  follows Verify iCloud access (item 143). Kept apart from MonitoringEngine.swift, which sits at the lint size limits.
//

import Foundation

extension MonitoringEngine {
    /// Verify iCloud access just succeeded (item 143): run what a relaunch would have. The upload retry, then the launch
    /// pull, which fills the log from iCloud, settles a restore owed since the install, checks this phone's copies
    /// (item 87) and refreshes Home's "Allow notifications" line once another device's records are in. The button ran
    /// only the retry and a plain pull before, so the line and the restore waited for a relaunch. The pull still asks
    /// for everything the log can hold, as the button's did, where the launch rule alone would ask a log that already
    /// has records (a newly selected account) for one page. An owed reinstall record is written first (item 148's 5),
    /// so it binds to the verified account and the retry can upload it.
    func cloudAccessVerified() async {
        writeOwedReinstallRecord()
        await retryPendingSync()
        await restoreFromCloudAtLaunch(minimumLimit: EventStore.maxEvents)
    }

    /// Pure (unit-tested). How much the launch pull asks iCloud for: everything the local cap
    /// allows when the log is empty or a restore is owed — a fresh install, whose records are in
    /// iCloud, not missing, including one whose first pull could not reach it (item 89, C1) —
    /// and one page otherwise, which is what the other devices did since.
    nonisolated static func launchSyncLimit(localEventCount: Int, restoreOwed: Bool = false,
                                            cap: Int, page: Int) -> Int {
        localEventCount == 0 || restoreOwed ? cap : page
    }

    /// What a launch pull is doing, for Home's line while it runs (owner follow-up, 2026-10-11).
    enum LaunchPullKind: Equatable {
        /// The log is empty or a restore is owed since the install: the pull fills the log.
        case restoring
        /// A routine pull for what other devices recorded since.
        case checking

        /// Home's line while the launch pull runs.
        var homeLabel: String {
            switch self {
            case .restoring: return "Restoring your event log from iCloud…"
            case .checking: return "Checking iCloud for new events…"
            }
        }
    }

    /// Pure (unit-tested): what the launch pull is doing, by the same rule as `launchSyncLimit`:
    /// a restore when the log is empty or a restore is owed, otherwise a routine check. Home said
    /// "Restoring" on every launch before (owner, 2026-10-11), which read as lost history.
    nonisolated static func launchPullKind(localEventCount: Int, restoreOwed: Bool) -> LaunchPullKind {
        localEventCount == 0 || restoreOwed ? .restoring : .checking
    }
}
