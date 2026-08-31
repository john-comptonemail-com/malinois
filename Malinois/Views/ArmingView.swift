//
//  ArmingView.swift
//  MALINOIS
//
//  The pre-arm flow: Guided Access coaching with a live enabled/disabled
//  indicator, then the grace countdown, then the calibration progress.
//

import SwiftUI

struct ArmingView: View {
    @EnvironmentObject private var engine: MonitoringEngine
    @EnvironmentObject private var entitlements: ProEntitlements
    @EnvironmentObject private var settings: AppSettings
    @State private var showCancelPIN = false

    var body: some View {
        VStack(spacing: 28) {
            switch engine.state {
            case .guidedAccessCheck: guidedAccessStep
            case .arming:            graceStep
            case .calibrating:       calibrationStep
            default:                 EmptyView()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { engine.refreshGuidedAccess() }
        // An unused lift must not linger past the arming screen (M2): leaving without
        // arming expires it, so a later arm re-asserts the owner's requirement.
        .onDisappear { engine.clearGuidedAccessLift() }
        // A crash-recovery re-arm can only be stopped with the PIN (R-04).
        .fullScreenCover(isPresented: $showCancelPIN) {
            PINEntryView(title: "Enter PIN to stop re-arming") {
                showCancelPIN = false
                engine.disarm()
            } onCancel: { showCancelPIN = false }
        }
    }

    /// Cancel the arm — directly if the owner started it, but PIN-gated if it was an
    /// automatic re-arm after a crash (so a thief can't just tap it away).
    private func cancelArming() {
        if engine.armWasAutoRecovered { showCancelPIN = true }
        else { engine.cancelArming() }
    }

    /// Battery/power guidance for the grace screen, accurate to the current camera-readiness
    /// mode. The old copy assumed an always-warm camera ("keep it on a charger… warm camera
    /// drains the battery"), which is wrong for **Auto** (warm only while charging) and
    /// **Battery saver** (never warm) — on battery those cold-start the camera on a trigger,
    /// so there's no continuous camera drain to warn about.
    private var batteryGuidance: String {
        var parts: [String] = []
        if settings.isEnabled(.camera) {
            switch settings.cameraReadiness {
            case .instant:
                parts.append("Instant mode keeps the camera warm for zero-delay capture, which drains the battery — best kept on a charger.")
            case .auto:
                parts.append("On a charger the camera stays warm for instant capture; on battery it cold-starts on a trigger (~1–2 s) to save power.")
            case .batterySaver:
                parts.append("Battery saver cold-starts the camera on a trigger (~1–2 s), so it sips power on battery.")
            }
        } else {
            parts.append("The screen stays on (black) while armed — a light draw.")
        }
        if settings.isEnabled(.vision) && settings.isEnabled(.camera) {
            // Never silently unprotected: say plainly when this tripwire won't be running, and
            // WHICH reason applies. The first branch is the device's own answer — whether the
            // tap actually came up — which beats predicting it from the camera setting.
            if engine.visionTapUnavailable {
                parts.append("Vision detection isn't running on this device with the current camera setup — there wasn't capacity for it alongside the capture. The other tripwires still run.")
            } else if settings.effectiveCameraPosition(pro: entitlements.proActive) == .both
                        && CameraController.supportsMultiCam {
                parts.append("With the camera set to Both, vision detection watches through the front camera.")
            } else if settings.cameraReadiness != .instant {
                parts.append("Vision detection watches through the camera only while it's warm — on a charger (Auto) or in Instant mode. On battery it's off; the other tripwires still run.")
            }
        }
        // The capture-mode setting does not apply in Siren mode (F4), and until now nothing in
        // the app said so: Settings offered "3-second clip" while every trigger would in fact
        // be photographed. Same rule as the tripwire caveats above — a setting that won't take
        // effect has to be stated before arming, not discovered in the Event Log afterwards.
        if settings.isEnabled(.camera), settings.responseMode == .siren,
           settings.effectiveCaptureMode(pro: entitlements.proActive).isClip {
            parts.append("Siren mode photographs each trigger instead of filming it — recording a clip needs the microphone, and that would silence the alarm. Your clip setting applies again when the response is Alert.")
        }
        // Both-camera clips are silent. Said before arming rather than discovered on playback
        // after an incident, when the setting can no longer be changed for that night.
        // Irrelevant under Siren, where nothing is filmed at all — the caveat above covers that.
        if settings.isEnabled(.camera), settings.responseMode != .siren,
           settings.effectiveCameraPosition(pro: entitlements.proActive) == .both,
           CameraController.supportsMultiCam,
           settings.effectiveCaptureMode(pro: entitlements.proActive).isClip {
            parts.append("With the camera on Both, clips are video only and will not contain audio.")
        }
        if settings.isEnabled(.power) {
            parts.append("A power-connection change (plugging in or unplugging) is itself a tripwire.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Guided Access coaching

    private var guidedAccessStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                disarmInstructions

                HStack {
                    Button("Cancel", role: .cancel) { cancelArming() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        engine.confirmGuidedAccessAndStartGrace()
                    } label: {
                        Text("Start countdown").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.armingBlockedByGuidedAccess)
                }

                if engine.armingBlockedByGuidedAccess { guidedAccessRequiredNotice }

                guidedAccessRecommendation
            }
            .padding()
        }
    }

    /// Shown when the owner has turned on "Require Guided Access" and it's currently off, so
    /// arming is refused. Offers BOTH remedies inline — turn Guided Access on (steps below),
    /// or drop the requirement — so this never dead-ends someone who can't or won't set up
    /// Guided Access right now.
    private var guidedAccessRequiredNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Guided Access is required to arm", systemImage: "lock.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("You've set Malinois to refuse arming without it. Follow the steps below to turn it on — or lift the requirement for this arm if you're just testing. Your setting stays on; turn it off permanently in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Don't require it for this arm") {
                // One-shot, logged, and the stored setting is untouched (eighth review, M2):
                // the old action here flipped `settings.requireGuidedAccess` permanently —
                // no PIN (arming is deliberately ungated), no log entry, and the owner's
                // future arms silently lost the requirement. Permanent changes belong in
                // Settings, behind its PIN.
                engine.liftGuidedAccessRequirementForThisArm()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
    }

    /// Guided Access status + coaching, shown below the arm controls. Recommended by
    /// default; enforced only if the owner turns on "Require Guided Access".
    @ViewBuilder
    private var guidedAccessRecommendation: some View {
        if engine.guidedAccessEnabled {
            header("Guided Access is on",
                   subtitle: "The device is locked to Malinois — a snoop can't switch apps or power it off.")
            guidedAccessIndicator
        } else {
            header("Recommended: turn on Guided Access",
                   subtitle: "It locks the device to Malinois so a snoop can't switch apps or power it off. Strongly recommended — but you can arm without it, for a first try or just to see how it works.")

            guidedAccessIndicator

            // The warning above says Guided Access is off. This says the part that carries
            // meaning: it was ON when you last disarmed, so something turned it off in
            // between. Malinois cannot say when or by whom — it can't observe Guided Access
            // while suspended at all — so this claims only what it can support.
            if engine.guidedAccessOffSinceDisarm {
                Label("Guided Access was ON when you last disarmed, and is off now. Malinois can't tell when it changed or who changed it — but you didn't leave it this way.",
                      systemImage: "exclamationmark.shield.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
            }

            VStack(alignment: .leading, spacing: 12) {
                instruction(1, "Open Settings → Accessibility → Guided Access and turn it on (one-time setup).")
                instruction(2, "In Guided Access → Passcode Settings, set a Guided Access passcode. Make it DIFFERENT from your device passcode, so someone who knows your unlock code still can't exit.")
                instruction(3, "Back in Malinois, triple-click the side (or Home) button to bring up Guided Access.")
                instruction(4, "Tap Start (top-right) to lock the device to Malinois.")
                instruction(5, "If you use Voice Control, turn it OFF (Settings → Accessibility → Voice Control) — it keeps working under Guided Access and can be told to close the app.")
                instruction(6, "For Siren mode: in Guided Access → Options, turn OFF Volume Buttons — otherwise a thief can turn the siren down.")
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))

            Label("Without Guided Access, a snoop could switch away from Malinois or power it off before the evidence uploads.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    /// Shown on the arming screen so the owner knows how to get back in later —
    /// the armed screen is black and gives no hints.
    private var disarmInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Disarm Instructions", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
            instruction(1, "On the blank screen, press and hold anywhere for 5 seconds. The screen brightens and a PIN pad appears.")
            instruction(2, "Enter your Malinois PIN to disarm. This works even while Guided Access is still on.")
            instruction(3, "Then triple-click the side (or Home) button and enter your Guided Access passcode to end Guided Access.")
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.08)))
    }

    private var guidedAccessIndicator: some View {
        HStack(spacing: 12) {
            Image(systemName: engine.guidedAccessEnabled ? "checkmark.shield.fill" : "shield.slash")
                .font(.title)
                .foregroundStyle(engine.guidedAccessEnabled ? .green : .orange)
            VStack(alignment: .leading) {
                Text(engine.guidedAccessEnabled ? "Guided Access: ON" : "Guided Access: OFF")
                    .font(.headline)
                Text(engine.guidedAccessEnabled
                     ? "Ready to arm."
                     : "Turn it on before you leave the device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12)
            .fill((engine.guidedAccessEnabled ? Color.green : Color.orange).opacity(0.12)))
    }

    // MARK: - Grace countdown

    private var graceStep: some View {
        VStack(spacing: 20) {
            Text("Arming in")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("\(engine.graceRemaining)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("Set the device down and step away. The screen will go black.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if engine.armWasAutoRecovered {
                Label("Re-arming after an interrupted session — PIN required to stop.",
                      systemImage: "arrow.clockwise.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if engine.sirenVolumeLow {
                Label("Media volume is low — turn it up now so the siren is audible (it can't override the volume buttons).",
                      systemImage: "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if !entitlements.proActive {
                Label("Local protection only — evidence stays on this device (it won't back up to iCloud or survive a power-off), single camera, 3s clips.",
                      systemImage: "icloud.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Label(batteryGuidance, systemImage: "battery.100")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Cancel", role: .cancel) { cancelArming() }
                .buttonStyle(.bordered)
                .padding(.top)
        }
    }

    // MARK: - Calibration

    private var calibrationStep: some View {
        VStack(spacing: 20) {
            if engine.showingCalibrationReview, let cal = engine.lastCalibration {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.tint)
                Text("Calibrated")
                    .font(.title2.weight(.semibold))
                CalibrationSummaryView(summary: cal)
                    .padding(.horizontal, 24)
                Text("Arming…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(value: engine.calibrationProgress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 40)
                Text("Calibrating sensors…")
                    .font(.headline)
                Text("Learning the resting position and ambient noise. Keep still.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Helpers

    private func header(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title.weight(.bold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func instruction(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text).font(.subheadline)
        }
    }
}
