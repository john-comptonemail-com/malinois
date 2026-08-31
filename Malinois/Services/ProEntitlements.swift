//
//  ProEntitlements.swift
//  Malinois
//
//  Monetization gate: a one-time non-consumable "Pro" unlock ($9.99), preceded by a
//  30-day full-Pro trial that STARTS ON FIRST LAUNCH. With a trial this generous, starting at
//  launch keeps the whole pre-arm experience coherent — the user is simply "in trial" rather
//  than in a confusing half-locked free state — and the trial can be bought at any point
//  during it. `proActive` is the single boolean the rest of the app consults; the
//  `AppSettings` extension at the bottom turns it into the
//  "effective" (Pro-aware) config used at arm time — the "store intent, clamp at use" rule
//  from the paywall spec, so a lapsed trial never destroys the user's saved preferences.
//
//  Guiding invariant (mirrors the app's degraded-state handling elsewhere): the paywall
//  NEVER silently reduces protection. Core detection + on-device capture are always free;
//  only whether evidence survives (cloud), travels (cross-device), and is richer (multi-cam,
//  longer clips, audio sensor) is gated — and every downgrade is surfaced by the UI.
//

import Foundation
import StoreKit
import UserNotifications

/// The Pro capabilities — all unlocked together by the single purchase. Used for messaging
/// and to lead the paywall with whichever feature the user tapped (no per-feature purchases).
enum ProFeature { case cloudBackup, crossDevicePush, multiCam, extendedVideo, audioSensor, visionSensor }

@MainActor
final class ProEntitlements: ObservableObject {

    static let productID = "com.johncompton.Malinois.pro"
    // `nonisolated` so it can be the default argument of the `nonisolated` `trialActive`
    // (a default arg is evaluated in a nonisolated context); an immutable Sendable Int is
    // safe to expose that way. Without this, Swift 6 language mode errors on the reference.
    nonisolated static let trialDays = 30

    enum Status: Equatable { case free, trial, pro }

    @Published private(set) var status: Status = .free
    /// Whether `refresh()` has completed at least once.
    ///
    /// `status` starts at `.free`, which is the safe default for *capability* — nothing is
    /// unlocked until entitlement is proven — but it is NOT a safe default for *messaging*.
    /// Until the first refresh lands, `.free` means "not checked yet", and reading it as
    /// "this user has no entitlement" tells an in-trial owner their protection has lapsed.
    @Published private(set) var hasResolved = false
    @Published private(set) var product: Product?
    @Published private(set) var purchaseInFlight = false

    /// The single gate the rest of the app consults.
    var proActive: Bool { status != .free }

    /// The trial ran its course and has now lapsed — drives the "trial ended, device still
    /// protected" Home banner. Since the trial starts at first launch, a *resolved* `.free`
    /// with a recorded start always means a used-up trial, never a pre-trial install.
    ///
    /// The `hasResolved` term is the whole point: without it, every launch claimed the trial
    /// had ended for the entire window between construction and the first StoreKit round trip
    /// — visible on TestFlight as an orange "Pro trial ended" banner and a $9.99 upsell,
    /// flashed at an owner whose trial was days from expiry. The paywall invariant is that it
    /// never silently *reduces* protection; announcing a downgrade that hasn't happened is the
    /// same failure wearing the other face.
    var trialEnded: Bool {
        Self.trialHasEnded(status: status, hasTrialStart: Self.storedTrialStart != nil,
                           hasResolved: hasResolved)
    }

    /// Pure form of `trialEnded`, so the launch-window case is covered by a test rather than
    /// by having someone notice a flash on a real device.
    nonisolated static func trialHasEnded(status: Status, hasTrialStart: Bool,
                                          hasResolved: Bool) -> Bool {
        guard hasResolved else { return false }
        return status == .free && hasTrialStart
    }

    /// Whole days left in the trial (nil unless a trial is currently active) — for the
    /// "N days of Pro left" messaging.
    var trialDaysRemaining: Int? {
        guard status == .trial, let start = Self.storedTrialStart else { return nil }
        let end = start.addingTimeInterval(Double(Self.trialDays) * 86_400)
        let secs = end.timeIntervalSince(Date())
        return secs > 0 ? Int((secs / 86_400).rounded(.up)) : 0
    }

    private var updatesTask: Task<Void, Never>?

    init() {
        #if DEBUG
        // Test hook: `MALINOIS_TRIAL_DAYS_AGO=<n>` (Xcode scheme → Run → Environment
        // Variables) backdates the trial start by n days for THIS launch only, so the trial
        // lifecycle — near-expiry banner (e.g. 28), expiry → free downgrade + free-tier
        // messaging (e.g. 31) — is testable instantly, with no 30-day wait and no disruptive
        // device-clock change. Non-persistent: never written to the Keychain/UserDefaults
        // store, so clearing the variable restores the real trial.
        if let raw = ProcessInfo.processInfo.environment["MALINOIS_TRIAL_DAYS_AGO"],
           let days = Double(raw) {
            Self.debugTrialStartOverride = Date().addingTimeInterval(-days * 86_400)
        }
        #endif
        updatesTask = listenForTransactions()
        Task { await refresh() }
    }

    /// A pre-resolved instance, for tests that need a known entitlement rather than a race.
    ///
    /// The ordinary `init()` starts a StoreKit listener and an async refresh, so a freshly
    /// constructed instance is unresolved — which is correct, and which now blocks arming
    /// (see `MonitoringEngine.armingBlockedByEntitlementCheck`). Tests of the arming flow are
    /// not testing StoreKit and should not be waiting on it. Nothing in the app calls this.
    init(resolvedAs status: Status) {
        self.status = status
        self.hasResolved = true
    }

    /// An UNRESOLVED instance whose resolution moment the test drives by hand — for tests of
    /// the launch window itself (the fifth review's round-3 finding lives entirely inside it).
    /// The ordinary `init()` starts StoreKit resolving immediately, so the window such a test
    /// needs to hold open would close on StoreKit's schedule, not the test's. Nothing in the
    /// app calls this.
    static func unresolvedForTesting() -> ProEntitlements {
        let entitlements = ProEntitlements(resolvedAs: .free)
        entitlements.hasResolved = false
        return entitlements
    }

    /// Completes the entitlement check by hand — `refresh()`'s observable effect (status
    /// known, `hasResolved` flipped) without StoreKit. Test-only, like the initializers above.
    func resolveForTesting(as newStatus: Status) {
        status = newStatus
        hasResolved = true
    }

    deinit { updatesTask?.cancel() }

    // MARK: - Public API

    /// Load product metadata for the paywall sheet.
    func loadProduct() async {
        product = try? await Product.products(for: [Self.productID]).first
    }

    /// Recompute `status` from the current entitlement + trial window. Safe offline —
    /// `Transaction.currentEntitlements` is served from StoreKit's on-device cache, so a
    /// paid user is never locked out for lack of a network. Also *starts* the 30-day trial
    /// the first time the app is launched (see `storedTrialStart`), so the whole pre-arm
    /// experience is simply "in trial" rather than a confusing half-locked free state.
    /// `hasResolved` is set the moment **status** is known — deliberately before
    /// `loadProduct()`, which is a network call to the App Store.
    ///
    /// It used to be a `defer` at the top of this function, so it only fired once product
    /// metadata had loaded too. That was harmless while it only drove a banner, and became a
    /// hazard the moment arming started waiting on it: a slow or unreachable App Store would
    /// have blocked the owner from protecting their device. Entitlement itself is a local
    /// question — `Transaction.currentEntitlements` is served from StoreKit's on-device cache —
    /// so resolution stays prompt and offline-safe.
    func refresh() async {
        if await hasPurchasedEntitlement() {
            status = .pro
            hasResolved = true
            cancelTrialEndNotification()      // bought → no "trial ended" reminder
            if product == nil { await loadProduct() }
            return
        }
        // Begin the trial on first launch (idempotent — recorded once, survives reinstall).
        if Self.storedTrialStart == nil { Self.storedTrialStart = Date() }
        let start = Self.storedTrialStart ?? Date()
        if Self.trialActive(start: start, now: Date()) {
            status = .trial
            scheduleTrialEndNotification(start: start)
        } else {
            status = .free
            cancelTrialEndNotification()
        }
        hasResolved = true
        if product == nil { await loadProduct() }
    }

    /// Purchase the one-time unlock. Returns true once Pro is active.
    @discardableResult
    func purchase() async -> Bool {
        if product == nil { await loadProduct() }
        guard let product else { return false }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { return false }
                await transaction.finish()
                await refresh()
                return status == .pro
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            return false
        }
    }

    /// Backs the required "Restore Purchases" button. StoreKit 2 restores automatically via
    /// `currentEntitlements`; `AppStore.sync()` forces a refresh from the App Store.
    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }

    // MARK: - Trial-end notification

    private static let trialEndNotifID = "com.malinois.trial.ended"

    /// Schedules the one-time local notice for when the trial lapses, so the user learns
    /// their protection was reduced even if they're not in the app (paywall spec §6). Uses a
    /// fixed identifier, so re-running each launch just refreshes the pending request. The
    /// app already requests notification authorization at launch.
    private func scheduleTrialEndNotification(start: Date) {
        let secondsUntilEnd = start.addingTimeInterval(Double(Self.trialDays) * 86_400).timeIntervalSinceNow
        guard secondsUntilEnd > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Malinois Pro trial ended"
        content.body = "Your device is still protected. Local detection and evidence keep working — cloud backup and cross-device alerts are off. Upgrade to restore them."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secondsUntilEnd, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.trialEndNotifID, content: content, trigger: trigger))
    }

    private func cancelTrialEndNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.trialEndNotifID])
    }

    // MARK: - Pure trial math (unit-tested)

    /// Is the trial window currently open? `nonisolated` so tests can call it off the main
    /// actor (a `@MainActor` static would be unreachable from a synchronous test context).
    nonisolated static func trialActive(start: Date?, now: Date, days: Int = trialDays) -> Bool {
        guard let start else { return false }
        // Fail toward the user if the device clock was moved backward past the start:
        // treat the trial as still active rather than expiring it early.
        guard now > start else { return true }
        return now.timeIntervalSince(start) < Double(days) * 86_400
    }

    // MARK: - Entitlement lookup

    private func hasPurchasedEntitlement() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil {
                return true
            }
        }
        return false
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let t) = update { await t.finish() }
                await self?.refresh()
            }
        }
    }

    // MARK: - Trial-start persistence

    // The Keychain is the primary store: it survives app deletion (a reinstall can't farm a
    // fresh trial) and needs no iCloud/KVS entitlement. A UserDefaults mirror serves the fast
    // first read and any build where the Keychain is unavailable. NOTE: unlike iCloud KVS this
    // does not sync across the user's devices, which is fine — a per-device trial is not abuse.
    private static let trialStartKey = "com.malinois.trial.start"

    #if DEBUG
    /// Debug/test-only, in-memory, non-persistent override for the trial start
    /// (set from `MALINOIS_TRIAL_DAYS_AGO` — see `init`). Takes precedence over the stored
    /// value so the whole trial lifecycle can be exercised on demand.
    static var debugTrialStartOverride: Date?
    #endif

    static var storedTrialStart: Date? {
        get {
            #if DEBUG
            if let override = debugTrialStartOverride { return override }
            #endif
            if let fromKeychain = KeychainService.trialStart { return fromKeychain }
            let local = UserDefaults.standard.double(forKey: trialStartKey)
            return local > 0 ? Date(timeIntervalSince1970: local) : nil
        }
        set {
            guard let newValue else { return }   // one-way: a trial start is never cleared
            KeychainService.setTrialStart(newValue)                                   // survives reinstall
            UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: trialStartKey)  // fast/offline mirror
        }
    }
}

// MARK: - Pro gating: effective (Pro-aware) settings

/// "Store intent, clamp at use." These read the user's SAVED preferences and clamp the
/// Pro-only ones when Pro isn't active, without mutating what's stored — so upgrading later
/// restores the user's real choices. The engine reads these `effective…` values at arm time
/// instead of the raw settings. The `static` forms are pure and unit-tested.
extension AppSettings {

    /// Audio and vision are the Pro *tripwires*; everything else (motion/touch/power/proximity)
    /// stays free so the free tier still detects the primary threats.
    static func effectiveSensors(_ enabled: Set<SensorType>, pro: Bool) -> Set<SensorType> {
        pro ? enabled : enabled.subtracting(SensorType.proTripwires)
    }

    /// Multi-cam ("Both") is Pro; free clamps to the front camera.
    static func effectiveCamera(_ choice: CameraChoice, pro: Bool) -> CameraChoice {
        (pro || choice != .both) ? choice : .front
    }

    /// Longer video (5s / until-clear) is Pro; free clamps to the 3s clip. Photo stays photo.
    static func effectiveCapture(_ mode: CaptureMode, pro: Bool) -> CaptureMode {
        guard !pro else { return mode }
        return (mode == .clip5 || mode == .untilClear) ? .clip3 : mode
    }

    func effectiveEnabledSensors(pro: Bool) -> Set<SensorType> { Self.effectiveSensors(enabledSensors, pro: pro) }
    func effectiveCameraPosition(pro: Bool) -> CameraChoice { Self.effectiveCamera(cameraPosition, pro: pro) }
    func effectiveCaptureMode(pro: Bool) -> CaptureMode { Self.effectiveCapture(captureMode, pro: pro) }

    /// Cloud backup and cross-device push are Pro-only.
    func cloudEnabled(pro: Bool) -> Bool { pro }
    func notifyOtherDevicesEffective(pro: Bool) -> Bool { pro && notifyOtherDevices }

    /// Pro-aware version of `hasActiveTripwire`: with the audio sensor Pro-locked, a free user
    /// whose only enabled tripwire is audio has NO effective tripwire and must be warned.
    func hasActiveTripwire(pro: Bool) -> Bool {
        !SensorType.tripwires.filter { effectiveEnabledSensors(pro: pro).contains($0) }.isEmpty
    }
}
