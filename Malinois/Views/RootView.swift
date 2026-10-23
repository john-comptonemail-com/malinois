//
//  RootView.swift
//  Malinois
//
//  Routes between first-launch PIN setup, the disarmed home, the arming flow,
//  and the covert armed (black) screen based on engine state.
//

import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var engine: MonitoringEngine
    @EnvironmentObject private var entitlements: ProEntitlements
    @Environment(\.scenePhase) private var scenePhase
    @State private var needsPINSetup = KeychainService.pinPresence == .absent
    // Retained PINs must be verified after a reinstall; missing credentials with known
    // evidence need device-owner recovery. Storage errors must never mean open setup.
    @State private var recovery: KeychainService.RecoveryKind? = KeychainService.pendingRecovery
    @State private var pinStateUnresolved = KeychainService.pinPresence == .sealedByLock

    /// One-time trial explainer, shown between setup and Home — and only when there is a trial
    /// to explain. The trial starts at first launch, so without it the first experience silently
    /// *is* Pro and the eventual lapse reads as features being taken away. During Early-Access
    /// (BACKLOG 66) and for a purchase nothing expires, so setup goes straight to Home: as little
    /// friction as possible before the first arm (owner, 2026-09-04). Only for genuine first-time
    /// setup — a returning owner coming through PIN recovery has seen it, and the flag survives
    /// in UserDefaults.
    @State private var showTrialWelcome = false

    /// One-time Guided Access nudge, evaluated when a session ends (see `maybePromptGuidedAccess`).
    @State private var showGuidedAccessPrompt = false

    var body: some View {
        Group {
            if pinStateUnresolved, engine.state == .disarmed {
                VStack(spacing: 20) {
                    Text("PIN storage unavailable").font(.headline)
                    Text("Unlock this device, then retry. Your PIN and evidence have not been reset.")
                        .multilineTextAlignment(.center)
                    Button("Retry", action: refreshPINStateIfUnresolved)
                }.padding(32)
            } else if let recovery {
                PINContinuityView(kind: recovery) { finishRecovery() }
            } else if needsPINSetup {
                PINSetupView {
                    needsPINSetup = false
                    showTrialWelcome = !OnboardingState.hasSeenTrialWelcome && entitlements.status == .trial
                }
            } else {
                switch engine.state {
                case .disarmed:
                    HomeView()
                case .guidedAccessCheck, .arming, .calibrating:
                    ArmingView()
                case .armed, .triggered:
                    ArmedView()
                }
            }
        }
        .animation(.easeInOut, value: engine.state)
        // Don't leave the whole system dimmed if the app is backgrounded while
        // armed; re-apply the covert/alert brightness when it returns.
        .onChange(of: scenePhase) { _, phase in
            engine.handleScenePhase(phase == .active)
            if phase == .active { refreshPINStateIfUnresolved() }
            // `.background` specifically, not `.inactive`: the latter fires for Control Centre,
            // the notification shade and call banners, none of which stop monitoring.
            if phase == .background { engine.handleEnteredBackground() }
        }
        // The sealed case's other exit: protected data becoming available on a background-
        // launched process, before any foreground activation delivers a scene-phase change.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            refreshPINStateIfUnresolved()
        }
        // Fires when a watch ends: `lastArmedDuration` is set only by `disarm()`, and only for a
        // session that actually went live — so cancelling the arming flow never triggers this.
        .onChange(of: engine.lastArmedDuration) { _, duration in
            guard duration != nil else { return }
            maybePromptGuidedAccess()
        }
        .fullScreenCover(isPresented: $showTrialWelcome) {
            TrialWelcomeView { OnboardingState.hasSeenTrialWelcome = true; showTrialWelcome = false }
        }
        .fullScreenCover(isPresented: $showGuidedAccessPrompt) {
            GuidedAccessPromptView {
                OnboardingState.hasSeenGuidedAccessPrompt = true
                showGuidedAccessPrompt = false
            }
        }
    }

    /// Offer the Guided Access walkthrough once, after the owner has actually watched a session
    /// run. The arming screen already coaches this, but it's easy to skim past while impatient to
    /// arm; afterwards there's context for why it matters. Skipped entirely when Guided Access is
    /// already on — telling an owner who set it up that they're unprotected is how a security
    /// prompt gets trained into reflexive dismissal.
    private func maybePromptGuidedAccess() {
        guard OnboardingState.shouldPromptForGuidedAccess(
                completedASession: true,
                guidedAccessOn: engine.guidedAccessEnabled,
                alreadySeen: OnboardingState.hasSeenGuidedAccessPrompt) else { return }
        showGuidedAccessPrompt = true
    }

    /// Re-runs the launch-time setup/recovery judgment once the Keychain can actually
    /// answer — the deferred half of the sealed-read rule (see the @State declarations).
    /// Still sealed → keep deferring; the flag stays set for the next signal.
    private func refreshPINStateIfUnresolved() {
        guard pinStateUnresolved else { return }
        let presence = KeychainService.pinPresence
        guard presence != .sealedByLock else { return }
        pinStateUnresolved = false
        recovery = KeychainService.pendingRecovery
        needsPINSetup = presence == .absent
    }

    /// Local recovery completed with either the existing PIN or a successfully written
    /// replacement after device authentication. This does not authorize cloud enrollment.
    private func finishRecovery() {
        // Finished whatever the Keychain answers next: a reinstall owes a record in the new log (item 148's 5).
        engine.noteRecoveryFinished(recovery)
        let presence = KeychainService.pinPresence
        guard presence != .sealedByLock else { pinStateUnresolved = true; return }
        recovery = KeychainService.pendingRecovery
        needsPINSetup = presence == .absent
    }
}
