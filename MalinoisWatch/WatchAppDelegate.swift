//
//  WatchAppDelegate.swift
//  MalinoisWatch
//
//  Registers the watch for the Malinois alert pushes (item 57, ADR 0042). The watch registers its
//  own device token, so an alert reaches the wrist over the watch's own connection, also when the
//  armed iPhone is the watch's own: an armed iPhone stays in the foreground and never forwards its
//  notifications to its watch. The push carries the alert's fixed text; nothing is fetched. The alerts
//  its own iPhone relays (ADR 0043) are handled by `WatchRelayInbox` (ADR 0051), which pairs each with
//  iCloud's copy of the same event; the watch's alert extension shows iCloud's (ADR 0052).
//

import CloudKit
import os
import OSLog
import UserNotifications
import WatchConnectivity
import WatchKit

/// The watch's alert readiness, shown on its screen.
@MainActor
final class WatchAlertState: ObservableObject {
    @Published var registration: WatchAlertStatus.Registration = .pending
    @Published var account: WatchAlertStatus.Account = .unknown
    @Published var notifications: WatchAlertStatus.Notifications = .unknown
    @Published var subscriptions: WatchAlertStatus.Subscriptions = .unknown
    @Published var link: WatchAlertStatus.Link = .starting
    @Published var lastAlert = UserDefaults.standard.object(forKey: WatchAppDelegate.lastAlertReceivedKey) as? Date
    @Published var lastAlertSource = UserDefaults.standard.string(forKey: WatchAppDelegate.lastAlertSourceKey)
        .flatMap(WatchAlertStatus.AlertSource.init(rawValue:))
}

@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate, WCSessionDelegate {
    let state = WatchAlertState()
    /// An error's domain and code, safe to log publicly; the description is logged privately (R1-L3,
    /// as the iPhone app's `Log.ref`).
    nonisolated static func reference(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }

    /// When the watch app last saw an alert arrive, kept on the watch for its screen.
    nonisolated static let lastAlertReceivedKey = "com.malinois.watch.lastAlertReceived"
    /// Which path brought that alert, kept beside it.
    nonisolated static let lastAlertSourceKey = "com.malinois.watch.lastAlertSource"
    private let log = Logger(subsystem: "com.johncompton.Malinois.watchkitapp", category: "alerts")
    /// Background wakes for the iPhone link, held until the delivered alerts are handled.
    private var linkTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    /// The relayed alerts' handling (ADR 0043, ADR 0051): each event once, kept across launches (the
    /// iPhone sends an alert live while the app is open and queued as well, and a copy arriving after
    /// the app restarted must not alert again); one more than an hour old joins one summary; iCloud's
    /// copy of the event in the list is paired with it (ADR 0052).
    private let relayInbox = WatchRelayInbox(
        post: { request in try await UNUserNotificationCenter.current().add(request) },
        delivered: { await WatchAppDelegate.deliveredAlerts() },
        remove: { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) })
    /// Set when the link's activation completes without activating; a held wake then ends, since
    /// nothing more can arrive (the 1.6 review's finding 6). Cleared at each new activation.
    private var activationFailed = false
    /// Relayed alerts the link has handed over but the app has not yet handled (posted on their own or
    /// in the summary, or passed over as already shown). The link reports nothing pending as soon as it
    /// has handed an alert over, so a wake is held until this is zero too (TestFlight 1.6 (60), Test 3:
    /// a wake ended in between could lose the alert).
    private let alertsInFlight = OSAllocatedUnfairLock(initialState: 0)

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        // Registration needs no permission; showing an alert does, asked for when the app opens.
        WKApplication.shared().registerForRemoteNotifications()
        activateLink()
    }

    /// The paired iPhone's own alerts come over this link (ADR 0043): iCloud never sends a watch the
    /// alerts its own iPhone causes.
    private func activateLink() {
        guard WCSession.isSupported() else { state.link = .unavailable; return }
        activationFailed = false
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// watchOS wakes the app in the background to deliver the iPhone's queued alerts. Each wake is
    /// held until nothing is left to deliver; other kinds of wake are finished at once.
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let linkTask = task as? WKWatchConnectivityRefreshBackgroundTask {
                activateLink()
                // Out of time: give the wake back rather than be ended by watchOS, which can cost
                // the app its background deliveries; an alert not yet posted is lost either way
                // (the 1.6 review's finding 6).
                linkTask.expirationHandler = { [weak self] in
                    Task { @MainActor in self?.endLinkWake(linkTask) }
                }
                linkTasks.append(linkTask)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
        finishLinkTasksIfDone()
    }

    private func finishLinkTasksIfDone() {
        let session = WCSession.default
        guard WatchAlertStatus.mayEndLinkWake(activated: session.activationState == .activated,
                                              contentPending: session.hasContentPending,
                                              alertsInFlight: alertsInFlight.withLock { $0 },
                                              activationFailed: activationFailed) else { return }
        linkTasks.forEach { $0.setTaskCompletedWithSnapshot(false) }
        linkTasks.removeAll()
    }

    /// Ends one held wake, once: its expiration handler and the rule above can both reach it.
    private func endLinkWake(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        guard let index = linkTasks.firstIndex(where: { $0 === task }) else { return }
        linkTasks.remove(at: index)
        task.setTaskCompletedWithSnapshot(false)
    }

    /// Hands a relayed alert to the inbox, which shows it on the wrist with its time, joins it to the
    /// summary, or knows it already (ADR 0051). Recorded for the screen only once something was posted
    /// (item 108, CE-03).
    private func showRelayed(_ message: WatchAlertMessage) async {
        if await relayInbox.receive(message) { recordAlert(source: .iPhoneLink) }
    }

    /// Each time the app is opened: sign up again (a token can change), read the newest delivered
    /// alert (on the watch, so it does not wait for the network), then the permission to show
    /// alerts, then the iCloud checks.
    func applicationDidBecomeActive() {
        WKApplication.shared().registerForRemoteNotifications()
        Task {
            await relayInbox.reconcile()   // iCloud's copies of alerts already shown (ADR 0052)
            await refreshLastAlert()
            await requestNotificationPermission()
            await refreshCloud()
        }
    }

    /// An alert push arrived; the system shows the alert itself, through the alert extension (ADR 0052).
    /// The push can wake the app (its remote-notification background mode; whether and when is up to
    /// watchOS): recorded for the screen, then iCloud's copies of events already handled leave the list,
    /// which keeps the relayed copies, with their times. The tidy-up's read of the list has a deadline, so
    /// the wake ends in time.
    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any],
                                      fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void) {
        recordAlert(source: .iCloud)
        Task {
            await relayInbox.reconcile()
            completionHandler(.newData)
        }
    }

    /// The watch's notification list, as the pairing reads it (ADR 0052).
    static func deliveredAlerts() async -> [WatchAlertPairing.Delivered] {
        await UNUserNotificationCenter.current().deliveredNotifications().map {
            WatchAlertPairing.Delivered(identifier: $0.request.identifier, content: $0.request.content)
        }
    }

    private func recordAlert(at date: Date = Date(), source: WatchAlertStatus.AlertSource) {
        UserDefaults.standard.set(date, forKey: Self.lastAlertReceivedKey)
        UserDefaults.standard.set(source.rawValue, forKey: Self.lastAlertSourceKey)
        state.lastAlert = date
        state.lastAlertSource = source
    }

    /// When the app opens: the newest alert still in the watch's notification list and the path
    /// that brought it, since an alert iCloud delivers in the background never wakes the app. One
    /// older than the alert already recorded changes nothing.
    private func refreshLastAlert() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        guard let newest = delivered.max(by: { $0.date < $1.date }),
              newest.date > (state.lastAlert ?? .distantPast) else { return }
        recordAlert(at: newest.date, source: WatchAlertStatus.source(ofNotification: newest.request.identifier))
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        log.info("Registered for alert pushes")
        state.registration = .registered
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        log.error("Alert push registration failed: \(Self.reference(error), privacy: .public) \(error, privacy: .private)")
        state.registration = .failed
    }

    /// Asks for permission to show alerts. A one-iPhone owner's armed iPhone never receives an
    /// alert, so the iPhone app may never have asked; an answer already given returns at once,
    /// without a prompt.
    private func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        state.notifications = granted ? .allowed : .denied
    }

    /// The iCloud account the alerts come through, then the account's subscriptions: the watch's one
    /// server call, which reads no event records and says whether the tamper alert is set up.
    private func refreshCloud() async {
        let container = CKContainer(identifier: "iCloud.com.johncompton.Malinois")
        switch try? await container.accountStatus() {
        case .available: state.account = .available
        case .noAccount, .restricted: state.account = .unavailable
        default: state.account = .unknown
        }
        do {
            let subscriptions = try await container.privateCloudDatabase.allSubscriptions()
            let found = subscriptions.contains { $0.subscriptionID == WatchAlertStatus.tamperSubscriptionID }
            state.subscriptions = found ? .found : .missing
        } catch {
            log.error("Subscription check failed: \(Self.reference(error), privacy: .public) \(error, privacy: .private)")
            state.subscriptions = .unreadable(error.localizedDescription)
        }
    }

    /// An alert arriving while the app is open still shows, and is recorded; the summary's quiet
    /// updates are listed only (ADR 0051).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        Task { @MainActor in self.recordAlert(source: WatchAlertStatus.source(ofNotification: identifier)) }
        completionHandler(WatchRelayInbox.presentationOptions(for: notification.request.content))
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let ready = activationState == .activated && session.isCompanionAppInstalled
        let failed = activationState != .activated
        Task { @MainActor in
            self.state.link = ready ? .ready : .unavailable
            self.activationFailed = failed
            self.finishLinkTasksIfDone()
        }
    }

    /// A queued alert from the paired iPhone, delivered in the background or at launch. Counted
    /// before this returns, since the link reports nothing pending once it has handed the alert
    /// over, and uncounted once posted, so the wake lasts until the alert is shown.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let message = WatchAlertMessage(userInfo: userInfo)
        if message != nil { alertsInFlight.withLock { $0 += 1 } }
        Task { @MainActor in
            if let message {
                await self.showRelayed(message)
                self.alertsInFlight.withLock { $0 -= 1 }
            }
            self.finishLinkTasksIfDone()
        }
    }

    /// The same alert sent at once while the watch app is open.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let alert = WatchAlertMessage(userInfo: message)
        Task { @MainActor in
            if let alert { await self.showRelayed(alert) }
        }
    }

    /// An alert opened from the watch face is recorded too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        Task { @MainActor in self.recordAlert(source: WatchAlertStatus.source(ofNotification: identifier)) }
        completionHandler()
    }
}
