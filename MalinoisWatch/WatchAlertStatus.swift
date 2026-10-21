//
//  WatchAlertStatus.swift
//  MalinoisWatch
//
//  What the watch's screen says about alerts (item 57, ADR 0042). Pure and Foundation-only, so the
//  iPhone test suite compiles it too and checks the wording.
//

import Foundation

/// Whether alerts will reach this watch, in the screen's words, with one line per check so the
/// screen always says what it is waiting for.
struct WatchAlertStatus: Equatable {
    /// The watch's registration for the alert pushes.
    enum Registration: Equatable { case pending, registered, failed }
    /// The iCloud account the pushes come through, as far as the watch can tell.
    enum Account: Equatable { case unknown, available, unavailable }
    /// Permission to show alerts on this watch, which the watch asks for itself.
    enum Notifications: Equatable { case unknown, allowed, denied }
    /// The account's tamper subscription as the iCloud server lists it to this watch. Missing means
    /// Cross-device alerts are off, or the watch sees a different account or environment.
    enum Subscriptions: Equatable { case unknown, found, missing, unreadable(String) }
    /// The direct link from the paired iPhone (ADR 0043), how the watch hears its own iPhone's
    /// alerts while it is connected through that iPhone, when iCloud sends it none.
    enum Link: Equatable { case starting, ready, unavailable }
    /// The path an alert took to the watch, shown on the screen so a test can tell them apart.
    enum AlertSource: String, Equatable { case iPhoneLink, iCloud }

    /// What the watch knows so far.
    struct Checks: Equatable {
        var registration: Registration = .pending
        var account: Account = .unknown
        var notifications: Notifications = .unknown
        var subscriptions: Subscriptions = .unknown
        var link: Link = .starting
        /// When the watch app last saw an alert arrive; kept on the watch only.
        var lastAlert: Date?
        /// Which path brought that alert, when known.
        var lastAlertSource: AlertSource?
    }

    /// The iPhone app's tamper subscription (`CloudExfiltrator`'s; a test keeps the two equal).
    static let tamperSubscriptionID = "malinois-tamper-meta-v2-sub"

    /// Pure (unit-tested). Whether a background wake for the iPhone link may end: the link is up,
    /// has handed over everything queued, and every alert it handed over has been posted. The link
    /// reports nothing pending as soon as it has handed an alert over, and a wake ended then could
    /// let watchOS suspend the app before the alert was shown (TestFlight 1.6 (60), Test 3). A
    /// failed activation ends it too: nothing more can arrive (the 1.6 review's finding 6).
    static func mayEndLinkWake(activated: Bool, contentPending: Bool, alertsInFlight: Int,
                               activationFailed: Bool = false) -> Bool {
        activationFailed || (activated && !contentPending && alertsInFlight == 0)
    }

    /// Pure (unit-tested; item 108, CE-03). The relayed alerts the watch has shown, and those it is
    /// posting now. An alert is remembered only once its post succeeded: remembered before, a post
    /// that failed was never tried again, though the iPhone sends each alert twice while the watch
    /// app is open (live and queued). A copy arriving while the first is still being posted is
    /// not posted as well.
    struct RelayLedger: Equatable {
        /// The alerts shown, newest last, at most `rememberedRelayLimit`; kept across launches.
        var shown: [String] = []
        /// The alerts being posted now. Not kept: a post the app's end cut short showed nothing.
        var posting: Set<String> = []

        /// Whether to post `id`: not when it was shown or is being posted. True marks it as posting.
        mutating func begin(_ id: String) -> Bool {
            guard !shown.contains(id), !posting.contains(id) else { return false }
            posting.insert(id)
            return true
        }

        /// Ends the post `begin` allowed, remembering `id` among the alerts shown only when `posted`
        /// says so (an alert summed up is remembered in its summary instead; ADR 0051).
        mutating func finish(_ id: String, posted: Bool) {
            posting.remove(id)
            if posted { shown = WatchAlertStatus.remembering(id, in: shown) }
        }
    }

    /// How many relayed alerts shown on their own the watch remembers (the 1.6 review's finding 5): 50
    /// until 1.8 (73), then 500, so the late queued copies of many alerts shown live are still
    /// recognized (Codex's X1 on build 73).
    static let rememberedRelayLimit = 500

    /// Pure (unit-tested). The remembered alert identifiers with `id` added, newest last, the
    /// oldest giving way at `limit`; one already remembered changes nothing. Kept across launches,
    /// so the queued copy of an alert the open app already showed live is recognized after a restart.
    static func remembering(_ id: String, in ids: [String], limit: Int = rememberedRelayLimit) -> [String] {
        guard !ids.contains(id) else { return ids }
        return Array((ids + [id]).suffix(limit))
    }

    /// Pure (unit-tested). The path a delivered alert took: the iPhone link's alerts carry
    /// identifiers starting "malinois-relay-" (`WatchAlertMessage.notificationIdentifier`; a test
    /// keeps the two in step); iCloud's are the system's own.
    static func source(ofNotification identifier: String) -> AlertSource {
        identifier.hasPrefix("malinois-relay-") ? .iPhoneLink : .iCloud
    }

    let headline: String
    let detail: String
    let lines: [String]

    /// Pure (unit-tested): a failed sign-up first, then a missing iCloud account, notifications off,
    /// and a missing or unreadable subscription; ready once all are known good; otherwise
    /// "Checking…", with the lines saying what is still pending.
    static func describe(_ checks: Checks) -> WatchAlertStatus {
        let lines = lineTexts(checks)
        func status(_ headline: String, _ detail: String) -> WatchAlertStatus {
            WatchAlertStatus(headline: headline, detail: detail, lines: lines)
        }
        switch (checks.registration, checks.account, checks.notifications, checks.subscriptions) {
        case (.failed, _, _, _):
            return status("Can't receive alerts", "This watch couldn't sign up for alerts. Open Malinois on the watch again later.")
        case (_, .unavailable, _, _):
            return status("iCloud unavailable", "Alerts come through iCloud. Sign in to iCloud on the iPhone this watch is paired with.")
        case (_, _, .denied, _):
            return status("Notifications are off", "Turn on notifications for Malinois in the Watch app on your iPhone.")
        case (_, _, _, .missing):
            return status("Alerts are off for this account", "Turn on Cross-device alerts in Malinois on your iPhone (Settings → iCloud).")
        case (_, _, _, .unreadable(let reason)):
            return status("Can't check alerts", "iCloud didn't answer: \(reason) Open Malinois on the watch again later.")
        case (.registered, .available, .allowed, .found):
            return status("Ready for alerts", "When Malinois detects tampering on one of your devices, the alert arrives here.")
        default:
            return status("Checking…", "Setting up alerts on this watch.")
        }
    }

    private static func lineTexts(_ checks: Checks) -> [String] {
        let signUp = switch checks.registration {
        case .pending: "waiting"
        case .registered: "done"
        case .failed: "failed"
        }
        let account = switch checks.account {
        case .unknown: "checking"
        case .available: "signed in"
        case .unavailable: "not signed in"
        }
        let notifications = switch checks.notifications {
        case .unknown: "waiting for your answer"
        case .allowed: "allowed"
        case .denied: "off"
        }
        let subscription = switch checks.subscriptions {
        case .unknown: "checking"
        case .found: "found"
        case .missing: "not found"
        case .unreadable: "couldn't check"
        }
        let link = switch checks.link {
        case .starting: "starting"
        case .ready: "ready"
        case .unavailable: "unavailable"
        }
        let lastAlert = checks.lastAlert.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "none yet"
        var lines = ["Sign-up: \(signUp)", "iCloud: \(account)", "Notifications: \(notifications)",
                     "Alert subscription: \(subscription)", "iPhone link: \(link)", "Last alert: \(lastAlert)"]
        if checks.lastAlert != nil, let source = checks.lastAlertSource {
            lines.append("Last alert came through: \(source == .iPhoneLink ? "iPhone link" : "iCloud")")
        }
        return lines
    }
}
