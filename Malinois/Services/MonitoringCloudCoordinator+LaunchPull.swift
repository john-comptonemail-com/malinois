//
//  MonitoringCloudCoordinator+LaunchPull.swift
//  Malinois
//
//  The launch pull's pure rules: how much it asks iCloud for, and what Home says while it runs; and the pull that
//  follows Verify iCloud access (item 143). Owned by the cloud coordinator.
//

import Foundation

extension MonitoringCloudCoordinator {
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

/// How the last pull of the event log from iCloud went (item 227's Codex-1; the owner's D6 (a), every pull): whether it
/// ran to the end, and how many records it found that this version of Malinois cannot read (one with no ID or date, or a
/// status kind a later version wrote). Home and the top of the Event Log say what it shows, until a pull runs to the end
/// and, for records it cannot read, while the last pull found any.
struct CloudPullOutcome: Equatable, Sendable {
    var complete: Bool
    var unreadable: Int

    /// Home's line when the last pull did not run to the end (the owner's "wording approved", 2026-11-12, W6).
    static let homeIncomplete = "Malinois couldn't read all of your event log from iCloud. Pull down in the Event Log to try again."
    /// The Event Log's top row, the same case (W7).
    static let logIncomplete = "Part of your event log in iCloud couldn't be read. Pull down to try again."

    /// The line for records the last pull could not read, on Home and in the Event Log (W8).
    static func unreadableLine(_ count: Int) -> String {
        count == 1 ? "1 record in iCloud can't be read by this version of Malinois and isn't shown."
                   : "\(count) records in iCloud can't be read by this version of Malinois and aren't shown."
    }

    /// What Home says of it.
    var homeLines: [String] {
        (complete ? [] : [Self.homeIncomplete]) + (unreadable > 0 ? [Self.unreadableLine(unreadable)] : [])
    }

    /// What the top of the Event Log says of it.
    var logLines: [String] {
        (complete ? [] : [Self.logIncomplete]) + (unreadable > 0 ? [Self.unreadableLine(unreadable)] : [])
    }
}
