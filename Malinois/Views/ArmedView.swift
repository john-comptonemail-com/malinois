//
//  ArmedView.swift
//  Malinois
//
//  The covert armed screen. Full-screen black overlay (the engine has already
//  forced brightness to 0 and disabled the idle timer). A quick TAP is logged as
//  an interaction attempt (the TouchMonitor tripwire); a press-and-HOLD reveals
//  the disarm PIN pad. Using a hold (not a hidden corner) makes disarming
//  reliable, and — because a hold is distinct from a tap — the reveal gesture
//  doesn't trip the sensor or flash the screen.
//
//  Disarm sequence for the owner:
//    1. Press and hold anywhere for 5 seconds. The engine raises the brightness
//       and the PIN pad appears (works even while Guided Access is still on).
//    2. Enter the MALINOIS PIN to disarm; the Home screen returns.
//    3. Then triple-click the side button and enter the Guided Access passcode
//       to end Guided Access.
//

import SwiftUI

struct ArmedView: View {
    @EnvironmentObject private var engine: MonitoringEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var camera: CameraController

    // The PIN pad follows the engine's disarm-entry flag (not local state), so the
    // engine's inactivity timeout can dismiss it and return to covert.

    /// True while a finger is down, so the touch trip is logged once per press.
    @State private var pressActive = false

    private let holdSeconds: Double = 5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if engine.disarmEntryActive {
                PINEntryView(title: "Enter PIN to disarm", onSuccess: {
                    engine.disarm()   // restores brightness + returns to Home
                }, onCancel: {
                    engine.endDisarmEntry()   // back to covert black
                }, onActivity: { engine.noteDisarmActivity() })
                .overlay(alignment: .top) { armedDurationBadge }
                .transition(.opacity)
            } else {
                // Full-screen black layer: a quick tap logs a touch trip; a
                // press-and-hold reveals the disarm pad (and raises brightness so
                // the pad is visible). A hold is separate from a tap, so revealing
                // the pad never trips the sensor.
                Color.black
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    // The reveal is a real 5-second press, enforced by SwiftUI's own gesture
                    // machinery: it fires ONLY if the finger stays down that long, and no
                    // event is needed to "cancel" it. The previous hand-rolled version
                    // scheduled the reveal on press-down and relied on a release callback to
                    // cancel it — so any missed release opened the pad on a mere tap, which
                    // also silenced the alarm (an open pad suppresses a fresh alert).
                    // `maximumDistance` is deliberately huge: the default (10pt) cancels on
                    // the slightest drift, which made a 5-second hold nearly impossible.
                    .gesture(
                        LongPressGesture(minimumDuration: holdSeconds,
                                         maximumDistance: .greatestFiniteMagnitude)
                            .onEnded { _ in
                                withAnimation { engine.beginDisarmEntry() }
                                pressActive = false
                            }
                    )
                    // Runs alongside purely to observe the press itself — log the touch trip
                    // on press-DOWN and close the attribution window on release. Neither can
                    // reveal the pad, so if a release event is ever missed the worst outcome
                    // is a stale attribution window that expires on its own.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in notePressDown() }
                            .onEnded { _ in notePressUp() }
                    )
            }
        }
        .overlay {
            // Tamper warning (alert / siren modes). Non-interactive so the
            // press-and-hold to disarm still works underneath it. An escalation
            // (jamming blackout / tamper flood) shows its own aggressive warning.
            if engine.alertActive && !engine.disarmEntryActive {
                AlertMessageView(message: engine.escalation?.message ?? settings.alertMessage)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay {
            // Capture flash: white screen that lights the scene for the front
            // camera, then disappears. Non-interactive so it never blocks the
            // disarm hold. Suppressed while the PIN pad is up — during a lit clip
            // the flash persists for the whole recording, and it would otherwise
            // cover the pad with an un-enterable white screen.
            if engine.captureFlash && !engine.disarmEntryActive {
                Color.white.ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Recording indicator (Guideline 2.5.14): a clear, always-on-top REC badge
            // whenever any capture session is live. Deliberately NOT gated on response
            // mode, disarm state, or any setting — it cannot be disabled, and the engine
            // raises the screen brightness while it shows so the screen is never blank
            // during recording (see MonitoringEngine.brightnessLevel).
            if camera.isRecordingActive {
                RecordingIndicator()
                    .safeAreaPadding(.top, 18)
                    .padding(.trailing, 18)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: engine.alertActive)
        .animation(.easeInOut(duration: 0.2), value: camera.isRecordingActive)
        // A tactile confirmation the moment the 5-second hold registers and the pad
        // reveals — the owner feels it without needing to see the (still-black) screen.
        .sensoryFeedback(trigger: engine.disarmEntryActive) { _, revealed in revealed ? .impact(weight: .medium) : nil }
        // While recording, show the status bar too, so the SYSTEM camera indicator
        // (green dot) is also visible alongside the in-app badge.
        .statusBarHidden(!camera.isRecordingActive)
        .persistentSystemOverlays(.hidden)
    }

    /// Press-down, once per press. Reveals nothing on its own — that's the long-press
    /// gesture's job — it only records the interaction.
    private func notePressDown() {
        guard !pressActive else { return }
        pressActive = true
        // Open the owner-attribution window at press-down, BEFORE reporting the touch, so
        // the touch that starts a legitimate disarm hold is a candidate for attribution
        // rather than an un-attributed self-tamper (R-02). Confirmed by a correct PIN;
        // discarded on early release or a failed entry.
        engine.noteDisarmCandidate()
        // Any contact counts as a touch trip (F-08): report on press-DOWN, not only on a
        // sub-second release. A lingering finger, a drag, or the start of the disarm hold
        // itself is exactly the interaction a snoop makes — and it must be logged.
        if settings.isEnabled(.touch) { engine.reportTouch() }
    }

    /// Release. If the pad didn't open, this was a tap rather than a disarm, so close the
    /// attribution window and let that touch stand as evidence.
    private func notePressUp() {
        pressActive = false
        if !engine.disarmEntryActive { engine.cancelDisarmCandidate() }
    }

    /// Live "Armed for H:MM:SS" shown above the disarm pad.
    @ViewBuilder
    private var armedDurationBadge: some View {
        if let since = engine.armedSince {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Armed for \(context.date.timeIntervalSince(since).clockString)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            // Safe-area-relative so it clears the Dynamic Island on all models,
            // instead of a hardcoded top inset.
            .safeAreaPadding(.top, 24)
        }
    }
}

/// The always-on-top recording badge: red dot + "REC". Shown whenever a capture session is
/// live (2.5.14). The dot pulses so it reads as "recording now", not decoration.
struct RecordingIndicator: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.red)
                .frame(width: 11, height: 11)
                .opacity(pulsing ? 0.35 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            Text("REC")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(Capsule().strokeBorder(Color.red.opacity(0.9), lineWidth: 1.5))
        .onAppear { pulsing = true }
        .accessibilityLabel("Recording in progress")
    }
}

/// The full-screen tamper warning shown on trigger (alert / siren modes).
struct AlertMessageView: View {
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 68))
                .foregroundStyle(.red)
            Text(message)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            // No disarm-gesture hint here: the owner learns the hold on the arming
            // screen; printing it on the tamper alert would hand a thief the bypass.
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .overlay(
            Rectangle().stroke(Color.red.opacity(0.85), lineWidth: 4).ignoresSafeArea()
        )
    }
}
