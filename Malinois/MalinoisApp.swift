//
//  MalinoisApp.swift
//  Malinois
//
//  App entry point. Wires up the shared services and registers for the remote
//  (CloudKit) pushes that alert the user's OTHER devices when a trip lands.
//

import SwiftUI
import OSLog
import UIKit
import UserNotifications

@main
struct MalinoisApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Shared object graph.
    @StateObject private var settings: AppSettings
    @StateObject private var eventStore: EventStore
    @StateObject private var cloud: CloudExfiltrator
    @StateObject private var camera: CameraController
    @StateObject private var entitlements: ProEntitlements
    @StateObject private var engine: MonitoringEngine

    init() {
        // iOS keeps Keychain items across app deletion, so a fresh install can inherit a PIN
        // from a previous install and skip setup. Clear that stale PIN data first, before any
        // view reads `KeychainService.hasPIN`. (The Pro trial start is kept — see the method.)
        KeychainService.wipeStalePINDataOnFreshInstall()
        // Clear clip temp files a failed store-move orphaned (disk full mid-recording). Off the
        // launch path — nothing waits on it, and it only touches files over a day old.
        Task.detached(priority: .background) { CameraController.sweepOrphanedClips() }
        let settings = AppSettings.load()
        let eventStore = EventStore()
        let cloud = CloudExfiltrator()
        let camera = CameraController()
        let entitlements = ProEntitlements()
        let engine = MonitoringEngine(settings: settings,
                                      eventStore: eventStore,
                                      cloud: cloud,
                                      camera: camera,
                                      entitlements: entitlements)
        _settings = StateObject(wrappedValue: settings)
        _eventStore = StateObject(wrappedValue: eventStore)
        _cloud = StateObject(wrappedValue: cloud)
        _camera = StateObject(wrappedValue: camera)
        _entitlements = StateObject(wrappedValue: entitlements)
        _engine = StateObject(wrappedValue: engine)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(eventStore)
                .environmentObject(cloud)
                .environmentObject(camera)
                .environmentObject(entitlements)
                .task {
                    _ = await CameraController.requestAccess()
                    await requestNotificationAuthorization()
                }
        }
    }

    private func requestNotificationAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }
}

/// Handles remote-notification registration, incoming CloudKit pushes, and notification taps.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PrivacyCover.shared.start()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Pure (unit-tested): which notifications are tamper alerts. Every CloudKit push
    /// carries the "ck" payload; the app's only other notification — the trial-end local
    /// notice — does not, and must open the app normally rather than deep-link to the log.
    nonisolated static func isTamperAlert(userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["ck"] != nil
    }

    /// A tamper alert was TAPPED: route to the Event Log — behind its existing PIN gate —
    /// because the moment the owner opens an alert is the moment they want the evidence,
    /// not Home (owner ask, 2026-08-30). The gate is unchanged: the tap saves a hop, never
    /// a credential.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if Self.isTamperAlert(userInfo: userInfo) {
            Task { @MainActor in RemotePushCoordinator.shared.onOpenEventLog?() }
        }
        completionHandler()
    }

    /// Foreground delivery: without a delegate, an alert arriving while the app is open
    /// showed nothing at all. One exception, decided async so the covert state can be read
    /// on the main actor: while a watch is live the screen is deliberately black, and a
    /// banner lighting it up would advertise the app covert mode exists to conceal — the
    /// alert stays silent there (it still reaches the owner's OTHER devices; that is the
    /// feature's whole point).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            completionHandler(PrivacyCover.shared.isCovert ? [] : [.banner, .sound, .list])
        }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // CloudKit manages the token; nothing to store client-side — but the OUTCOME is
        // health state the engine surfaces (34.H7).
        Task { @MainActor in RemotePushCoordinator.shared.registrationFailed = false }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Log-only used to be the whole story — a device that could never receive a
        // cross-device alert looked exactly like a healthy one (34.H7).
        Log.app.error("Remote notification registration failed: \(String(describing: error), privacy: .public)")
        Task { @MainActor in RemotePushCoordinator.shared.registrationFailed = true }
    }

    /// A CloudKit subscription push arrived on one of the user's other devices.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // The subscription's NotificationInfo has already surfaced the alert. Now pull the
        // record down and keep a copy here (BACKLOG 9b), so the evidence lives on a device an
        // attacker would have to compromise separately.
        //
        // The handler is called with the REAL result, after the fetch returns. It used to fire
        // `.newData` immediately, while the fetch had not begun: that reported success for work
        // that might fail, and told iOS the background work was done while it was still
        // running — leaving the system free to suspend the app mid-copy, which is the one thing
        // this push exists to prevent.
        Task { @MainActor in
            completionHandler(await RemotePushCoordinator.shared.handlePush())
        }
    }
}

/// Bridges the AppDelegate to the engine for background pushes, so the completion handler can
/// report the fetch's real outcome.
///
/// A coordinator rather than a direct reference because UIKit constructs the AppDelegate and it
/// does not own the object graph — the same boundary the previous `NotificationCenter` broadcast
/// preserved. Unlike a broadcast, this one can be awaited and can return a result.
@MainActor
final class RemotePushCoordinator {
    static let shared = RemotePushCoordinator()
    private init() {}

    /// Set by `MonitoringEngine`. Absent only before the engine exists, in which case there is
    /// nothing to fetch into and `.noData` is the honest answer.
    var onPush: (() async -> UIBackgroundFetchResult)?

    /// Set by `MonitoringEngine`: a tapped tamper alert wants the Event Log opened (behind
    /// its PIN gate). Same boundary reasoning as `onPush` — UIKit constructs the delegate
    /// and it has no handle on the engine.
    var onOpenEventLog: (() -> Void)?

    /// Whether the last APNs registration attempt failed (34.H7). The AppDelegate writes it;
    /// the engine reads it when refreshing notification health.
    var registrationFailed = false

    func handlePush() async -> UIBackgroundFetchResult {
        guard let onPush else { return .noData }
        return await onPush()
    }
}

/// Covers the whole window while the app leaves the foreground, so the snapshot iOS takes for
/// the app switcher shows this instead of whatever was on screen (BACKLOG 3).
///
/// What it protects: the event log, Settings and Test Sensors all sit behind the PIN, so the
/// PIN — not the device passcode — is the boundary around the evidence and the configuration.
/// The switcher snapshot crossed it. A card showing evidence thumbnails, a capture frame, or
/// which tripwires are armed is readable by anyone holding the unlocked phone without entering
/// anything, and those snapshots persist between launches.
///
/// Deliberately UIKit, at the window, rather than a SwiftUI overlay:
///  * Settings and Test Sensors are presented as **sheets**, which an overlay in the root view
///    does not cover — precisely the screens most worth covering.
///  * The notification handler runs synchronously before the snapshot, whereas a SwiftUI state
///    change waits for the next render pass and can lose the race.
///
/// (Lives in this file rather than its own because the project lists its sources individually,
/// so a new file needs an Xcode project edit to join the target.)
@MainActor
final class PrivacyCover {
    static let shared = PrivacyCover()

    /// Mirrors the engine's state. While a watch is live the screen is deliberately black, and
    /// putting the emblem in the app switcher would *add* information rather than hide it —
    /// the opposite of what covert mode is for. So the cover stays plain black then.
    var isCovert = false

    private var cover: UIView?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification,
                               object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PrivacyCover.shared.install() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PrivacyCover.shared.remove() }
            }
        ]
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private func install() {
        guard cover == nil, let window = keyWindow else { return }
        let view = UIView(frame: window.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.backgroundColor = isCovert ? .black : UIColor(Brand.emblemGround)

        // The emblem artwork sits on `emblemGround` already, so against that fill it reads as
        // one piece rather than a logo pasted onto a panel.
        if !isCovert, let emblem = UIImage(named: "MalinoisEmblem") {
            let image = UIImageView(image: emblem)
            image.contentMode = .scaleAspectFit
            image.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(image)
            NSLayoutConstraint.activate([
                image.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                image.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 160)
            ])
        }
        window.addSubview(view)
        cover = view
    }

    private func remove() {
        cover?.removeFromSuperview()
        cover = nil
    }
}
