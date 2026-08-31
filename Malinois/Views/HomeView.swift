//
//  HomeView.swift
//  Malinois
//
//  The disarmed home. Big Arm control, iCloud status, a quick trigger-mode
//  toggle, and PIN-gated access to the event log and settings.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var engine: MonitoringEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var cloud: CloudExfiltrator
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var entitlements: ProEntitlements
    @Environment(\.scenePhase) private var scenePhase

    /// PIN-gated areas. Both the event log and Settings require the PIN.
    enum Gate: Identifiable {
        case log, settings, test
        var id: Int {
            switch self { case .log: 0; case .settings: 1; case .test: 2 }
        }
        var prompt: String {
            switch self {
            case .log:      "Enter PIN to view log"
            case .settings: "Enter PIN for Settings"
            case .test:     "Enter PIN to test sensors"
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
            case .settings:   false
            }
        }
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

                Spacer(minLength: 8)

                statusBadge

                Button(action: engine.beginArming) {
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

                Spacer()

                HStack(spacing: 16) {
                    Button {
                        pinGate = .log
                    } label: {
                        Label(eventLogTitle, systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        pinGate = .settings
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
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
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showTest) { DryRunView() }
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .navigationDestination(isPresented: $showLog) { EventLogView() }
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
                showLog = false
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
            }
        }
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

    /// Opens the area unlocked by a successful PIN, once the prompt has dismissed.
    private func openUnlocked() {
        guard let dest = unlocked else { return }
        unlocked = nil
        switch dest {
        case .log:      showLog = true
        case .settings: showSettings = true
        case .test:     showTest = true
        }
    }

    /// "Event Log (54)" — a glanceable count of real events (routine arm/disarm audit records
    /// are excluded so the number reads as tampers, not activity). Hidden at 0. This is a
    /// convenience/baseline, not a tamper-evidence guarantee: it's the local count, which an
    /// iCloud-only attacker doesn't change (BACKLOG 9a/10).
    private var eventLogTitle: String {
        let count = eventStore.events.lazy.filter { !$0.isStateChange }.count
        return count > 0 ? "Event Log (\(count))" : "Event Log"
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
            } else if entitlements.proActive {
                statusRow(ready: cloud.accountState.isReady, text: cloud.accountState.displayName)
            } else {
                statusRow(ready: false, text: "iCloud backup is Pro — evidence stays on device")
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
            if engine.recoveredInterruptedSession {
                Label("Recovered an interrupted armed session — re-syncing any pending evidence.",
                      systemImage: "arrow.clockwise.icloud")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if !engine.isOnline && entitlements.proActive {
                // Only meaningful when cloud backup is in use; a free user's evidence stays
                // on-device regardless of connectivity, so this would be misleading (P-05).
                Label("Offline — captured evidence can't upload until you reconnect.",
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
                      ? "Your only enabled tripwire is audio, which is Pro — enable a free tripwire in Settings or upgrade, or nothing will trigger."
                      : "No tripwires enabled — nothing will trigger. Turn one on in Settings.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            // The defaults include Guided Access enforcement off and the Sound and Vision
            // tripwires off, so a settings reset the owner didn't ask for reduces protection.
            // It has to be said, not just logged.
            if AppSettings.loadWasReset {
                Label("Your settings couldn't be read and have been reset to defaults. Check Settings before arming — tripwires and Guided Access enforcement may not be as you left them.",
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
                Label("New events aren't being saved to this device — storage may be full. Anything already uploaded to iCloud is unaffected.",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.red)
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
                Label("iCloud refused an evidence upload — evidence is kept on this device and will retry. Check your iCloud storage.",
                      systemImage: "icloud.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if cloud.cloudUnavailable {
                Label("iCloud backup isn't available in this build — evidence is kept on-device only. A signed build with an iCloud container restores off-device sync.",
                      systemImage: "icloud.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            proBanner
        }
    }

    /// Trial status / upgrade prompt. The 30-day trial starts at first launch, so a new
    /// install shows a low-key "Pro trial active — N days left" indicator (a positive status,
    /// not an upsell nag); once the trial lapses it makes the reduced protection explicit.
    @ViewBuilder
    private var proBanner: some View {
        if entitlements.trialEnded {
            VStack(spacing: 6) {
                Label("Pro trial ended — your device is still protected. Local detection and evidence keep working; cloud backup and cross-device alerts are off.",
                      systemImage: "lock.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                Button("Restore protection — \(entitlements.product?.displayPrice ?? "$9.99")") { showPaywall = true }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal)
        } else if entitlements.status == .trial, let days = entitlements.trialDaysRemaining {
            Button { showPaywall = true } label: {
                Label {
                    Text(days <= 3 ? "\(days) day\(days == 1 ? "" : "s") of Pro left — tap to keep it"
                                   : "Pro trial active — \(days) days left")
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
    }

}
