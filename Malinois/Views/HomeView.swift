//
//  HomeView.swift
//  Malinois
//
//  The disarmed home. Big Arm control, iCloud status, a quick trigger-mode
//  toggle, and PIN-gated access to the event log and settings.
//

import StoreKit
import SwiftUI

struct HomeView: View {
    /// Home's orange line while what this installation records stays on this iPhone until it verifies iCloud access:
    /// before its first verification, or after another account was seen (item 140 pins its words).
    /// Said when the crash-loop guard declined an automatic re-arm (fable-3 on Fable's review of 75; item 132).
    static let reArmSkippedNotice = "Not re-armed automatically: Malinois was closed again within 90 seconds of re-arming "
        + "itself. Arm it again when you're ready."
    static let iCloudPausedNotice = "iCloud is paused. Verify iCloud access in Settings to back up new events; Malinois won't upload events recorded before then."
    /// The iCloud row while a verified installation waits for iCloud, offline or after a relaunch: what it records
    /// uploads once iCloud names the verified account again (item 140's codex-1).
    static let iCloudWaitingRow = "Waiting for iCloud"

    /// The iCloud row's words on Pro with iCloud backup on: iOS's account state, or, while iOS reports an account but
    /// this installation's access is not current, whether new events wait for the verified account (`newEventsBound`,
    /// `CloudEnrollment.newEventsBindToVerifiedAccount`) or a verification is needed.
    static func iCloudRow(_ account: CloudExfiltrator.AccountState, verified: Bool, newEventsBound: Bool) -> String {
        guard account.isReady, !verified else { return account.displayName }
        return newEventsBound ? iCloudWaitingRow : "iCloud verification needed"
    }

    /// Home's orange iCloud line, or nil for none (item 140's codex-1): on Pro, with iCloud backup on (off, the
    /// backup-off line says new events stay here), in a build with iCloud, while this installation's access is not
    /// current and new events are tied to no verified account (`newEventsBound` false): only a verification helps.
    static func iCloudPauseLine(proActive: Bool, backupOn: Bool, verified: Bool, newEventsBound: Bool,
                                cloudUnavailable: Bool) -> String? {
        guard proActive, backupOn, !verified, !newEventsBound, !cloudUnavailable else { return nil }
        return iCloudPausedNotice
    }

    @EnvironmentObject private var engine: MonitoringEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var cloud: CloudExfiltrator
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var entitlements: ProEntitlements
    @ObservedObject private var enrollment = CloudEnrollment.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview   // Apple's rating request (item 137)
    @Environment(\.dynamicTypeSize) private var typeSize

    /// PIN-gated areas: the event log, Settings and Test Sensors, and the ARM tap when the PIN
    /// has not been entered correctly for 14 days (ADR 0054).
    enum Gate: Identifiable {
        case log, settings, test, arm
        var id: Int {
            switch self { case .log: 0; case .settings: 1; case .test: 2; case .arm: 3 }
        }
        var prompt: String {
            switch self {
            case .log:      "Enter PIN to view log"
            case .settings: "Enter PIN for Settings"
            case .test:     "Enter PIN to test sensors"
            case .arm:      "Enter PIN to arm"
            }
        }
        /// Which gates may ALSO open by Face ID when the owner opts in (item 30 option A,
        /// narrowed by eighth-review M1): the log and Test Sensors are READ surfaces;
        /// Settings is a WRITE surface — a presented face could disable every tripwire,
        /// switch to Stealth, kill cross-device alerts, and purge cloud media — so it
        /// stays PIN-only, and SECURITY.md's "read surfaces" boundary is true word for word.
        var allowsBiometrics: Bool {
            switch self {
            case .log, .test: true
            case .settings, .arm: false
            }
        }
    }

    /// Pure (unit-tested; ADR 0054): the gate the ARM tap's outcome opens, if any: the PIN pad when the engine asks for
    /// the PIN first (`MonitoringEngine.armTapped`), otherwise none, the arming having begun.
    static func armTapGate(_ outcome: MonitoringEngine.ArmTapOutcome) -> Gate? { outcome == .askForPIN ? .arm : nil }

    /// Pure (unit-tested; item 137, ADR 0058): whether Home makes Apple's rating request now. Only when a calm disarm has
    /// Home's offer of notifications for cross-device alerts (item 69).
    static let notificationAskLine = "Cross-device alerts need notifications on this device. You can also allow it later in Settings → iCloud."

    /// asked for it (`MonitoringEngine.ratingRequestPending`), with no PIN pad up and Guided Access off; otherwise it
    /// waits for the next chance on Home.
    static func mayAskForRating(pending: Bool, pinGateOpen: Bool, guidedAccessOn: Bool) -> Bool {
        pending && !pinGateOpen && !guidedAccessOn
    }

    @State private var pinGate: Gate?      // PIN prompt currently showing
    @State private var unlocked: Gate?     // area to open once the PIN clears
    @State private var showSettings = false
    @State private var showLog = false
    @State private var showTest = false
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                wordmark

                // Item 82: scrolls when taller than the room between the wordmark and the buttons
                // (the iPhone Duo's outer display, an iPhone SE, large text) instead of squeezing
                // the notices to one line each. Where it fits, the frame centres it between them,
                // where the two spacers kept it; scrolling, it adds no height of its own. At the
                // accessibility text sizes the buttons are its last part (item 119, `bottomButtons`).
                VStack(spacing: 18) {
                    statusBadge

                    Button(action: armTapped) {
                        VStack(spacing: 6) {
                            Image("MalinoisEmblem")
                                .resizable()
                                .scaledToFit()
                                .frame(height: 118)
                            Text("ARM")
                                .font(.largeTitle.weight(.bold))
                                .tracking(4)
                                .foregroundStyle(Brand.blueDeep)   // matches the logo blue on the dark ground
                        }
                        .frame(width: 220, height: 220)
                        .background(
                            Circle().fill(Brand.emblemGround)
                                .overlay(Circle().strokeBorder(Brand.blue, lineWidth: 3))
                        )
                    }
                    .buttonStyle(.plain)
                    // Arming is held until the entitlement check completes, so a session can't be
                    // snapshotted as free-tier while StoreKit is still answering. The wait is a
                    // local cache read, and the status row above says "Checking Pro status…"
                    // throughout — a visible pause rather than a silently degraded watch.
                    .disabled(engine.armingBlockedByEntitlementCheck)
                    .opacity(engine.armingBlockedByEntitlementCheck ? 0.5 : 1)

                    // PIN-gated like the log and Settings: the test view lists exactly which
                    // tripwires are enabled and shows their live thresholds, which is the same
                    // reconnaissance the Settings gate exists to deny.
                    Button {
                        pinGate = .test
                    } label: {
                        Label("Test sensors", systemImage: "dot.radiowaves.left.and.right")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if typeSize.isAccessibilitySize { bottomButtons }
                }
                .frame(maxHeight: .infinity)
                .scrollingIfNeeded()

                if !typeSize.isAccessibilitySize { bottomButtons }
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $pinGate, onDismiss: openUnlocked) { gate in
                PINEntryView(title: gate.prompt, allowBiometrics: gate.allowsBiometrics) {
                    unlocked = gate     // open it after the PIN cover dismisses
                    pinGate = nil
                } onCancel: {
                    pinGate = nil
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { engine.recordProtectionChanges() },   // item 91
                   content: { SettingsView() })
            .sheet(isPresented: $showTest) { DryRunView() }
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .navigationDestination(isPresented: eventLogPresentation) { EventLogView() }
            .task { await cloud.refreshAccountState() }
            // A PIN-opened area must not outlive the foreground session. Without this the gate
            // is first-open only: unlock the log, background the app for an hour, come back,
            // and it is still open with no PIN asked — a formality for anyone who picks the
            // phone up after the owner used it.
            //
            // `.background`, not `.inactive`: the latter fires for Control Centre, the
            // notification shade and incoming-call banners, and slamming the log shut for a
            // glance at a notification would train the owner to stop using it. The app-switcher
            // cover handles those transient cases — it is a different job with a different hook.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                eventLogPresentation.wrappedValue = false
                showSettings = false
                showTest = false
                pinGate = nil
                unlocked = nil
            }
            // A tapped tamper alert deep-links here (behind the same PIN gate as the log
            // button — the tap saves a hop, never a credential). Both hooks are needed: the
            // cold-launch tap sets the flag before Home exists (`onAppear` picks it up), and
            // a tap while Home is already showing arrives as a change.
            .onChange(of: engine.eventLogOpenRequested) { _, requested in
                if requested { openLogFromNotification() }
            }
            .onAppear {
                if engine.eventLogOpenRequested { openLogFromNotification() }
                Task { await engine.refreshNotificationHealth() }   // a pull-to-refresh or Settings may have changed the picture (item 69)
                askForRatingIfDue()
            }
            // Apple's rating request after a calm disarm (item 137): when Home is back, or once Guided Access ends or
            // the PIN pad closes, whichever comes last.
            .onChange(of: engine.ratingRequestPending) { _, _ in askForRatingIfDue() }
            .onChange(of: engine.guidedAccessEnabled) { _, _ in askForRatingIfDue() }
            .onChange(of: pinGate) { _, _ in askForRatingIfDue() }
        }
    }

    /// Apple's rating request at a calm moment (item 137, ADR 0058): iOS decides whether to show it.
    private func askForRatingIfDue() {
        guard Self.mayAskForRating(pending: engine.ratingRequestPending, pinGateOpen: pinGate != nil,
                                   guidedAccessOn: engine.guidedAccessEnabled) else { return }
        engine.ratingRequestHandled()
        requestReview()
    }

    /// The ARM tap: the engine decides (ADR 0054; item 162's G1). After 14 days without a correct PIN, or with none on
    /// record, the PIN first, Cancel staying on Home; otherwise the camera question when due, then the arming screen.
    private func armTapped() {
        if let gate = Self.armTapGate(engine.armTapped()) { pinGate = gate }
    }

    /// A tapped tamper alert wants the log: consume the request and act on it in EVERY
    /// branch (eighth review, L8 — the old order consumed first and then dropped the
    /// request if any PIN gate happened to be up, losing the one notification the owner
    /// most wants). Already-open log: nothing to do. A different gate mid-prompt: retarget
    /// it to the log — the tapped alert's intent wins; the PIN still gates as always.
    private func openLogFromNotification() {
        engine.consumeEventLogOpenRequest()
        guard !showLog else { return }
        pinGate = .log
    }

    private var eventLogPresentation: Binding<Bool> {
        Self.eventLogPresentation($showLog, store: eventStore)
    }

    /// A real log transition acknowledges the current records BEFORE navigation
    /// publishes its new state. Opening is reached only after authentication; Back
    /// and backgrounding close the same visit. Redundant closes (including a cancelled
    /// PIN prompt) cannot acknowledge events that arrived after the visit ended.
    @MainActor
    static func eventLogPresentation(_ destination: Binding<Bool>, store: EventStore) -> Binding<Bool> {
        Binding(get: { destination.wrappedValue }, set: { presented in
            guard presented != destination.wrappedValue else { return }
            store.markAllSeen()
            destination.wrappedValue = presented
        })
    }

    /// Opens the area unlocked by a successful PIN, once the prompt has dismissed.
    private func openUnlocked() {
        guard let dest = unlocked else { return }
        unlocked = nil
        switch dest {
        case .log:      eventLogPresentation.wrappedValue = true
        case .settings: showSettings = true
        case .test:     showTest = true
        case .arm:      engine.armAfterPINCheck()   // the PIN was remembered: on to the arming screen (ADR 0054)
        }
    }

    /// "Event Log (3 new)": the records new since the owner last opened the log (item 81;
    /// arm/disarm and the other state records never count), hidden at 0. It shows without the
    /// PIN, a glanceability trade: it reveals how many, never what, and only opening the
    /// PIN-gated log clears it. A convenience, not a tamper-evidence guarantee: it's the local
    /// count, which an iCloud-only attacker doesn't change (BACKLOG 9a/10).
    private var eventLogTitle: String { Self.eventLogTitle(newCount: eventStore.newRecordCount) }

    /// Pure (unit-tested; item 81): the button's words.
    nonisolated static func eventLogTitle(newCount: Int) -> String {
        newCount > 0 ? "Event Log (\(newCount) new)" : "Event Log"
    }

    /// The Event Log and Settings buttons (item 119). Below the part of Home that scrolls they sit side
    /// by side. At the accessibility text sizes, half the width each, their names broke into a few
    /// letters a line ("E / v / …"), so there they stack, each the full width with its name whole, at
    /// the end of the part that scrolls: pinned below it, stacked, they left it a window a few lines
    /// tall, with ARM out of sight (BACKLOG 128).
    private var bottomButtons: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            Button {
                pinGate = .log
            } label: {
                Label { Text(eventLogTitle).fixedSize(horizontal: false, vertical: true).reportedOnScreen(eventLogTitle) }
                      icon: { Image(systemName: "list.bullet.rectangle") }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                pinGate = .settings
            } label: {
                Label { Text("Settings").fixedSize(horizontal: false, vertical: true).reportedOnScreen("Settings") }
                      icon: { Image(systemName: "gearshape") }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
    }

    /// "Last armed 2:15 PM – 3:42 PM · 1:23:45" when the wall-clock window is known;
    /// falls back to duration-only for a session recorded before the interval was tracked.
    private func lastArmedText(duration: TimeInterval, interval: (start: Date, end: Date)?) -> String {
        guard let interval else { return "Last armed for \(duration.clockString)" }
        let hm = Date.FormatStyle.dateTime.hour().minute()
        return "Last armed \(interval.start.formatted(hm)) – \(interval.end.formatted(hm)) · \(duration.clockString)"
    }

    private var wordmark: some View {
        MalinoisLockup()
    }

    private var statusBadge: some View {
        VStack(spacing: 6) {
            Text("DISARMED")
                .font(.headline)
                .foregroundStyle(.secondary)
            // Cloud backup is Pro. Only show real iCloud account status when it's actually in
            // use; on the free tier say so plainly instead of a green "iCloud ready" the free
            // user never benefits from (P-05).
            if !entitlements.hasResolved {
                // Same discipline as the iCloud row's own "Checking iCloud…": say we don't
                // know yet rather than guessing a tier and correcting it a moment later.
                statusRow(ready: false, text: "Checking Pro status…")
            } else if entitlements.proActive, !settings.cloudBackup {
                // Item 120, F1: with iCloud backup off Malinois uploads nothing new, and the
                // green "iCloud ready" said the opposite. The arming screens say it too.
                Label(MonitoringEngine.backupOffNotice, systemImage: "icloud.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .reportedOnScreen(MonitoringEngine.backupOffNotice)
            } else if entitlements.proActive {
                statusRow(ready: cloud.accountState.isReady && enrollment.verified,
                          text: Self.iCloudRow(cloud.accountState, verified: enrollment.verified,
                                               newEventsBound: enrollment.newEventsBindToVerifiedAccount))
            } else {
                // What Malinois does, not where the evidence stays: the iPhone's own backups can copy it (item 168's deepseek-2).
                statusRow(ready: false, text: "iCloud backup is Pro - Malinois uploads no evidence")
            }
            statusRow(ready: engine.guidedAccessEnabled,
                      text: engine.guidedAccessEnabled ? "Guided Access ready" : "Guided Access off")
            if let last = engine.lastArmedDuration {
                Label(lastArmedText(duration: last, interval: engine.lastArmedInterval),
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let notice = engine.cameraNotice {
                Label(notice, systemImage: "video.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if let notice = engine.audioNotice {
                Label(notice, systemImage: "mic.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if let notice = engine.sirenNotice {
                Label(notice, systemImage: "speaker.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if let notice = engine.notificationNotice {
                Label(notice, systemImage: "bell.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            // Never under Guided Access, where iOS shows no permission question (ADR 0011: the camera's blocked
            // question was taken as a refusal; Codex's note on 1.8.2): the line waits until it ends.
            if engine.notificationAskDue && !engine.guidedAccessEnabled {
                // Asked here, in context, on the device that would show the alert — and only
                // once another device's evidence has arrived in this log (item 69) or this
                // installation is verified for iCloud (item 155's A11). Hide keeps it out of
                // the way; Settings → iCloud carries the same ask.
                VStack(spacing: 4) {
                    Label(Self.notificationAskLine, systemImage: "bell.badge")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .reportedOnScreen(Self.notificationAskLine)
                    HStack(spacing: 10) {
                        Button("Allow notifications") {
                            Task {
                                await NotificationPermission.requestIfUndetermined()
                                await engine.refreshNotificationHealth()
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Hide") { engine.hideNotificationAsk() }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal)
            }
            if engine.recoveredInterruptedSession {
                Label("Recovered an interrupted armed session - re-syncing any pending evidence.",
                      systemImage: "arrow.clockwise.icloud")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if engine.reArmSkipped {   // fable-3: the crash-loop guard declined the automatic re-arm
                Label(Self.reArmSkippedNotice, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .reportedOnScreen(Self.reArmSkippedNotice)
            }
            if engine.cloudRestoreInProgress {
                // The launch pull (owner, 2026-09-04): while it runs, an empty log is "loading".
                // It says "Restoring" only for a real restore, otherwise "Checking" (2026-10-11).
                Label(engine.currentLaunchPull.homeLabel, systemImage: "icloud.and.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if !engine.isOnline && entitlements.proActive {
                // Only meaningful when cloud backup is in use; a free user's evidence stays
                // on-device regardless of connectivity, so this would be misleading (P-05).
                Label("Offline - captured evidence can't upload until you reconnect.",
                      systemImage: "wifi.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if !settings.hasActiveTripwire(pro: entitlements.proActive) {
                // Two ways to have no *effective* tripwire: none enabled at all, or (free tier)
                // the only one enabled is the Pro-locked audio sensor — which needs its own
                // honest message rather than "turn one on" when one already is (P-04).
                Label(settings.hasActiveTripwire
                      ? "Your only enabled tripwire is audio, which is Pro - enable a free tripwire in Settings or upgrade, or nothing will trigger."
                      : "No tripwires enabled - nothing will trigger. Turn one on in Settings.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            // The defaults include PIN-pad scrambling off and the Sound and Vision tripwires off,
            // so a settings reset the owner didn't ask for can reduce protection.
            // It has to be said, not just logged.
            if AppSettings.loadWasReset {
                Label("Your settings couldn't be read and have been reset to defaults. Check Settings before arming - tripwires and Guided Access enforcement may not be as you left them.",
                      systemImage: "gear.badge.xmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if eventStore.loadFailed {
                Label("The event log couldn't be read and new events aren't being saved locally. Reinstalling will reset it.",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if eventStore.persistDegraded {
                Label("New events aren't being saved to this device - storage may be full. Anything already uploaded to iCloud is unaffected.",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if eventStore.logWasQuarantined {
                Label("The event log couldn't be read and was set aside as a backup - new events go to a fresh log.",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if eventStore.journalDegraded {
                Label("Recent events may not survive a crash - the event journal can't be written. The log itself is saving normally.",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if let notice = engine.cloudResetNotice {
                Label(notice, systemImage: "icloud.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if engine.cloudPushRefused {
                Label("iCloud refused an evidence upload - evidence is kept on this device and will retry. Check your iCloud storage.",
                      systemImage: "icloud.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if let line = Self.iCloudPauseLine(proActive: entitlements.proActive, backupOn: settings.cloudBackup,
                                               verified: enrollment.verified,
                                               newEventsBound: enrollment.newEventsBindToVerifiedAccount,
                                               cloudUnavailable: cloud.cloudUnavailable) {
                Label(line, systemImage: "icloud.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .reportedOnScreen(line)
            }
            if cloud.cloudUnavailable {
                Label("iCloud backup isn't available in this build - evidence is kept on-device only. A signed build with an iCloud container restores off-device sync.",
                      systemImage: "icloud.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            proBanner
        }
    }

    /// Pro status line. Purchased and Early-Access Pro share the collar badge; only
    /// Early-Access links to the support screen. Otherwise: the 30-day trial
    /// starts at first launch, so a new install shows a low-key "Pro trial active — N days
    /// left" indicator (a positive status, not an upsell nag); once the trial lapses it makes
    /// the reduced protection explicit.
    @ViewBuilder
    private var proBanner: some View {
        HomeProBadge(status: entitlements.status) { showPaywall = true }
        if entitlements.trialEnded {
            VStack(spacing: 6) {
                Label("Pro trial ended - your device is still protected. Local detection and evidence keep working; cloud backup and cross-device alerts are off.",
                      systemImage: "lock.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                Button(PaywallView.priced("Restore protection", displayPrice: entitlements.product?.displayPrice)) { showPaywall = true }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal)
        } else if entitlements.status == .trial, let days = entitlements.trialDaysRemaining {
            Button { showPaywall = true } label: {
                Label {
                    Text(days <= 3 ? "\(days) day\(days == 1 ? "" : "s") of Pro left - tap to keep it"
                                   : "Pro trial active - \(days) days left")
                } icon: {
                    CollarIcon(height: 12)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// A status line — colored dot + label — matching the iCloud/Guided Access rows.
    private func statusRow(ready: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ready ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .reportedOnScreen(text)
    }

}

/// The same permanent Pro branding for purchasers and Early-Access members. Only
/// Early-Access opens the support sheet; purchasers are not offered another upgrade.
struct HomeProBadge: View {
    let status: ProEntitlements.Status
    var showSupport: () -> Void

    @ViewBuilder
    var body: some View {
        if status == .pro {
            badge
        } else if status == .earlyAccess {
            Button(action: showSupport) { badge }
                .buttonStyle(.plain)
        }
    }

    private var badge: some View {
        Label {
            Text("Pro")
        } icon: {
            CollarIcon(height: 12)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
