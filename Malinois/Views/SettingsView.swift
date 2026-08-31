//
//  SettingsView.swift
//  Malinois
//
//  Active sensors, per-sensor sensitivity, grace period, capture mode, trigger
//  mode, Guided Access enforcement, PIN change, and iCloud status.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var cloud: CloudExfiltrator
    @EnvironmentObject private var entitlements: ProEntitlements
    @Environment(\.dismiss) private var dismiss

    @State private var showChangePIN = false
    @State private var showPaywall = false
    @State private var showPurgeDialog = false
    @State private var purgeNote: String?

    var body: some View {
        NavigationStack {
            Form {
                proSection
                sensorsSection
                sensitivitySection
                triggerSection
                responseSection
                captureSection
                securitySection
                iCloudSection
                consideringSection
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
            .task { await cloud.refreshAccountState() }
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
            } else {
                // Free OR trial — always offer the purchase (buyable during the trial too).
                Button { showPaywall = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label {
                                Text(entitlements.status == .trial ? "Malinois Pro — trial" : "Unlock Malinois Pro")
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
                             ? "Everything's unlocked during your trial. Buy now to keep it — one-time \(entitlements.product?.displayPrice ?? "$9.99")."
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
                            Label("On, but not running — \(sensor.displayName) needs Pro. Your choice is saved and resumes if you upgrade.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        } header: {
            Text("Active sensors")
        } footer: {
            Text("Any enabled tripwire fires on its own. Vision runs only while the camera is warm; on battery the other tripwires still cover you.")
        }
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
        } header: {
            Text("Arming")
        } footer: {
            Text("Any enabled tripwire fires on its own. Time to set the device down and step away before the watch goes live.")
        }
    }

    private var responseSection: some View {
        Section {
            Picker("Response", selection: Binding(
                get: { settings.responseMode },
                set: { settings.responseMode = $0 })) {
                ForEach(ResponseMode.allCases) { Text($0.displayName).tag($0) }
            }
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

            // Lives here, not under iCloud: it's a siren behaviour, and it overrides the
            // response mode above — Stealth included.
            Toggle(isOn: Binding(
                get: { settings.jammingResponse },
                set: { settings.jammingResponse = $0 })) {
                VStack(alignment: .leading) {
                    Text("Alarm on suspected attack")
                    Text("Abandon covert mode when the pattern looks like a sophisticated attack. Suspected jamming (total signal loss while armed and stationary) sounds the siren even in Stealth. A sensor flood shows the on-screen warning — it sirens only if your response is Siren.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("When triggered")
        } footer: {
            if settings.responseMode == .siren {
                Text("iOS gives no app control of the hardware volume buttons, so the alarm plays at whatever the media volume is. For Siren mode, turn OFF Volume Buttons in Guided Access → Options so it can't be turned down while armed.")
            }
        }
    }

    private var responseHint: String {
        switch settings.responseMode {
        case .alert:   return "Evidence is captured silently, then a warning appears on screen — a deterrent that also serves as the disarm prompt."
        case .stealth: return "Fully covert: the screen stays black and nothing is shown. Evidence is still captured and uploaded."
        case .siren:   return "Captures evidence, shows the warning, and sounds a loud alarm (plays even on silent) until the tamper stops or you disarm."
        }
    }

    private var captureSection: some View {
        Section {
            // The camera lives HERE, not under Active sensors: it isn't a tripwire, and
            // sitting beside Vision made it read like one (owner request, 2026-08-23).
            Toggle(isOn: binding(for: .camera)) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(SensorType.camera.displayName, systemImage: SensorType.camera.iconName)
                    Text(SensorType.camera.summary)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("On trigger", selection: Binding(
                get: { settings.captureMode },
                set: { settings.captureMode = $0 })) {
                ForEach(CaptureMode.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Camera", selection: Binding(
                get: { settings.cameraPosition },
                set: { settings.cameraPosition = $0 })) {
                ForEach(CameraChoice.allCases) { Text($0.displayName).tag($0) }
            }
            if settings.cameraPosition == .both {
                Text(CameraController.supportsMultiCam
                     ? (settings.captureMode.isClip
                        ? "Captures the front and rear cameras simultaneously. Video only; clips will not contain audio."
                        : "Captures the front and rear cameras simultaneously.")
                     : "This device doesn't support multi-cam — “Both” will capture the front camera only.")
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
                    Text("Refuse to arm unless Guided Access is on. It's what stops a snoop swiping the app away or powering the device off — leave this off while you're still testing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(
                get: { settings.scramblePINPad },
                set: { settings.scramblePINPad = $0 })) {
                VStack(alignment: .leading) {
                    Text("Scramble PIN pad")
                    Text("Randomizes the disarm keypad each time, so someone watching can't learn your PIN from finger positions. Slower to enter — leave off if you rely on muscle memory.")
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
            Text("Guided Access (single-app mode) is strongly recommended while armed — it stops a snoop from switching away or powering off. Malinois coaches you through it on the arming screen.")
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
                    Text("Cross-device alerts")
                    Text("Alert every device on this iCloud account the moment any of them is triggered. One switch for the whole account, applied immediately from any device: off removes the alerts for all devices, on restores them — no re-arm needed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let subscriptionNote {
                Text(subscriptionNote).font(.caption).foregroundStyle(.orange)
            }
            Picker("Full-media retention", selection: Binding(
                get: { settings.cloudRetention },
                set: { settings.cloudRetention = $0 })) {
                ForEach(CloudRetention.allCases) { Text($0.displayName).tag($0) }
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
            Text("iCloud")
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
        guard entitlements.proActive else { return }   // free tier has no subscription to manage
        subscriptionNote = nil
        Task {
            let landed = await cloud.setCrossDeviceAlerts(enabled)
            subscriptionNote = landed ? nil
                : "iCloud couldn't be updated — flip the switch again to retry."
        }
    }

    /// BACKLOG 14's demand-check line, added at the owner's direction (2026-08-30). The
    /// feature is now PLANNED (item 14's phases await spike results), so this line's job is
    /// priority signal and early contact with real users of it, not a build/no-build gate.
    /// Deliberately text-only, no tappable link: the app currently ships no outbound links
    /// at all, and opening that door is item 21's own decision, not a side effect of a
    /// survey line. The address is the same support@ every other user-facing surface shows.
    private var consideringSection: some View {
        Section {
            Text("Planned: hardware-key disarm — Malinois couldn't be disarmed without a physical security key you enroll (FIDO2/NFC). If you'd use it, email support@comptonemail.com and say so.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Considering")
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
            ? "Some records couldn't be deleted — check iCloud and try again."
            : "Deleted full media from \(result.eventsExamined) event(s)."
    }

    // MARK: - Bindings

    private func binding(for sensor: SensorType) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(sensor) },
            set: { on in
                if on { settings.enabledSensors.insert(sensor) }
                else { settings.enabledSensors.remove(sensor) }
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
