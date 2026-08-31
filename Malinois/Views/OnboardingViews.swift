//
//  OnboardingViews.swift
//  Malinois
//
//  Two one-time screens that fire at the moments the owner is actually receptive:
//
//  1. `TrialWelcomeView` — right after PIN setup. States plainly that the 30-day Pro trial has
//     already started and that some of what they're about to use will switch off when it ends.
//     The trial begins at first launch (see `ProEntitlements`), so without this the first
//     experience silently *is* Pro and the eventual downgrade reads as features being taken away.
//  2. `GuidedAccessPromptView` — after the first completed armed session. Guided Access is the
//     difference between "logs a tamper" and "can't be stopped", and the arming screen's
//     coaching is easy to skim past while impatient to arm. After a real session the owner has
//     context for why it matters.
//
//  Both are shown once and never again; the flags live in `OnboardingState`.
//

import SwiftUI

/// One-time onboarding flags. Kept together so the "seen" keys can't drift apart from the
/// screens that consume them, and so tests/reset paths have a single place to look.
enum OnboardingState {
    private static let welcomeKey = "com.malinois.onboarding.seenTrialWelcome"
    private static let guidedAccessKey = "com.malinois.onboarding.seenGuidedAccessPrompt"

    static var hasSeenTrialWelcome: Bool {
        get { UserDefaults.standard.bool(forKey: welcomeKey) }
        set { UserDefaults.standard.set(newValue, forKey: welcomeKey) }
    }

    static var hasSeenGuidedAccessPrompt: Bool {
        get { UserDefaults.standard.bool(forKey: guidedAccessKey) }
        set { UserDefaults.standard.set(newValue, forKey: guidedAccessKey) }
    }

    /// Whether the post-session Guided Access nudge is due. Pure (unit-tested).
    ///
    /// Deliberately narrow. It fires only after a session that actually *ran* (so cancelling the
    /// arming flow doesn't count), and never when Guided Access is already on — an owner who has
    /// set it up doesn't need to be told it matters, and nagging them is how a security prompt
    /// gets trained into reflexive dismissal.
    static func shouldPromptForGuidedAccess(completedASession: Bool,
                                            guidedAccessOn: Bool,
                                            alreadySeen: Bool) -> Bool {
        completedASession && !guidedAccessOn && !alreadySeen
    }
}

// MARK: - Trial welcome

/// Shown once, immediately after PIN setup.
struct TrialWelcomeView: View {
    @EnvironmentObject private var entitlements: ProEntitlements
    var onDismiss: () -> Void

    private var daysLeft: Int { entitlements.trialDaysRemaining ?? ProEntitlements.trialDays }

    // This screen fires on first *setup*, which is not the same as a first-ever install: the
    // trial start and a purchase both survive app deletion (Keychain / the App Store account).
    // So a reinstall can arrive here already owning Pro, or with the trial long lapsed —
    // announcing "your trial has started" in either case would simply be false.
    private var headline: String {
        switch entitlements.status {
        case .pro:   "Malinois Pro is active"
        case .trial: "Your \(ProEntitlements.trialDays)-day Pro trial has started"
        case .free:  "Welcome to Malinois"
        }
    }
    private var subhead: String {
        switch entitlements.status {
        case .pro:   "You own Pro — everything below is unlocked, permanently."
        case .trial: "\(daysLeft) days left · no card, nothing to cancel"
        case .free:  "This device has already used its Pro trial."
        }
    }
    private var includedTitle: String {
        entitlements.status == .trial ? "Included during the trial" : "Included with Pro"
    }
    private var closingNote: String {
        switch entitlements.status {
        case .pro:
            "Nothing expires and there's nothing to renew. Your evidence stays on this device and in your own private iCloud — nobody else can read it, including me."
        case .trial:
            "When the trial ends, your device stays protected — only the iCloud backup, the cross-device alerts and the richer capture options switch off. Nothing you've recorded is lost, and your settings are kept."
        case .free:
            "Your device is still fully protected: detection, capture, the local log and the alarm all keep working. Pro restores the iCloud backup, the cross-device alerts and the richer capture options whenever you want it."
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("MalinoisEmblem")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 84)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(headline)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(subhead)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // The honest framing: say what STOPS, not just what's included. The trial starts
                // at first launch, so everything below is already on — and a user who never
                // learns that reads the lapse as features being removed.
                section(title: includedTitle,
                        tint: Brand.blue,
                        icon: "sparkles",
                        rows: [
                            ("icloud.and.arrow.up", "Evidence backed up to your private iCloud", "Survives the phone being switched off or taken."),
                            ("iphone.radiowaves.left.and.right", "Alerts on your other Apple devices", "Know the moment it's touched, wherever you are."),
                            ("camera.on.rectangle", "Both cameras at once, longer clips", "More frames, and the face plus the room together."),
                            ("waveform", "The Sound tripwire", "Detects handling noise nearby."),
                            ("eye", "The Vision tripwire", "While charging, the camera watches its view for movement.")
                        ])

                section(title: "Free forever, trial or not",
                        tint: .green,
                        icon: "checkmark.shield",
                        rows: [
                            ("sensor.tag.radiowaves.forward", "Detection and capture", "Motion, touch, power and proximity tripwires, with photo and video evidence."),
                            ("list.bullet.rectangle", "Your PIN-locked event log", "On this device, with export."),
                            ("bell", "The alarm and every hardening feature", "Siren, brute-force lockout, Guided Access support, anti-flooding.")
                        ])

                Text(closingNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                Button(action: onDismiss) {
                    Text("Start using Malinois").frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .padding(24)
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled()
    }

    private func section(title: String, tint: Color, icon: String,
                         rows: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
            ForEach(rows, id: \.1) { row in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: row.0)
                        .font(.body)
                        .foregroundStyle(tint)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.1).font(.subheadline.weight(.semibold))
                        Text(row.2).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(tint.opacity(0.10)))
    }
}

// MARK: - Guided Access prompt

/// Shown once, after the first armed session that ran without Guided Access.
struct GuidedAccessPromptView: View {
    var onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "lock.open.trianglebadge.exclamationmark")
                    .font(.system(size: 54))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                Text("Malinois isn't fully protected yet")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                // The specific failure, not a vague exhortation. Someone who just watched the app
                // work needs to know what it still can't stop.
                Text("That session ran **without Guided Access**. Malinois caught what happened — but anyone holding your phone could have swiped the app away or powered it off before the evidence uploaded, and nothing would have reached your iCloud.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 12) {
                    Label("Guided Access locks the phone to Malinois", systemImage: "lock.shield")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.blue)
                    bullet("It can't be swiped away or app-switched")
                    bullet("The power-off slider is blocked")
                    bullet("Incoming calls go to voicemail and Siri is disabled, so neither can interrupt monitoring")
                    bullet("With Volume Buttons turned off in its Options, the siren can't be turned down")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Brand.blue.opacity(0.10)))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Set it up once — about a minute")
                        .font(.subheadline.weight(.bold))
                    step(1, "Settings → Accessibility → Guided Access → turn it on.")
                    step(2, "Guided Access → Passcode Settings → set a passcode. Make it **different** from your device passcode, so someone who knows your unlock code still can't exit.")
                    step(3, "Then whenever you arm Malinois, triple-click the side button and tap Start.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))

                Text("Malinois will keep working without it, and the arming screen shows these steps every time. You can also make Guided Access mandatory in Settings → Require Guided Access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: onDismiss) {
                    Text("Got it").frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .padding(24)
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Brand.blue)
                .frame(width: 16)
            Text(.init(text)).font(.caption)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Brand.blue.opacity(0.25)))
            Text(.init(text)).font(.caption)
        }
    }
}
