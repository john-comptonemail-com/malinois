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

import Combine
import SwiftUI

struct ArmedView: View {
    @EnvironmentObject private var engine: MonitoringEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var camera: CameraController

    // The PIN pad follows the engine's disarm-entry flag (not local state), so the
    // engine's inactivity timeout can dismiss it and return to covert.

    /// True while a finger is down, so the touch trip is logged once per press. A `GestureState`
    /// (item 120, F6): SwiftUI resets it when the touch ends AND when iOS cancels it (the Guided
    /// Access triple-click, leaving the app). The `@State` flag before it was cleared only when a
    /// touch ended, so after a cancelled touch every later tap was ignored until a full hold.
    @GestureState private var fingerDown = false

    private let holdSeconds: Double = 5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if engine.disarmEntryActive {
                PINEntryView(title: "Enter PIN to disarm", onSuccess: {
                    OnboardingState.hasDisarmedOnce = true   // the hold is learned: the warning drops its tip (item 107)
                    engine.disarm()   // restores brightness + returns to Home
                }, onCancel: {
                    engine.endDisarmEntry()   // back to covert black
                }, onActivity: { engine.noteDisarmActivity() },
                onFailure: { engine.noteWrongDisarmPIN() })   // a wrong PIN is on the record (item 49)
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
                            .onEnded { _ in withAnimation { engine.beginDisarmEntry() } }
                    )
                    // Runs alongside purely to observe the press itself: `fingerDown` turns on at
                    // press-DOWN and off at release or cancellation, and the change below logs the
                    // touch trip and closes the attribution window. Neither can reveal the pad.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .updating($fingerDown) { _, down, _ in down = true }
                    )
            }
        }
        .onChange(of: fingerDown) { _, down in down ? notePressDown() : notePressUp() }
        .overlay {
            // Tamper warning (alert / siren modes). Non-interactive so the
            // press-and-hold to disarm still works underneath it. An escalation
            // (jamming blackout / tamper flood) shows its own aggressive warning.
            // Until the owner's first disarm it also says how to disarm (item 107).
            if engine.alertActive && !engine.disarmEntryActive {
                // Clamped at the render (R1-L4, the deviceLabel rule): bounded and
                // never blank, whatever the stored value or decode admitted.
                AlertMessageView(
                    message: MonitoringEngine.sanitizedAlertMessage(
                        engine.escalation?.message ?? settings.alertMessage,
                        fallback: AppSettings.defaultAlertMessage),
                    disarmTip: DisarmTip.alertTip(hasDisarmedOnce: OnboardingState.hasDisarmedOnce))
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
        // The status bar stays hidden while recording (owner ruling 2026-09-06, item 73): iOS
        // draws its camera and microphone indicator in the Dynamic Island or the top corner
        // whatever the app does with the bar — seen on device — so un-hiding it lit a strip of
        // clock, carrier and battery over the black screen for nothing. The REC badge and its
        // brightness floor remain the app's own indication (guideline 2.5.14).
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    /// Press-down, once per press (`fingerDown` turning on). Reveals nothing on its own — that's
    /// the long-press gesture's job — it only records the interaction.
    private func notePressDown() {
        // Open the owner-attribution window at press-down, BEFORE reporting the touch, so
        // the touch that starts a legitimate disarm hold is a candidate for attribution
        // rather than an un-attributed self-tamper (R-02). Confirmed by a correct PIN;
        // discarded on early release or a failed entry.
        engine.noteDisarmCandidate()
        // Any contact counts as a touch trip (F-08): report on press-DOWN, not only on a
        // sub-second release. A lingering finger, a drag, or the start of the disarm hold
        // itself is exactly the interaction a snoop makes — and it must be logged. Touch has
        // no switch (item 83, ADR 0015), so there is no setting to ask.
        engine.reportTouch()
    }

    /// Release or cancellation (`fingerDown` turning off). If the pad didn't open, this was a tap
    /// rather than a disarm, so close the attribution window and let that touch stand as evidence.
    private func notePressUp() {
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

extension View {
    /// The REC badge at the top trailing corner while `live` says a camera session runs, in a row of
    /// its own above the screen's content so it never covers text, at any text size (item 120: the
    /// arming screens and the recovery PIN, F4, V3, V4). The armed screen and Test Sensors, which
    /// have no text beneath it, overlay theirs.
    func recordingBadge(whileLive live: AnyPublisher<Bool, Never>) -> some View {
        modifier(RecordingBadgeRow(live: live))
    }
}

private struct RecordingBadgeRow: ViewModifier {
    let live: AnyPublisher<Bool, Never>
    @State private var running = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, alignment: .trailing, spacing: 0) {
                ZStack {
                    if running {
                        RecordingIndicator()
                            .padding(.trailing, 16)
                            .padding(.bottom, 4)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: running)
            }
            .onReceive(live) { running = $0 }
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
        .reportedOnScreen("REC")
    }
}

/// The full-screen tamper warning shown on trigger (alert / siren modes).
struct AlertMessageView: View {
    let message: String
    /// How to disarm, shown under the warning until the owner's first disarm, then `nil`
    /// (`DisarmTip.alertTip`, item 107, ADR 0044). The hold only opens the PIN pad: a running
    /// alarm stays up until a correct PIN, and a wrong one is recorded and counts toward the
    /// lockout. Still, after the first disarm the owner knows it and a later intruder is not shown it.
    var disarmTip: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 68))
                .foregroundStyle(.red)
            Text(message)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if let disarmTip {
                VStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill")
                        .font(.title2)
                    Text(disarmTip)
                        .font(.callout.weight(.semibold))
                    Text(DisarmTip.alertTipFootnote)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.1)))
                .padding(.top, 10)
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .overlay(
            Rectangle().stroke(Color.red.opacity(0.85), lineWidth: 4).ignoresSafeArea()
        )
    }
}
