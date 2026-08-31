//
//  PINViews.swift
//  Malinois
//
//  Reusable PIN pad plus the first-launch setup flow and a modal entry sheet
//  used to gate disarming and viewing the event log.
//

import SwiftUI
import Combine
import LocalAuthentication

// MARK: - PIN pad

struct PINPad: View {
    @Binding var digits: String
    let maxLength: Int
    /// When true, hide the target length (F-25): show a dot only per *typed* digit (no
    /// empty placeholders revealing the count) and submit via an explicit ✓ rather than
    /// auto-firing at a fixed length. Used for the disarm/gate pad; setup leaves it off.
    var conceal: Bool = false
    /// When true, randomize the digit positions so an observer can't read the PIN from
    /// finger positions (shoulder-surf / smudge / thermal). ✓ and ⌫ stay put — only the
    /// digits carry information, and you never want the owner hunting for backspace/submit.
    var scramble: Bool = false
    /// Called on every keypress — lets the disarm flow reset its inactivity timeout (R-09).
    var onActivity: (() -> Void)?
    var onComplete: (() -> Void)?

    private static let minLength = 4
    private static let naturalOrder = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    /// The digit layout, fixed for the life of this pad presentation. Shuffled once at
    /// construction when `scramble` is on — via `State(initialValue:)`, which SwiftUI honors
    /// only on first appearance — so there's no first-frame flash of the natural order and
    /// the layout stays stable across keystrokes (re-scrambling per keystroke would be
    /// hostile even to the owner). A fresh presentation is a fresh view identity → a fresh shuffle.
    @State private var digitOrder: [String]

    init(digits: Binding<String>, maxLength: Int, conceal: Bool = false, scramble: Bool = false,
         onActivity: (() -> Void)? = nil, onComplete: (() -> Void)? = nil) {
        self._digits = digits
        self.maxLength = maxLength
        self.conceal = conceal
        self.scramble = scramble
        self.onActivity = onActivity
        self.onComplete = onComplete
        _digitOrder = State(initialValue: scramble ? Self.naturalOrder.shuffled() : Self.naturalOrder)
    }

    private var keys: [[String]] {
        [Array(digitOrder[0...2]),
         Array(digitOrder[3...5]),
         Array(digitOrder[6...8]),
         [conceal ? "✓" : "", digitOrder[9], "⌫"]]
    }
    private var canSubmit: Bool { digits.count >= Self.minLength }

    var body: some View {
        VStack(spacing: 24) {
            // Dots — placeholders reveal the length, so when concealing show only what's
            // been typed. Reserve a little height so the pad doesn't jump as dots appear.
            HStack(spacing: 16) {
                if conceal {
                    ForEach(0..<digits.count, id: \.self) { _ in
                        Circle().fill(Color.accentColor).frame(width: 16, height: 16)
                    }
                } else {
                    ForEach(0..<maxLength, id: \.self) { i in
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.4), lineWidth: 1.5)
                            .background(Circle().fill(i < digits.count ? Color.accentColor : .clear))
                            .frame(width: 16, height: 16)
                    }
                }
            }
            .frame(height: 16)

            VStack(spacing: 12) {
                ForEach(keys, id: \.self) { row in
                    HStack(spacing: 24) {
                        ForEach(row, id: \.self) { key in
                            keyButton(key)
                        }
                    }
                }
            }
        }
        // A light tap on every keypress so the PIN can be entered without looking
        // at the (often dim) screen. Fires on append and delete.
        .sensoryFeedback(.impact(flexibility: .soft), trigger: digits)
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        if key.isEmpty {
            Color.clear.frame(width: 72, height: 72)
        } else {
            let isSubmit = key == "✓"
            Button {
                tap(key)
            } label: {
                Text(key)
                    .font(.title.weight(.regular))
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(isSubmit && !canSubmit ? Color.secondary : .primary)
            }
            .buttonStyle(.plain)
            .disabled(isSubmit && !canSubmit)
        }
    }

    private func tap(_ key: String) {
        onActivity?()
        if key == "⌫" {
            if !digits.isEmpty { digits.removeLast() }
            return
        }
        if key == "✓" {
            if canSubmit { onComplete?() }
            return
        }
        guard digits.count < maxLength else { return }
        digits.append(key)
        // Auto-submit at the fixed length only when NOT concealing (setup uses its own
        // Continue button; the concealed entry pad submits via ✓).
        if !conceal, digits.count == maxLength { onComplete?() }
    }
}

// MARK: - First-launch setup

struct PINSetupView: View {
    var onDone: () -> Void

    @State private var stage: Stage = .create
    @State private var first = ""
    @State private var confirm = ""
    @State private var error: String?

    // PINs may be 4–6 digits. The pad shows the maximum; a Continue button
    // commits whatever length (4–6) the user chose. That chosen length is then
    // stored and reused by every entry screen.
    private let maxLength = 6
    private let minLength = 4
    enum Stage { case create, confirm }

    private var current: String { stage == .create ? first : confirm }
    private var canContinue: Bool {
        stage == .create
            ? (minLength...maxLength).contains(first.count)
            : confirm.count == first.count
    }

    var body: some View {
        VStack(spacing: 28) {
            Image("MalinoisEmblem")
                .resizable()
                .scaledToFit()
                .frame(height: 92)
                .accessibilityLabel("Malinois")
            Text(stage == .create ? "Create a PIN" : "Confirm your PIN")
                .font(.title2.weight(.semibold))
            Text("4–6 digits. Required to disarm Malinois and to view captured evidence.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            PINPad(digits: stage == .create ? $first : $confirm,
                   maxLength: maxLength)

            Button(action: advance) {
                Text(stage == .create ? "Continue" : "Set PIN")
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue)
        }
        .padding()
        // Match PINEntryView's dark treatment so setup and disarm-entry look like one flow.
        // (Entry must stay black — it doubles as the disarm pad on the covert armed screen.)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onChange(of: first) { _, _ in error = nil }
        .onChange(of: confirm) { _, _ in error = nil }
    }

    private func advance() {
        switch stage {
        case .create:
            guard (minLength...maxLength).contains(first.count) else { return }
            withAnimation { stage = .confirm }
        case .confirm:
            guard first == confirm else {
                error = "PINs didn't match. Try again."
                first = ""; confirm = ""
                withAnimation { stage = .create }
                return
            }
            if KeychainService.setPIN(first) {
                onDone()
            } else {
                error = "Couldn't save PIN."
                first = ""; confirm = ""
                withAnimation { stage = .create }
            }
        }
    }
}

// MARK: - Modal entry (disarm / view log)

/// Shown when the Keychain and the local setup flag disagree. Gates the fix behind device
/// authentication so a stranger holding the unlocked device can't claim the app — either by
/// setting a new PIN over an unreadable hash, or by inheriting a container whose setup flag
/// was lost mid-write.
struct PINRecoveryView: View {
    let kind: KeychainService.RecoveryKind
    var onAuthenticated: () -> Void
    @State private var failed = false
    @State private var authUnavailable = false

    private var title: String {
        kind == .lostHash ? "PIN unavailable" : "Verify it's you"
    }
    private var explanation: String {
        switch kind {
        case .lostHash:
            return "Your Malinois PIN can't be read on this device. Authenticate with your device passcode to set a new one."
        case .lostSetupFlag:
            return "Malinois didn't finish saving its setup. Your PIN and your recorded evidence are intact — authenticate with your device passcode to restore access."
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 54))
                .foregroundStyle(.orange)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if authUnavailable {
                Text("Recovery requires a device passcode. Set one in iOS Settings → Face ID & Passcode, then tap Try Again.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Try Again", action: authenticate)
                    .buttonStyle(.borderedProminent)
            } else if failed {
                Button("Authenticate", action: authenticate)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())   // same dark treatment as setup/entry
        .environment(\.colorScheme, .dark)
        .onAppear(perform: authenticate)
    }

    private func authenticate() {
        let ctx = LAContext()
        var error: NSError?
        // Fail CLOSED when device authentication can't run (sixth review, F4): "cannot be
        // performed" must not become success on the one gate protecting PIN re-setup — on a
        // device with no passcode, anyone holding the phone could reset the PIN. The owner
        // is never trapped: setting a device passcode re-enables recovery immediately, and
        // the copy above says exactly that.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authUnavailable = true
            return
        }
        authUnavailable = false
        let reason = kind == .lostHash
            ? "Authenticate to reset your Malinois PIN"
            : "Authenticate to restore access to Malinois"
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            Task { @MainActor in
                if ok { onAuthenticated() } else { failed = true }
            }
        }
    }
}

struct PINEntryView: View {
    let title: String
    /// Whether this gate may ALSO open by biometrics (item 30, option A). Default false, so
    /// callers opt IN and every gate is PIN-only until argued otherwise: Home's read gates
    /// (log / Settings / Test Sensors) pass the owner's setting; disarm, stop-re-arming, and
    /// the change-PIN gate never do — a face must not be able to stop the watch or change
    /// the PIN that guards it. Biometrics-only policy (no device-passcode fallback door);
    /// failure or cancel simply leaves the pad standing.
    var allowBiometrics: Bool = false
    var onSuccess: () -> Void
    var onCancel: () -> Void
    var onActivity: (() -> Void)? = nil

    @EnvironmentObject private var settings: AppSettings
    @State private var digits = ""
    @State private var error = false
    @State private var shakes: CGFloat = 0   // bumped on a wrong PIN to shake the pad
    @State private var lockoutRemaining: TimeInterval = KeychainService.lockoutRemaining()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var isLocked: Bool { lockoutRemaining > 0 }

    var body: some View {
        VStack(spacing: 28) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            if isLocked {
                Text("Too many attempts. Try again in \(Int(lockoutRemaining.rounded(.up)))s")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else if error {
                Text("Incorrect PIN")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            PINPad(digits: $digits, maxLength: 6, conceal: true, scramble: settings.scramblePINPad,
                   onActivity: onActivity, onComplete: check)
                .environment(\.colorScheme, .dark)
                .disabled(isLocked)
                .opacity(isLocked ? 0.35 : 1)
                .modifier(Shake(animatableData: shakes))
            Button("Cancel", action: onCancel)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .sensoryFeedback(.error, trigger: shakes)   // buzz on a wrong PIN
        .onChange(of: digits) { _, _ in error = false }
        .onReceive(ticker) { _ in
            lockoutRemaining = KeychainService.lockoutRemaining()
        }
        .onAppear(perform: tryBiometrics)
    }

    /// Offers Face ID / Touch ID over the pad when the caller allows it and the owner opted
    /// in. Deliberately skipped during a PIN lockout (the pad is the locked thing; a face
    /// opening a locked gate would read as the lockout being decorative), and PIN counters
    /// are untouched either way — a biometric open neither spends nor resets attempts.
    private func tryBiometrics() {
        guard allowBiometrics, settings.biometricUnlock, !isLocked else { return }
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "Unlock the Malinois log and settings") { ok, _ in
            Task { @MainActor in if ok { onSuccess() } }
        }
    }

    private func check() {
        guard !isLocked else { digits = ""; return }
        // Fires when the owner submits (✓). `verify` accepts any 4–6 digit length, so the
        // pad never needs to know — or reveal — the stored length.
        if KeychainService.verify(digits) {
            // `verify` itself cleared the failure counter (the service owns BOTH halves of
            // the rate-limit contract — seventh review #1); nothing to reset here.
            onSuccess()
        } else {
            error = true
            digits = ""
            withAnimation(.linear(duration: 0.4)) { shakes += 1 }   // shake + error haptic
            // `verify` already counted this failure (F2 — the service owns rate limiting;
            // counting here too would escalate the lockout at double rate). Just read the
            // authoritative remaining time back from the Keychain (the ticker's source too)
            // so the display always reflects stored state, never a local copy that drifts.
            lockoutRemaining = KeychainService.lockoutRemaining()
        }
    }
}

/// A quick horizontal shake, driven by an incrementing `animatableData` — applied
/// to the PIN pad on an incorrect entry.
struct Shake: GeometryEffect {
    var travel: CGFloat = 9
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let dx = travel * sin(animatableData * .pi * shakesPerUnit)
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}
