//
//  SettingsView.swift
//  Malinois
//
//  Tripwires, per-sensor sensitivity, grace period, capture mode, trigger
//  mode, Guided Access enforcement, PIN change, and iCloud status.
//

import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var cloud: CloudExfiltrator
    @EnvironmentObject private var entitlements: ProEntitlements
    @Environment(\.dismiss) private var dismiss

    @State private var showChangePIN = false
    @State private var showPaywall = false
    @State private var showPurgeDialog = false
    @State private var purgeNote: String?
    /// Guided Access blocks leaving the app, which is what the Help links do — tracked so the
    /// section's footer can say so while it is on (same pattern as the PIN pad's caption).
    @State private var gaActive = UIAccessibility.isGuidedAccessEnabled
    /// The microphone permission, re-read after every prompt this screen raises (item 69).
    @State private var micPermission = CameraController.microphonePermission
    /// The notifications permission, for the iCloud section's row (item 69); nil until read.
    @State private var notificationStatus: UNAuthorizationStatus?

    var body: some View {
        NavigationStack {
            Form {
                proSection
                sensorsSection
                responseSection
                sensitivitySection
                triggerSection
                captureSection
                securitySection
                iCloudSection
                consideringSection
                helpSection
                #if DEBUG
                spikeSection   // BACKLOG 14 probes — debug builds only, removed post-spike
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIAccessibility.guidedAccessStatusDidChangeNotification)) { _ in
                gaActive = UIAccessibility.isGuidedAccessEnabled
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { settings.save(); dismiss() }
                }
            }
            .sheet(isPresented: $showChangePIN) { ChangePINView().environmentObject(settings) }
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .task { micPermission = CameraController.microphonePermission; notificationStatus = await NotificationPermission.status(); await cloud.refreshAccountState() }
        }
        // Persist even if the sheet is swiped down instead of tapping Done.
        .onDisappear { settings.save() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var proSection: some View {
        Section {
            if entitlements.status == .pro {
                HStack {
                    Label { Text("Malinois Pro") } icon: { CollarIcon(height: 16) }
                    Spacer()
                    Text("Active").foregroundStyle(.green)
                }
            } else if entitlements.status == .earlyAccess {
                // Early-Access (BACKLOG 66): Pro is free and permanent; the row stays a door to
                // the support screen.
                Button { showPaywall = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label { Text("Malinois Pro - Early-Access") } icon: { CollarIcon(height: 16) }
                                .font(.body.weight(.semibold))
                            Spacer()
                            Text("Active").foregroundStyle(.green)
                        }
                        Text("Free and permanent for Early-Access installs. Tap to support the project - one-time \(entitlements.product?.displayPrice ?? "$9.99"); it adds nothing you don't already have.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                // Free OR trial — always offer the purchase (buyable during the trial too).
                Button { showPaywall = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label {
                                Text(entitlements.status == .trial ? "Malinois Pro - trial" : "Unlock Malinois Pro")
                            } icon: {
                                CollarIcon(height: 16)
                            }
                            .font(.body.weight(.semibold))
                            Spacer()
                            if entitlements.status == .trial, let d = entitlements.trialDaysRemaining {
                                Text("\(d)d left").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(entitlements.status == .trial
                             ? "Everything's unlocked during your trial. Buy now to keep it - one-time \(entitlements.product?.displayPrice ?? "$9.99")."
                             : "iCloud backup, cross-device alerts, both cameras, longer clips, and the sound tripwire. One-time \(entitlements.product?.displayPrice ?? "$9.99").")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var sensorsSection: some View {
        Section {
            ForEach(SensorType.allCases.filter { $0 != .camera }) { sensor in
                Toggle(isOn: binding(for: sensor)) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Label(sensor.displayName, systemImage: sensor.iconName)
                            if SensorType.proTripwires.contains(sensor) { proMark }
                            if SensorType.proTripwires.contains(sensor) && !entitlements.proActive { proTag }
                        }
                        Text(sensor.summary)
                            .font(.caption).foregroundStyle(.secondary)
                        // A Pro tripwire switched on without Pro is stored but clamped off at
                        // arm time (`effectiveSensors`). Without this the toggle reads ON and
                        // the sensor never runs — the user believes they are covered and a
                        // clean log reads as "nothing happened". The saved choice is
                        // deliberately kept, per "store intent, clamp at use", so say so.
                        if sensor.isInertWithoutPro(enabled: settings.isEnabled(sensor),
                                                    pro: entitlements.proActive) {
                            Label("On, but not running - \(sensor.displayName) needs Pro. Your choice is saved and resumes if you upgrade.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if sensor == .audio, settings.isEnabled(.audio), micPermission == .denied {
                            Label("Microphone access is off for Malinois in iOS Settings, so the Sound tripwire can't listen. Allow Microphone under iOS Settings → Apps → Malinois.",
                                  systemImage: "mic.slash")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if sensor == .vision, settings.isEnabled(.vision) {
                            Text("For a phone lying face down, set Capture → Camera to Auto or Rear so it watches the room.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Tripwires")
        } footer: {
            Text("Any enabled tripwire fires on its own. Vision runs only while the camera is warm; on battery the other tripwires still cover you.")
        }
    }

    /// The Pro mark beside a Pro-gated control (owner's ask, 2026-09-04): the collar, small,
    /// shown whether or not Pro is active — it says what the control is, not whether it is
    /// locked; the "PRO" pill below still says locked.
    private var proMark: some View {
        CollarIcon(height: 12).accessibilityLabel("Pro")
    }

    /// Small "PRO" pill for a Pro-gated control.
    private var proTag: some View {
        Text("PRO")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .foregroundStyle(.tint)
    }

    private var sensitivitySection: some View {
        Section("Sensitivity") {
            ForEach(SensorType.tripwires.filter { $0 != .power && $0 != .proximity }) { sensor in
                Picker(selection: sensitivityBinding(for: sensor)) {
                    ForEach(Sensitivity.allCases) { Text($0.displayName).tag($0) }
                } label: {
                    Label(sensor.displayName, systemImage: sensor.iconName)
                }
            }
            Text("Power and Proximity are binary and have no sensitivity.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var triggerSection: some View {
        Section {
            Stepper(value: Binding(
                get: { settings.gracePeriodSeconds },
                set: { settings.gracePeriodSeconds = $0 }), in: 5...120, step: 5) {
                Text("Arming Grace Period: \(settings.gracePeriodSeconds)s")
            }
            // Under Arming by the owner's ruling (2026-09-05): a whole-watch behaviour that
            // overrides the response mode — Stealth included — rather than a response setting.
            Toggle(isOn: Binding(
                get: { settings.jammingResponse },
                set: { settings.jammingResponse = $0 })) {
                VStack(alignment: .leading) {
                    Text("Alarm on suspected attack")
                    Text("Abandon covert mode when the pattern looks like a sophisticated attack. Suspected jamming (total signal loss while armed and stationary) sounds the siren even in Stealth. A sensor flood shows the on-screen warning - it sirens only if your response is Siren.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Arming")
        } footer: {
            Text("Any enabled tripwire fires on its own. Time to set the device down and step away before the watch goes live.")
        }
    }

    private var responseSection: some View {
        Section {
            // Two pickers on this screen are labelled "Mode" (this one and Capture's); the
            // section headers carry the context for sighted users, the accessibility labels
            // carry it for VoiceOver (owner's renames, 2026-09-05).
            Picker(selection: Binding(
                get: { settings.responseMode },
                set: { settings.responseMode = $0 })) {
                ForEach(ResponseMode.allCases) { Text($0.displayName).tag($0) }
            } label: {
                Text("Mode")
            }
            .accessibilityLabel("Response mode")
            if settings.responseMode.showsMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On-screen message").font(.caption).foregroundStyle(.secondary)
                    TextField("Message", text: Binding(
                        get: { settings.alertMessage },
                        set: { settings.alertMessage = $0 }), axis: .vertical)
                        .lineLimit(1...3)
                }
            }
            Text(responseHint)
                .font(.caption).foregroundStyle(.secondary)

            if settings.responseMode == .siren {
                Toggle(isOn: Binding(
                    get: { settings.sirenRampUp },
                    set: { settings.sirenRampUp = $0 })) {
                    VStack(alignment: .leading) {
                        Text("Start quiet, then ramp up")
                        Text("The alarm opens quietly and rises to full over about 20 seconds, so disarming your own device isn't a jolt. Turn off for maximum volume immediately.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

        } header: {
            Text("Tripwire Response")
        } footer: {
            if settings.responseMode == .siren {
                Text("iOS gives no app control of the hardware volume buttons, so the alarm plays at whatever the media volume is. For Siren mode, turn OFF Volume Buttons in Guided Access → Options so it can't be turned down while armed.")
            }
        }
    }

    private var clipAudioCaption: String {
        if settings.cameraPosition == .both && CameraController.supportsMultiCam {
            return "With the camera on Both, clips are video only: recording both cameras at once leaves no room for the microphone."
        }
        switch (settings.clipAudio, micPermission) {
        case (false, _):
            return "Clips are video only. Turn this on to add sound from the microphone; iOS asks for microphone access the first time."
        case (true, .denied):
            return "Microphone access is off for Malinois in iOS Settings, so clips stay video only until you allow it under iOS Settings → Apps → Malinois."
        case (true, _):
            return "Clips include sound from the microphone."
        }
    }

    /// Asks iOS for the microphone if it has never been asked, then re-reads the answer for
    /// the captions that depend on it (item 69).
    private func requestMicrophone() {
        Task {
            _ = await CameraController.requestMicrophoneAccessIfUndetermined()
            micPermission = CameraController.microphonePermission
        }
    }

    private var responseHint: String {
        switch settings.responseMode {
        case .alert:   return "Evidence is captured silently, then a warning appears on screen - a deterrent that also serves as the disarm prompt."
        case .stealth: return "Fully covert: the screen stays black and nothing is shown. Evidence is still captured and uploaded."
        case .siren:   return "Captures evidence, shows the warning, and sounds a loud alarm (plays even on silent) until the tamper stops or you disarm."
        }
    }

    private var captureSection: some View {
        Section {
            // The camera lives HERE, not under Tripwires: it isn't a tripwire, and
            // sitting beside Vision made it read like one (owner request, 2026-08-23).
            Toggle(isOn: binding(for: .camera)) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(SensorType.camera.displayName, systemImage: SensorType.camera.iconName)
                    Text(SensorType.camera.summary)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker(selection: Binding(
                get: { settings.captureMode },
                set: { settings.captureMode = $0 })) {
                ForEach(CaptureMode.allCases) { Text($0.displayName).tag($0) }
            } label: {
                // No collar on this row or the Camera row (owner, 2026-09-05): not every option
                // in these pickers is Pro, and the mark read as if the whole picker were. The
                // footer still names the Pro options while Pro is inactive.
                Text("Mode")
            }
            .accessibilityLabel("Capture mode")
            if settings.captureMode.isClip {
                // Off by default (owner ruling, 2026-09-05): clips are video only until the
                // owner adds sound, and that is the moment iOS asks for the microphone.
                Toggle(isOn: Binding(
                    get: { settings.clipAudio },
                    set: { on in
                        settings.clipAudio = on
                        if on { requestMicrophone() }
                    })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Record audio in clips")
                        Text(clipAudioCaption)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Picker(selection: Binding(
                get: { settings.cameraPosition },
                set: { settings.cameraPosition = $0 })) {
                // Rear and Auto serve the Vision tripwire's setup only (ADR 0012).
                ForEach(CameraChoice.allCases.filter { settings.isEnabled(.vision) || !$0.needsVision }) {
                    Text($0.displayName).tag($0)
                }
            } label: {
                Text("Camera")
            }
            if !settings.isEnabled(.vision) {
                Text("Rear and Auto appear when the Vision tripwire is on: the rear camera is only worth using while the camera is watching the room, as with a phone lying face down.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.cameraPosition == .rear {
                Text("Rear only, with one exception: a trigger that includes a screen touch captures from the front camera, because a screen being touched is facing whoever touches it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if settings.cameraPosition == .auto {
                Text("Rear while the phone lies face down, front in every other position, decided at each event.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.cameraPosition == .both {
                Text(CameraController.supportsMultiCam
                     ? (settings.captureMode.isClip
                        ? "Captures the front and rear cameras simultaneously. Video only; clips will not contain audio."
                        : "Captures the front and rear cameras simultaneously.")
                     : "This device doesn't support multi-cam - “Both” will capture the front camera only.")
                    .font(.caption)
                    .foregroundStyle(CameraController.supportsMultiCam ? Color.secondary : Color.orange)
            }
            Picker("Battery mode", selection: Binding(
                get: { settings.cameraReadiness },
                set: { settings.cameraReadiness = $0 })) {
                ForEach(CameraReadiness.allCases) { Text($0.displayName).tag($0) }
            }
            Text(settings.cameraReadiness.summary)
                .font(.caption).foregroundStyle(.secondary)
            Picker("Illumination", selection: Binding(
                get: { settings.illumination },
                set: { settings.illumination = $0 })) {
                ForEach(IlluminationMode.allCases) { Text($0.displayName).tag($0) }
            }
            Text("Lights the shot (screen flash front / LED rear) so evidence isn't black. Auto only fires in dim light; Off = full stealth.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Capture")
        } footer: {
            if !entitlements.proActive {
                Text("“Both” cameras and 5-second / until-clear clips are Pro. The free tier captures a single camera and up to a 3-second clip.")
            }
        }
    }

    private var securitySection: some View {
        Section {
            Button("Change PIN") { showChangePIN = true }
            Toggle(isOn: Binding(
                get: { settings.requireGuidedAccess },
                set: { settings.requireGuidedAccess = $0 })) {
                VStack(alignment: .leading) {
                    Text("Require Guided Access")
                    Text("Refuse to arm unless Guided Access is on. It's what stops a snoop swiping the app away or powering the device off. On by default; while you're still testing, the arming screen can lift it for one arm.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(
                get: { settings.scramblePINPad },
                set: { settings.scramblePINPad = $0 })) {
                VStack(alignment: .leading) {
                    Text("Scramble PIN pad")
                    Text("Randomizes the disarm keypad each time, so someone watching can't learn your PIN from finger positions. Slower to enter - leave off if you rely on muscle memory.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(
                get: { settings.biometricUnlock },
                set: { settings.biometricUnlock = $0 })) {
                VStack(alignment: .leading) {
                    Text("Face ID unlock")
                    Text("Open the Event Log and Test Sensors with Face ID instead of the PIN. Settings, disarming, and changing the PIN always require the PIN: a face can be presented; a PIN has to be given.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Security")
        } footer: {
            Text("Guided Access (single-app mode) is strongly recommended while armed - it stops a snoop from switching away or powering off. Malinois coaches you through it on the arming screen.")
        }
    }

    private var iCloudSection: some View {
        Section {
            HStack {
                Text("Account")
                Spacer()
                Text(cloud.accountState.displayName)
                    .foregroundStyle(cloud.accountState.isReady ? .green : .orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Device label").font(.caption).foregroundStyle(.secondary)
                // The placeholder IS the effective default (owner's ask, 2026-08-30): an
                // empty field shows exactly what the device will be called, in placeholder
                // grey — the standard type-to-override idiom — instead of a hypothetical
                // example beside a caption explaining the real fallback.
                TextField(DeviceInfo.marketingName(forIdentifier: DeviceInfo.modelIdentifier),
                          text: Binding(
                    get: { settings.deviceLabel },
                    set: { settings.deviceLabel = $0 }))
                Text("Names this device in evidence and cross-device alerts. Leave blank to use the model name shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(
                get: { settings.notifyOtherDevices },
                set: { applyCrossDeviceAlerts($0) })) {
                VStack(alignment: .leading) {
                    HStack { Text("Cross-device alerts"); proMark }
                    Text("Alert every device on this iCloud account the moment any of them is triggered - and the moment any of them is disarmed. One switch for the whole account, applied immediately from any device: off removes the alerts for all devices, on restores them - no re-arm needed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let subscriptionNote {
                Text(subscriptionNote).font(.caption).foregroundStyle(.orange)
            }
            // The notifications ask lives here too (owner, 2026-09-05): Home shows it only once
            // another device's evidence has arrived, and its Hide button points here.
            if entitlements.proActive, let notificationStatus {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Notifications on this device")
                        Spacer()
                        switch notificationStatus {
                        case .authorized, .provisional, .ephemeral:
                            Text("Allowed").foregroundStyle(.green)
                        case .denied:
                            Text("Off").foregroundStyle(.orange)
                        default:
                            Button("Allow") {
                                Task {
                                    await NotificationPermission.requestIfUndetermined()
                                    self.notificationStatus = await NotificationPermission.status()
                                }
                            }
                            .font(.caption.weight(.semibold)).buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    Text(notificationStatus == .denied
                         ? "Alerts from your other devices can't be shown here until you allow Notifications for Malinois under iOS Settings → Apps → Malinois."
                         : "Needed only to show alerts from your other devices on this one; arming never needs it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker(selection: Binding(
                get: { settings.cloudRetention },
                set: { settings.cloudRetention = $0 })) {
                ForEach(CloudRetention.allCases) { Text($0.displayName).tag($0) }
            } label: {
                HStack { Text("Full-media retention"); proMark }
            }
            Text("Applies to full-resolution photos and clips in iCloud. Event facts, thumbnails, and arm/disarm records are always kept, and nothing newer than 30 days is ever deleted.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.cloudRetention == .manual {
                Button("Free up iCloud space…") { showPurgeDialog = true }
                    .confirmationDialog("Delete full-resolution photos and clips from iCloud?",
                                        isPresented: $showPurgeDialog, titleVisibility: .visible) {
                        ForEach([1, 3, 6, 12], id: \.self) { months in
                            Button("Older than \(months) month\(months == 1 ? "" : "s")",
                                   role: .destructive) {
                                Task { await runPurge(monthsOld: months) }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Event facts, thumbnails, and arm/disarm records are kept. Nothing newer than 30 days can be deleted. This cannot be undone.")
                    }
            }
            if let purgeNote {
                Text(purgeNote).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack { Text("iCloud"); proMark }
        } footer: {
            if !entitlements.proActive {
                Text("iCloud backup and cross-device alerts are Pro. On the free tier, evidence is kept on this device only.")
            }
        }
    }

    @State private var subscriptionNote: String?

    /// H6, option A: the toggle IS the account switch, applied now — not a preference the
    /// next arm interprets. The local value still saves (arm and reconnect use it as
    /// create-only backstops), and a failed OFF is surfaced hard: with arm no longer
    /// deleting, nothing else will retry the removal.
    private func applyCrossDeviceAlerts(_ enabled: Bool) {
        settings.notifyOtherDevices = enabled
        settings.save()   // now, not after the 400 ms debounce: the account switch below applies at once (item 73, review 1 F4)
        guard entitlements.proActive else { return }   // free tier has no subscription to manage
        subscriptionNote = nil
        Task {
            if enabled { await NotificationPermission.requestIfUndetermined() }   // this device may receive alerts too (item 69)
            let landed = await cloud.setCrossDeviceAlerts(enabled)
            subscriptionNote = landed ? nil
                : "iCloud couldn't be updated - flip the switch again to retry."
        }
    }

    /// BACKLOG 14's demand-check line, added at the owner's direction (2026-08-30). The
    /// feature was spiked to completion and then DEFERRED (2026-09-01: it closes only the
    /// quiet PIN path, which 1.3 makes loud instead), so this line is now the reopen gate's
    /// instrument — support@ asks are what bring item 14 back. Honest tense: no "Planned".
    /// Deliberately text-only even now that the Help section below carries the app's
    /// outbound links (item 21): this is a survey line, not a support surface, and its
    /// address is the same support@ every other user-facing surface shows — copyable, not
    /// tappable.
    private var consideringSection: some View {
        Section {
            Text("Hardware-key disarm - Malinois couldn't be disarmed without a physical security key you enroll (NFC or USB-C). The hard parts are proven on our test devices; whether it ships depends on demand. If you'd use it, email support@comptonemail.com and say so.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Considering")
        }
    }

    /// BACKLOG 21: the app's only outbound links — Help & FAQ, the privacy policy, and the
    /// public source — at the foot of Settings. Settings is PIN-gated and reachable only
    /// while disarmed, so leaving the app from here is harmless; never put a link on
    /// `ArmedView`, where leaving is exactly what Guided Access exists to prevent. Under
    /// Guided Access a tap silently does nothing, so the footer says so and every row offers
    /// copy-the-address as the way out. The destinations live in `AppLinks`, pinned by test.
    private var helpSection: some View {
        Section {
            ForEach(AppLinks.rows) { row in
                Link(destination: row.url) {
                    Label(row.title, systemImage: row.symbol)
                }
                .contextMenu {
                    Button("Copy link", systemImage: "doc.on.doc") {
                        UIPasteboard.general.url = row.url
                    }
                }
            }
        } header: {
            Text("Help")
        } footer: {
            Text(AppLinks.footer(guidedAccessActive: gaActive))
        }
    }

    /// The Manual retention mode's explicit purge (32.R2). The 30-day protection floor is
    /// enforced inside `purgeCutoff`, so no month choice here can violate it.
    private func runPurge(monthsOld months: Int) async {
        guard entitlements.proActive else { return }
        purgeNote = "Deleting…"
        let result = await cloud.purgeFullMedia(
            olderThan: CloudExfiltrator.purgeCutoff(monthsOld: months, now: Date()))
        purgeNote = result.failed
            ? "Some records couldn't be deleted - check iCloud and try again."
            : "Deleted full media from \(result.eventsExamined) event(s)."
    }

    // MARK: - Bindings

    private func binding(for sensor: SensorType) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(sensor) },
            set: { on in
                if on { settings.enabledSensors.insert(sensor) }
                else { settings.enabledSensors.remove(sensor) }
                // The microphone is asked for here, when the Sound tripwire is switched on,
                // not at launch (item 69); the monitor never records without the grant.
                if on && sensor == .audio { requestMicrophone() }
                // Rear and Auto serve Vision only (ADR 0012): switching it off returns the
                // camera to Front, which is what the picker will offer from now on.
                if !on && sensor == .vision {
                    settings.cameraPosition = AppSettings.cameraChoice(settings.cameraPosition, visionOn: false)
                }
            })
    }

    private func sensitivityBinding(for sensor: SensorType) -> Binding<Sensitivity> {
        Binding(
            get: { settings.sensitivity(for: sensor) },
            set: { settings.sensitivities[sensor] = $0 })
    }
}

// MARK: - Change PIN

struct ChangePINView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .verify
    @State private var error: String?

    enum Stage { case verify, setNew }

    var body: some View {
        Group {
            switch stage {
            case .verify:
                PINEntryView(title: "Enter current PIN") {
                    stage = .setNew
                } onCancel: { dismiss() }
            case .setNew:
                PINSetupView { dismiss() }
            }
        }
    }
}

#if DEBUG

// MARK: - BACKLOG 14 spike harness (0a + 0c's API half) — throwaway, removed post-spike

import CryptoTokenKit
import CryptoKit
import CommonCrypto
#if canImport(CoreNFC)
import CoreNFC
#endif

extension SettingsView {
    /// Debug builds only: the item-14 probes (key-gated disarm, route A).
    var spikeSection: some View {
        Section("Development (debug builds only)") {
            NavigationLink("Item 14 spike — NFC / smart-card probes") { Spike14View() }
        }
    }
}

/// On-screen, timestamped log so results are readable on device mid-Guided-Access —
/// the deferral question (does the system NFC sheet queue under GA the way the Face ID
/// sheet does, BACKLOG 44?) is answered by WHEN lines appear, so every line is stamped.
final class Spike14Model: NSObject, ObservableObject {
    @Published var log: [String] = []

    private var nfcSession: NFCTagReaderSession?
    private var slotSession: Any?   // TKSmartCardSlotNFCSession (iOS 26 type; stored as Any for the iOS 17 target)
    private var pollTask: Task<Void, Never>?
    private var lastLoggedState = -1
    /// The 9E public key (65-byte uncompressed EC point) captured at enroll, verified
    /// against at disarm-sim. In the real feature this lives in the Keychain roster;
    /// here a static stands in so backing out of the spike screen (which recreates the
    /// model, as the 0d run discovered) doesn't drop the enrollment mid-session.
    private static var storedEnrolledKey: Data?
    private var enrolledPublicKey: Data? {
        get { Self.storedEnrolledKey }
        set { Self.storedEnrolledKey = newValue }
    }
    /// The PIV PIN, entered at runtime for a personalized key (retrieves its PIN-protected
    /// management key). Never stored, never committed — lives only in memory for the run.
    @Published var pivPIN: String = ""
    /// A custom management key entered as hex, for a personalized key whose key the owner
    /// holds (set it, but did NOT store it PIN-protected). Runtime-only, never committed.
    @Published var pivMgmtKeyHex: String = ""
    /// Probe 4 refuses to GENERATE over an occupied 9E slot unless this is ON — protects a
    /// personalized key already carrying a card-auth credential, and makes re-running 4 on
    /// the fresh key (whose 9E the first green run filled) a deliberate act.
    @Published var allowOverwrite9E = false
    private let selectPIVAPDU: [UInt8] =
        [0x00, 0xA4, 0x04, 0x00, 0x0B, 0xA0, 0x00, 0x00, 0x03, 0x08, 0x00, 0x00, 0x10, 0x00, 0x01, 0x00, 0x00]
    private let defaultMgmtKey = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                                       0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                                       0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

    /// The slot the probes should target: any enumerated slot first (a WIRED key shows up
    /// in `slotNames` — no sheet, no timeout), else the live NFC session's slot.
    @available(iOS 26.0, *)
    private func bestSlotName(_ mgr: TKSmartCardSlotManager) -> String? {
        if let wired = mgr.slotNames.first { return wired }
        return (slotSession as? TKSmartCardSlotNFCSession)?.slotName
    }

    private func stamp(_ line: String) {
        DispatchQueue.main.async {
            self.log.append(Date().formatted(date: .omitted, time: .standard) + "  " + line)
        }
    }

    /// Probe 1 — CryptoTokenKit posture: manager, NFC support, and whatever slots the
    /// system currently enumerates (the USB-C answer requires a CCID reader plugged in
    /// at tap time; empty is the expected reading without one).
    func probeSlots() {
        guard let mgr = TKSmartCardSlotManager.default else {
            stamp("1: defaultManager = nil — unexpected on iOS per TKSmartCard.h:22")
            return
        }
        stamp("1: defaultManager OK")
        if #available(iOS 26.0, *) {
            stamp("1: isNFCSupported = \(mgr.isNFCSupported())")
        } else {
            stamp("1: iOS < 26 — no isNFCSupported")
        }
        stamp("1: slotNames (\(mgr.slotNames.count)): [\(mgr.slotNames.joined(separator: ", "))]")
    }

    /// Probe 2 — the route-A transport: iOS 26's native NFC smart-card slot, with the
    /// system-presented UI. The log's job is the timing: called → sheet → session/error.
    func createNFCSlot() {
        guard #available(iOS 26.0, *) else { stamp("2: needs iOS 26"); return }
        guard let mgr = TKSmartCardSlotManager.default else { stamp("2: no manager"); return }
        stamp("2: createNFCSlot CALLED — does the system sheet appear NOW?")
        mgr.createNFCSlot(message: "Malinois item-14 spike") { [weak self] session, error in
            if let session {
                self?.slotSession = session
                self?.stamp("2: session created, slotName = \(session.slotName ?? "nil")")
                // The sheet covers our buttons and dismissing it kills the slot — so the
                // rest of the flow is hands-free: poll for the card, SELECT on arrival.
                if let name = session.slotName { self?.startPolling(mgr: mgr, name: name) }
            } else if let error = error as NSError? {
                self?.stamp("2: error \(error.domain) \(error.code) — \(error.localizedDescription)")
            } else {
                self?.stamp("2: nil session, nil error")
            }
        }
    }

    /// Hands-free card wait: logs state TRANSITIONS every ~0.7 s for 30 s; on a card
    /// arriving (muteCard/validCard) fires SELECT PIV automatically; logs the slot dying
    /// (which also measures the sheet's real lifetime) or the timeout.
    @available(iOS 26.0, *)
    private func startPolling(mgr: TKSmartCardSlotManager, name: String) {
        pollTask?.cancel()
        lastLoggedState = -1
        let t0 = Date()
        pollTask = Task { [weak self] in
            let states = ["missing", "empty", "probing", "muteCard", "validCard"]
            while !Task.isCancelled, Date().timeIntervalSince(t0) < 30 {
                let slot: TKSmartCardSlot? = await withCheckedContinuation { cont in
                    mgr.getSlot(withName: name) { cont.resume(returning: $0) }
                }
                guard let slot else {
                    self?.stamp("2: slot GONE at +\(Int(Date().timeIntervalSince(t0)))s — sheet/session ended")
                    return
                }
                let raw = Int(slot.state.rawValue)
                if raw != self?.lastLoggedState {
                    self?.lastLoggedState = raw
                    let label = states.indices.contains(raw) ? states[raw] : "raw \(raw)"
                    self?.stamp("2: state → \(label) at +\(Int(Date().timeIntervalSince(t0)))s")
                }
                if raw >= 3 {   // muteCard / validCard: something is in the field
                    self?.stamp("2: CARD IN FIELD — running SELECT PIV")
                    self?.selectPIV()
                    return
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            if !Task.isCancelled { self?.stamp("2: poll timeout (30 s), no card seen") }
        }
    }

    func endNFCSlot() {
        pollTask?.cancel()
        if #available(iOS 26.0, *), let session = slotSession as? TKSmartCardSlotNFCSession {
            session.end()
            stamp("2b: end()")
        } else {
            stamp("2b: no live slot session")
        }
        slotSession = nil
    }

    /// Probe 2c — the question the GA run raised: is a created slot's RF field actually
    /// LIVE even when the system sheet is suppressed (GA), or is the session an empty
    /// shell? Tap with no card, then with any contactless card held to the top edge —
    /// a state change to probing/muteCard/validCard means the radio is on and route A
    /// works under GA without any system chrome at all.
    func probeLiveSlot() {
        guard #available(iOS 26.0, *) else { stamp("2c: needs iOS 26"); return }
        guard let mgr = TKSmartCardSlotManager.default else { stamp("2c: no manager"); return }
        stamp("2c: slotNames now (\(mgr.slotNames.count)): [\(mgr.slotNames.joined(separator: ", "))]")
        guard let name = bestSlotName(mgr) else {
            stamp("2c: no slot anywhere — plug a key in, or tap 2 first")
            return
        }
        mgr.getSlot(withName: name) { [weak self] slot in
            guard let slot else { self?.stamp("2c: getSlot → nil"); return }
            let states = ["missing", "empty", "probing", "muteCard", "validCard"]
            let raw = Int(slot.state.rawValue)
            let label = states.indices.contains(raw) ? states[raw] : "raw \(raw)"
            self?.stamp("2c: slot state = \(label), ATR \(slot.atr != nil ? "PRESENT" : "nil")")
        }
    }

    /// Probe 2d — the PIV handshake: SELECT the PIV applet over the live slot, logging
    /// the raw response, status word, and timing. SW 9000 proves transport + card +
    /// applet in one APDU; the bytes are the spike plan's fixture capture.
    func selectPIV() {
        guard #available(iOS 26.0, *) else { stamp("2d: needs iOS 26"); return }
        guard let mgr = TKSmartCardSlotManager.default,
              let name = bestSlotName(mgr) else {
            stamp("2d: no slot anywhere — plug a key in, or tap 2 first")
            return
        }
        mgr.getSlot(withName: name) { [weak self] slot in
            guard let slot else { self?.stamp("2d: getSlot → nil"); return }
            guard let card = slot.makeSmartCard() else {
                self?.stamp("2d: makeSmartCard → nil (no card in the field?)")
                return
            }
            let t0 = Date()
            card.beginSession { ok, error in
                guard ok else {
                    self?.stamp("2d: beginSession failed — \(error?.localizedDescription ?? "?")")
                    return
                }
                // SELECT the PIV AID (A0 00 00 03 08 00 00 10 00 01 00), Le appended.
                let apdu = Data([0x00, 0xA4, 0x04, 0x00, 0x0B,
                                 0xA0, 0x00, 0x00, 0x03, 0x08, 0x00, 0x00, 0x10, 0x00, 0x01, 0x00,
                                 0x00])
                card.transmit(apdu) { response, error in
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    if let response {
                        let hex = response.map { String(format: "%02X", $0) }.joined(separator: " ")
                        self?.stamp("2d: [\(ms) ms] \(response.count) bytes: \(hex.prefix(150))\(hex.count > 150 ? "…" : "")")
                        if response.count >= 2 {
                            let sw = response.suffix(2).map { String(format: "%02X", $0) }.joined()
                            self?.stamp("2d: SW = \(sw)\(sw == "9000" ? " — PIV APPLET SELECTED ✓" : "")")
                        }
                    } else {
                        self?.stamp("2d: [\(ms) ms] transmit error — \(error?.localizedDescription ?? "?")")
                    }
                    card.endSession()
                }
            }
        }
    }

    // MARK: - Probes 4 & 5: the full PIV crypto round trip (spike 0c)

    /// Probe 4 — ENROLL: SELECT → learn the mgmt-key algorithm → mutual-authenticate with
    /// the default management key → GENERATE an ECC P-256 key in slot 9E → read + store its
    /// public key. This is the one operation that needs the management key; the real feature
    /// runs it once per key, in Settings, behind the PIN, outside GA.
    func enroll() {
        Task { [weak self] in
            guard #available(iOS 26.0, *) else { self?.stamp("4: needs iOS 26"); return }
            await self?.enrollFlow()
        }
    }

    /// Probe 5 — DISARM SIM: SELECT → sign a fresh random challenge with the 9E key
    /// (slot 9E is PIN-policy NEVER, so possession alone signs — no PIN, no touch) →
    /// verify the ECDSA signature against the enrolled public key with CryptoKit.
    func disarmSim() {
        Task { [weak self] in
            guard #available(iOS 26.0, *) else { self?.stamp("5: needs iOS 26"); return }
            await self?.disarmFlow()
        }
    }

    @available(iOS 26.0, *)
    private func enrollFlow() async {
        guard let card = await acquireCard("4") else { return }
        defer { cleanup(card) }
        guard let (_, sw) = await tx(card, selectPIVAPDU, "4:SEL"), sw == 0x9000 else {
            stamp("4: SELECT failed — aborting"); return
        }
        // Learn the management-key algorithm + whether it is the factory default
        // (YubiKey GET METADATA, fw 5.3+).
        var alg: UInt8 = 0x03      // default assumption: legacy 3-key TDES
        var isDefault = true       // if metadata is unavailable, assume default and try
        if let (m, msw) = await tx(card, [0x00, 0xF7, 0x00, 0x9B, 0x00], "4:META"), msw == 0x9000 {
            if let a = tlvValue(0x01, in: m)?.first { alg = a }
            isDefault = (tlvValue(0x05, in: m)?.first == 0x01)
            stamp("4: mgmt-key alg = \(hex(alg)) (\(algName(alg))), default = \(isDefault ? "yes" : "NO")")
        } else {
            stamp("4: no metadata (older fw) — assuming default TDES")
        }
        // Guard the target slot: never silently overwrite an existing 9E credential
        // (GET METADATA on 9E: 9000 = occupied, 6A88 = empty, 6D00 = older fw can't say).
        guard let (_, esw) = await tx(card, [0x00, 0xF7, 0x00, 0x9E, 0x00], "4:9E?") else {
            stamp("4: card unresponsive — aborting"); return
        }
        switch esw {
        case 0x9000 where !allowOverwrite9E:
            stamp("4: 9E ALREADY HOLDS A KEY — flip 'Allow overwriting 9E' to run deliberately.")
            return
        case 0x9000: stamp("4: 9E occupied — overwriting (toggle ON)")
        case 0x6A88: stamp("4: 9E empty ✓")
        default: stamp("4: 9E occupancy unknown (\(String(format: "%04X", esw))) — proceeding")
        }
        // Choose the management key. Factory-default for the untouched majority; for a
        // PERSONALIZED key, the PIN-protected key the YubiKey stores under the PIV PIN —
        // the shipping path for developers / enterprise-managed keys. We NEVER reset a
        // user's key.
        let key: Data
        if isDefault {
            key = defaultMgmtKey
            stamp("4: using the factory-default mgmt key")
        } else if let entered = dataFromHex(pivMgmtKeyHex), !pivMgmtKeyHex.isEmpty {
            // The owner set a custom key and holds it — the common personalized case.
            key = entered
            stamp("4: using the entered mgmt key (\(entered.count) B)")
        } else if !pivPIN.isEmpty {
            // The --protect case: the key stores its mgmt key under the PIN. NOTE the object
            // ID here (0x5FFF01) came back as a CERTIFICATE on the owner's key — that's the
            // attestation cert, so this address is wrong for the protected key; retrieval is
            // parked pending the correct object. Raw-key entry above is the working path.
            guard await verifyPIN(card, pivPIN) else { stamp("4: PIN verify failed — aborting"); return }
            stamp("4: PIN OK ✓")
            guard let retrieved = await retrieveProtectedMgmtKey(card) else {
                stamp("4: couldn't read a PIN-protected mgmt key (wrong object / not --protect). Paste the key's hex in the Mgmt key field instead."); return
            }
            key = retrieved
            stamp("4: retrieved PIN-protected mgmt key (\(retrieved.count) B) ✓")
        } else {
            stamp("4: custom mgmt key — paste its hex in the Mgmt key field (or PIN for a --protect key), then retry 4. Shipping handles both; we never reset.")
            return
        }
        // A mispasted key should say so — not masquerade as an auth/touch problem.
        let expected = [0x03: 24, 0x08: 16, 0x0A: 24, 0x0C: 32][Int(alg)] ?? 24
        guard key.count == expected else {
            stamp("4: mgmt key is \(key.count) B but \(algName(alg)) needs \(expected) B — check the pasted hex.")
            return
        }
        guard await mgmtAuth(card, alg: alg, key: key) else {
            stamp("4: mgmt auth FAILED — wrong key value? If touch-protected and blinking, touch it and retry.")
            return
        }
        stamp("4: mgmt auth OK ✓")
        // GENERATE ECC P-256 (alg 0x11) in slot 9E.
        guard let (g, gsw) = await tx(card, [0x00, 0x47, 0x00, 0x9E, 0x05, 0xAC, 0x03, 0x80, 0x01, 0x11, 0x00], "4:GEN"),
              gsw == 0x9000, let point = extractECPoint(g) else {
            stamp("4: GENERATE failed or no public key in response"); return
        }
        enrolledPublicKey = point
        stamp("4: 9E key generated, public key stored (\(point.count) B) ✓ — now run 5")
    }

    @available(iOS 26.0, *)
    private func disarmFlow() async {
        guard let point = enrolledPublicKey else { stamp("5: enroll first (run 4)"); return }
        guard let card = await acquireCard("5") else { return }
        defer { cleanup(card) }
        guard let (_, sw) = await tx(card, selectPIVAPDU, "5:SEL"), sw == 0x9000 else {
            stamp("5: SELECT failed — aborting"); return
        }
        var cbytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &cbytes)
        let challenge = Data(cbytes)
        let digest = [UInt8](Data(SHA256.hash(data: challenge)))   // the card signs this 32-byte hash directly
        let body: [UInt8] = [0x7C, 0x24, 0x82, 0x00, 0x81, 0x20] + digest
        let apdu: [UInt8] = [0x00, 0x87, 0x11, 0x9E, UInt8(body.count)] + body + [0x00]
        let t0 = Date()
        guard let (r, ssw) = await tx(card, apdu, "5:SIGN"), ssw == 0x9000,
              let outer = tlvValue(0x7C, in: r), let der = tlvValue(0x82, in: outer) else {
            stamp("5: SIGN failed or no signature in response"); return
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        do {
            let pub = try P256.Signing.PublicKey(x963Representation: point)
            let sig = try P256.Signing.ECDSASignature(derRepresentation: der)
            let ok = pub.isValidSignature(sig, for: challenge)
            stamp("5: [\(ms) ms] CryptoKit verify = \(ok ? "VALID ✓ — ROUND TRIP COMPLETE" : "INVALID ✗")")
        } catch {
            stamp("5: verify error — \(error.localizedDescription)")
        }
    }

    /// Probe 6 — 0d: one full disarm cycle with a per-phase timing breakdown
    /// (card-present → SELECT → sign+verify). Tap 5×, re-presenting the key each time,
    /// for the ramp numbers; run with the siren toggle ON for the coexistence leg.
    func disarmTiming() {
        Task { [weak self] in
            guard #available(iOS 26.0, *) else { self?.stamp("6: needs iOS 26"); return }
            await self?.disarmTimingFlow()
        }
    }

    @available(iOS 26.0, *)
    private func disarmTimingFlow() async {
        guard let point = enrolledPublicKey else { stamp("6: enroll first (run 4)"); return }
        guard let card = await acquireCard("6", pollMs: 100) else { return }
        defer { cleanup(card) }
        let tCard = Date()
        guard let (_, sw) = await tx(card, selectPIVAPDU, "6:SEL"), sw == 0x9000 else {
            stamp("6: SELECT failed"); return
        }
        let tSel = Date()
        var cbytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &cbytes)
        let challenge = Data(cbytes)
        let digest = [UInt8](Data(SHA256.hash(data: challenge)))
        let body: [UInt8] = [0x7C, 0x24, 0x82, 0x00, 0x81, 0x20] + digest
        let apdu: [UInt8] = [0x00, 0x87, 0x11, 0x9E, UInt8(body.count)] + body + [0x00]
        guard let (r, ssw) = await tx(card, apdu, "6:SIGN"), ssw == 0x9000,
              let outer = tlvValue(0x7C, in: r), let der = tlvValue(0x82, in: outer),
              let pub = try? P256.Signing.PublicKey(x963Representation: point),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: der),
              pub.isValidSignature(sig, for: challenge) else {
            stamp("6: sign/verify FAILED"); return
        }
        let tEnd = Date()
        func ms(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }
        stamp("6: VALID — card→done \(ms(tCard, tEnd)) ms (SELECT \(ms(tCard, tSel)), sign+verify \(ms(tSel, tEnd)))")
    }

    /// Probe 0 — RESET the PIV applet to factory defaults so a DEDICATED test key reaches a
    /// known management-key state (the purchased keys ship with a non-default mgmt key, so
    /// enroll can't authenticate). DESTRUCTIVE: wipes all PIV keys/certs and resets PIN
    /// (123456), PUK (12345678), and the management key to the well-known default. Blocks
    /// the PIN and PUK first (PIV requires both blocked before RESET is allowed). Use WIRED
    /// (fast, ~24 APDUs). Never run against a key holding real PIV credentials.
    func resetPIV() {
        Task { [weak self] in
            guard #available(iOS 26.0, *) else { self?.stamp("0: needs iOS 26"); return }
            await self?.resetFlow()
        }
    }

    @available(iOS 26.0, *)
    private func resetFlow() async {
        guard let card = await acquireCard("0") else { return }
        defer { cleanup(card) }
        guard let (_, sw) = await tx(card, selectPIVAPDU, "0:SEL"), sw == 0x9000 else { stamp("0: SELECT failed"); return }
        let wrong: [UInt8] = [0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39, 0x39]   // "99999999"
        let newPUK: [UInt8] = [0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30]
        for _ in 0..<12 {   // block the PIN
            guard let (_, s) = await tx(card, [0x00, 0x20, 0x00, 0x80, 0x08] + wrong, "0:PINblk") else { break }
            if s == 0x6983 || s == 0x63C0 { stamp("0: PIN blocked"); break }
        }
        for _ in 0..<12 {   // block the PUK (CHANGE REFERENCE, wrong current)
            guard let (_, s) = await tx(card, [0x00, 0x24, 0x00, 0x81, 0x10] + wrong + newPUK, "0:PUKblk") else { break }
            if s == 0x6983 || s == 0x63C0 { stamp("0: PUK blocked"); break }
        }
        guard let (_, rsw) = await tx(card, [0x00, 0xFB, 0x00, 0x00], "0:RESET") else { stamp("0: reset no response"); return }
        guard rsw == 0x9000 else { stamp("0: RESET → \(hex(UInt8(rsw >> 8)))\(hex(UInt8(rsw & 0xFF))) — PIN/PUK not fully blocked?"); return }
        stamp("0: PIV RESET OK ✓ — mgmt key now default; run 4")
        if let (m, msw) = await tx(card, [0x00, 0xF7, 0x00, 0x9B, 0x00], "0:META"), msw == 0x9000, let a = tlvValue(0x01, in: m)?.first {
            stamp("0: post-reset mgmt alg = \(hex(a)) (\(algName(a))), default = \(tlvValue(0x05, in: m)?.first.map(hex) ?? "?")")
        }
    }

    /// VERIFY the PIV PIN (needed to read a personalized key's PIN-protected mgmt key).
    /// PIN is ASCII, padded to 8 bytes with 0xFF.
    @available(iOS 26.0, *)
    private func verifyPIN(_ card: TKSmartCard, _ pin: String) async -> Bool {
        var pinBytes = [UInt8](pin.utf8)
        guard !pinBytes.isEmpty, pinBytes.count <= 8 else { stamp("4: PIN must be 1–8 chars"); return false }
        while pinBytes.count < 8 { pinBytes.append(0xFF) }
        guard let (_, sw) = await tx(card, [0x00, 0x20, 0x00, 0x80, 0x08] + pinBytes, "4:VERIFY") else { return false }
        if sw == 0x9000 { return true }
        if (sw & 0xFFF0) == 0x63C0 { stamp("4: wrong PIN, \(Int(sw & 0x0F)) tries left") }
        else if sw == 0x6983 { stamp("4: PIN blocked") }
        return false
    }

    /// Read the YubiKey's PIN-protected management key after a successful VERIFY PIN:
    /// GET DATA on the PIVMAN protected-data object — PIV's "printed information" object,
    /// **0x5FC109**, PIN-gated by its ACL; ykman's `--protect` stores the key there as
    /// 53 → 88 → 89. (The first attempt read 0x5FFF01, which is the Yubico ATTESTATION
    /// object — that's why the owner's run got a certificate back.) The response is the
    /// management key itself, so tx masks it out of the on-screen log.
    @available(iOS 26.0, *)
    private func retrieveProtectedMgmtKey(_ card: TKSmartCard) async -> Data? {
        let apdu: [UInt8] = [0x00, 0xCB, 0x3F, 0xFF, 0x05, 0x5C, 0x03, 0x5F, 0xC1, 0x09, 0x00]
        guard let (r, sw) = await tx(card, apdu, "4:GETPROT", maskData: true), sw == 0x9000 else { return nil }
        let outer = tlvValue(0x53, in: r) ?? r
        let mid = tlvValue(0x88, in: outer) ?? outer
        return tlvValue(0x89, in: mid)
    }

    /// PIV management-key mutual authentication (GENERAL AUTHENTICATE, key ref 9B) with the
    /// supplied key — factory-default for an untouched key, or the retrieved PIN-protected
    /// key for a personalized one. TDES / AES-128/192/256 per the metadata algorithm; the
    /// block cipher runs on CommonCrypto (CryptoKit exposes no raw ECB). Returns true when
    /// the card accepts our witness (SW 9000).
    @available(iOS 26.0, *)
    private func mgmtAuth(_ card: TKSmartCard, alg: UInt8, key: Data) async -> Bool {
        let isAES = (alg == 0x08 || alg == 0x0A || alg == 0x0C)
        let block = isAES ? 16 : 8
        let ccAlg = isAES ? CCAlgorithm(kCCAlgorithmAES) : CCAlgorithm(kCCAlgorithm3DES)
        // Step 1 — ask the card for a witness (encrypted under the mgmt key).
        guard let (r1, sw1) = await tx(card, [0x00, 0x87, alg, 0x9B, 0x04, 0x7C, 0x02, 0x80, 0x00, 0x00], "4:AUTH1"),
              sw1 == 0x9000, let outer1 = tlvValue(0x7C, in: r1), let encWitness = tlvValue(0x80, in: outer1),
              let witness = cryptECB(encWitness, key: key, alg: ccAlg, op: CCOperation(kCCDecrypt)), witness.count == block else {
            return false
        }
        // Step 2 — return the decrypted witness + our own challenge.
        var chal = [UInt8](repeating: 0, count: block)
        _ = SecRandomCopyBytes(kSecRandomDefault, block, &chal)
        let d: [UInt8] = [0x80, UInt8(block)] + [UInt8](witness) + [0x81, UInt8(block)] + chal
        let bodyBytes: [UInt8] = [0x7C, UInt8(d.count)] + d
        let apdu2: [UInt8] = [0x00, 0x87, alg, 0x9B, UInt8(bodyBytes.count)] + bodyBytes + [0x00]
        guard let (_, sw2) = await tx(card, apdu2, "4:AUTH2") else { return false }
        return sw2 == 0x9000
    }

    // MARK: Spike crypto/APDU helpers (throwaway)

    private func hex(_ b: UInt8) -> String { String(format: "%02X", b) }
    private func algName(_ a: UInt8) -> String {
        switch a { case 0x03: "3DES"; case 0x08: "AES-128"; case 0x0A: "AES-192"; case 0x0C: "AES-256"; default: "?" }
    }

    /// Transmit one APDU, following 61xx GET RESPONSE chaining (a big object like a
    /// certificate comes back across several reads), logging the final SW + accumulated
    /// bytes. Returns (responseData-minus-SW, statusWord).
    private func tx(_ card: TKSmartCard, _ apdu: [UInt8], _ tag: String,
                    maskData: Bool = false) async -> (Data, UInt16)? {
        var accumulated = Data()
        var current = Data(apdu)
        while true {
            let resp: Data? = await withCheckedContinuation { cont in
                card.transmit(current) { r, _ in cont.resume(returning: r) }
            }
            guard let resp, resp.count >= 2 else { stamp("\(tag) ← ERR no data"); return nil }
            let bytes = [UInt8](resp)
            let sw1 = bytes[bytes.count - 2], sw2 = bytes[bytes.count - 1]
            accumulated.append(contentsOf: bytes[0..<bytes.count - 2])
            if sw1 == 0x61 {   // more data — GET RESPONSE, Le = sw2 (0 ⇒ 256)
                current = Data([0x00, 0xC0, 0x00, 0x00, sw2]); continue
            }
            let sw = (UInt16(sw1) << 8) | UInt16(sw2)
            let shown: String
            if maskData {   // secret payloads (a retrieved mgmt key) must not reach the screenshot-able log
                shown = "…masked…"
            } else {
                let dhex = accumulated.map { String(format: "%02X", $0) }.joined()
                shown = dhex.count > 120 ? String(dhex.prefix(120)) + "…" : dhex
            }
            stamp("\(tag) ← \(String(format: "%04X", sw)) [\(accumulated.count)B] \(shown)")
            return (accumulated, sw)
        }
    }

    private func dataFromHex(_ s: String) -> Data? {
        let clean = s.filter(\.isHexDigit)
        guard !clean.isEmpty, clean.count % 2 == 0 else { return nil }
        var out = [UInt8](); var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            guard let b = UInt8(clean[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return Data(out)
    }

    /// Acquire a live card: prefer an enumerated WIRED slot (no sheet); else create the NFC
    /// slot and poll ~20 s for the key. Returns a card with an open session.
    @available(iOS 26.0, *)
    private func acquireCard(_ label: String, pollMs: UInt64 = 300) async -> TKSmartCard? {
        guard let mgr = TKSmartCardSlotManager.default else { stamp("\(label): no manager"); return nil }
        let name: String
        if let wired = mgr.slotNames.first(where: { $0 != "Built-in NFC Slot" }) {
            name = wired; stamp("\(label): wired slot [\(wired)]")
        } else {
            stamp("\(label): createNFCSlot — hold the key to the top edge")
            let session: TKSmartCardSlotNFCSession? = await withCheckedContinuation { cont in
                mgr.createNFCSlot(message: "Malinois — present your key") { s, _ in cont.resume(returning: s) }
            }
            guard let session, let sname = session.slotName else { stamp("\(label): NFC slot failed"); return nil }
            slotSession = session; name = sname
        }
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 20 {
            let slot: TKSmartCardSlot? = await withCheckedContinuation { cont in
                mgr.getSlot(withName: name) { cont.resume(returning: $0) }
            }
            if let slot, let card = slot.makeSmartCard() {
                let ok: Bool = await withCheckedContinuation { cont in card.beginSession { o, _ in cont.resume(returning: o) } }
                if ok { return card }
                stamp("\(label): beginSession failed"); return nil
            }
            try? await Task.sleep(nanoseconds: pollMs * 1_000_000)
        }
        stamp("\(label): no card within 20 s"); return nil
    }

    @available(iOS 26.0, *)
    private func cleanup(_ card: TKSmartCard) {
        card.endSession()
        if let s = slotSession as? TKSmartCardSlotNFCSession { s.end() }
        slotSession = nil
    }

    /// ECB block-cipher for the management-key handshake (CryptoKit has no raw ECB).
    private func cryptECB(_ data: Data, key: Data, alg: CCAlgorithm, op: CCOperation) -> Data? {
        let blockSize = (alg == CCAlgorithm(kCCAlgorithm3DES)) ? kCCBlockSize3DES : kCCBlockSizeAES128
        var out = [UInt8](repeating: 0, count: data.count + blockSize)
        var moved = 0
        let status = data.withUnsafeBytes { dptr in
            key.withUnsafeBytes { kptr in
                CCCrypt(op, alg, CCOptions(kCCOptionECBMode),
                        kptr.baseAddress, key.count, nil,
                        dptr.baseAddress, data.count,
                        &out, out.count, &moved)
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(moved))
    }

    /// First top-level TLV with `tag` (1-byte tags; 1/2-byte length forms). Enough for the
    /// PIV structures here: 7C→80/81/82, and metadata 01/05.
    private func tlvValue(_ tag: UInt8, in data: Data) -> Data? {
        let b = [UInt8](data); var i = 0
        while i < b.count {
            let t = b[i]; i += 1
            guard i < b.count else { return nil }
            var len = Int(b[i]); i += 1
            if len == 0x81 { guard i < b.count else { return nil }; len = Int(b[i]); i += 1 }
            else if len == 0x82 { guard i + 1 < b.count else { return nil }; len = (Int(b[i]) << 8) | Int(b[i + 1]); i += 2 }
            guard i + len <= b.count else { return nil }
            if t == tag { return Data(b[i..<i + len]) }
            i += len
        }
        return nil
    }

    /// The 65-byte uncompressed EC point (04‖X‖Y) from a GENERATE response
    /// (7F49 → 86 41 04 …), located by the 0x86 tag to avoid the 2-byte 7F49 wrapper.
    private func extractECPoint(_ d: Data) -> Data? {
        let b = [UInt8](d); var i = 0
        while i + 1 < b.count {
            if b[i] == 0x86 {
                let len = Int(b[i + 1]); let start = i + 2
                if len == 65, start + len <= b.count, b[start] == 0x04 { return Data(b[start..<start + len]) }
            }
            i += 1
        }
        return nil
    }

    /// Probe 3 — CoreNFC comparison for the same sheet-under-GA question.
    func startCoreNFC() {
        guard NFCTagReaderSession.readingAvailable else {
            stamp("3: readingAvailable = false (simulator, or entitlement not granted)")
            return
        }
        let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
        session?.alertMessage = "Malinois item-14 spike"
        nfcSession = session
        stamp("3: begin() — does the sheet appear NOW?")
        session?.begin()
    }

    func stopCoreNFC() {
        nfcSession?.invalidate()
        stamp("3b: invalidate()")
    }
}

extension Spike14Model: NFCTagReaderSessionDelegate {
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        stamp("3: SHEET ACTIVE (didBecomeActive)")   // the money line under GA
    }
    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        stamp("3: invalidated — \(error.localizedDescription)")
        DispatchQueue.main.async { self.nfcSession = nil }
    }
    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        stamp("3: detected \(tags.count) tag(s)")
    }
}

struct Spike14View: View {
    @StateObject private var model = Spike14Model()
    @State private var confirmingReset = false
    /// 0d coexistence leg: the REAL SirenPlayer (same audio session, category, and
    /// full-volume looped asset the feature will sound over). Created on first use;
    /// popping this screen deallocates it, which also silences a forgotten siren.
    @State private var siren: SirenPlayer?
    @State private var sirenOn = false

    var body: some View {
        List {
            Section("Personalized key (leave blank for a default key)") {
                SecureField("Mgmt key hex — if you set + hold it", text: $model.pivMgmtKeyHex)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("PIV PIN — for a --protect key", text: $model.pivPIN)
                    .keyboardType(.numberPad)
                Toggle("Allow overwriting 9E (probe 4)", isOn: $model.allowOverwrite9E)
            }
            Section("Probes") {
                Button("1 · Smart-card slot probe") { model.probeSlots() }
                Button("2 · Create NFC slot (route-A transport)") { model.createNFCSlot() }
                Button("2b · End NFC slot session") { model.endNFCSlot() }
                Button("2c · Probe live slot (hold a card)") { model.probeLiveSlot() }
                Button("2d · SELECT PIV applet (hold the key)") { model.selectPIV() }
                Button("4 · Enroll: mgmt-auth + GENERATE 9E") { model.enroll() }
                Button("5 · Disarm sim: sign + CryptoKit verify") { model.disarmSim() }
                Button("0 · RESET PIV (destructive — dedicated key only)", role: .destructive) {
                    confirmingReset = true
                }
                Button("3 · CoreNFC tag session (comparison)") { model.startCoreNFC() }
                Button("3b · End CoreNFC session") { model.stopCoreNFC() }
            }
            Section("0d — siren coexistence + disarm timing") {
                Toggle("Siren (REAL player, full volume — loud)", isOn: $sirenOn)
                    .onChange(of: sirenOn) { _, on in
                        if on {
                            let s = siren ?? SirenPlayer()
                            siren = s
                            s.start()
                        } else {
                            siren?.stop()
                        }
                    }
                Button("6 · Disarm timing (tap ×5, re-present the key)") { model.disarmTiming() }
            }
            Section("Log — screenshot this; the timestamps carry the story") {
                if model.log.isEmpty {
                    Text("No entries yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("Item 14 spike")
        .alert("Reset the PIV applet?", isPresented: $confirmingReset) {
            Button("Reset — wipe this key's PIV", role: .destructive) { model.resetPIV() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wipes ALL PIV keys and certificates, then resets PIN, PUK, and the "
                 + "management key to factory defaults. Dedicated test key only — never "
                 + "a key holding real credentials.")
        }
    }
}

#endif
