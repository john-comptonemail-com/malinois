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
    @Environment(\.scenePhase) private var scenePhase
    @State private var needsPINSetup = KeychainService.pinPresence == .absent
    // The Keychain and the local setup flag disagree. Either direction must go behind device
    // authentication rather than an open setup flow, or a stranger holding the unlocked device
    // could claim the app and gate the surviving event log behind a PIN of their choosing.
    @State private var recovery: KeychainService.RecoveryKind? = KeychainService.pendingRecovery
    // A CloudKit push can construct this view on a LOCKED device (background launch, or the
    // unlock-transition instant of a lock-screen notification tap), where the PIN hash reads
    // as SEALED — unreadable, not absent (found live 2026-08-30). Neither setup nor recovery
    // may be judged from a blind read: both @States above defer to the normal flow in that
    // state (Home is safe unauthenticated; every PIN gate still gates), and this flag makes
    // the judgment re-run once the Keychain can actually answer.
    @State private var pinStateUnresolved = KeychainService.pinPresence == .sealedByLock

    /// One-time trial explainer, shown between setup and Home. The trial starts at first launch,
    /// so without this the first experience silently *is* Pro and the eventual lapse reads as
    /// features being taken away. Only for genuine first-time setup — a returning owner coming
    /// through PIN recovery has seen it, and the flag survives in UserDefaults.
    @State private var showTrialWelcome = false

    /// One-time Guided Access nudge, evaluated when a session ends (see `maybePromptGuidedAccess`).
    @State private var showGuidedAccessPrompt = false

    var body: some View {
        Group {
            if let recovery {
                PINRecoveryView(kind: recovery) { resolveRecovery(recovery) }
            } else if needsPINSetup {
                PINSetupView {
                    needsPINSetup = false
                    showTrialWelcome = !OnboardingState.hasSeenTrialWelcome
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

    /// Device authentication succeeded. What that entitles depends on which way the state
    /// disagreed: a lost *hash* can only be re-set up (there's nothing left to keep), while a
    /// lost *flag* sits on an intact PIN and a surviving log — so repair the flag and destroy
    /// nothing. Re-reading `hasPIN` afterwards routes each case to the right screen.
    private func resolveRecovery(_ kind: KeychainService.RecoveryKind) {
        if kind == .lostSetupFlag { KeychainService.markSetupCompleted() }
        recovery = nil
        needsPINSetup = !KeychainService.hasPIN
    }
}
