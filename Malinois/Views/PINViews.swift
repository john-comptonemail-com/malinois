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
import UIKit

// MARK: - PIN pad

struct PINPad: View {
    @Binding var digits: String
    let maxLength: Int
    /// When true, show a dot only per *typed* digit (no empty placeholders revealing the
    /// count) and, without `autoSubmitLength`, submit via an explicit ✓ (F-25's length
    /// concealment, relaxed by item 106). Used for the disarm/gate pad; setup leaves it off.
    var conceal: Bool = false
    /// When true, randomize the digit positions so an observer can't read the PIN from
    /// finger positions (shoulder-surf / smudge / thermal). ✓ and ⌫ stay put — only the
    /// digits carry information, and you never want the owner hunting for backspace/submit.
    var scramble: Bool = false
    /// Called on every keypress — lets the disarm flow reset its inactivity timeout (R-09).
    var onActivity: (() -> Void)?
    var onComplete: (() -> Void)?
    /// Item 106: the PIN's confirmed length. When set, the pad submits itself once that many
    /// digits are typed, like the iPhone's passcode, and shows no ✓; the entry is checked exactly
    /// as an explicit submit is, so a wrong one counts toward the lockout. Nil keeps the ✓.
    var autoSubmitLength: Int?

    /// Pure (unit-tested; item 106): whether the entry submits itself after this keypress.
    nonisolated static func submitsAutomatically(count: Int, maxLength: Int, conceal: Bool,
                                                 autoSubmitLength: Int?) -> Bool {
        if let autoSubmitLength { return count == autoSubmitLength }
        return !conceal && count == maxLength
    }

    /// Pure (unit-tested; item 106): whether the pad shows the explicit submit key.
    nonisolated static func showsSubmitKey(conceal: Bool, autoSubmitLength: Int?) -> Bool {
        conceal && autoSubmitLength == nil
    }

    private static let minLength = 4
    private static let naturalOrder = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    /// The digit layout, fixed for the life of this pad presentation. Shuffled once at
    /// construction when `scramble` is on — via `State(initialValue:)`, which SwiftUI honors
    /// only on first appearance — so there's no first-frame flash of the natural order and
    /// the layout stays stable across keystrokes (re-scrambling per keystroke would be
    /// hostile even to the owner). A fresh presentation is a fresh view identity → a fresh shuffle.
    @State private var digitOrder: [String]

    init(digits: Binding<String>, maxLength: Int, conceal: Bool = false, scramble: Bool = false,
         autoSubmitLength: Int? = nil,
         onActivity: (() -> Void)? = nil, onComplete: (() -> Void)? = nil) {
        self.autoSubmitLength = autoSubmitLength
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
         [Self.showsSubmitKey(conceal: conceal, autoSubmitLength: autoSubmitLength) ? "✓" : "",
          digitOrder[9], "⌫"]]
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
        // Setup advances at its fixed length; the entry pad at the confirmed length, or via ✓
        // without one (item 106).
        if Self.submitsAutomatically(count: digits.count, maxLength: maxLength, conceal: conceal,
                                     autoSubmitLength: autoSubmitLength) { onComplete?() }
    }
}

// MARK: - First-launch setup

struct PINSetupView: View {
    /// Recovery supplies a guarded save; ordinary first setup and PIN-authorized changes
    /// retain the existing service path. A failed write never completes the view. Main-actor typed,
    /// as `setPIN` is since item 144 (a): a save runs where the lockout's state lives.
    var savePIN: @MainActor (String) -> Bool = KeychainService.setPIN
    var onDone: () -> Void

    @State private var stage: Stage = .create
    @State private var first = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var length = PINSetupView.defaultLength
    @State private var easyToGuess = false

    /// Item 106 (owner, 2026-10-12): new PINs are 4 digits by default, with 6 available; the pad
    /// advances by itself at the chosen length. An existing 5-digit PIN keeps working until changed.
    nonisolated static let defaultLength = 4
    nonisolated static let allowedLengths = [4, 6]
    enum Stage { case create, confirm }

    /// What the PIN is for, and a code to avoid sharing.
    private var advice: String {
        "\(length) digits. Required to disarm Malinois and to view captured evidence. Use a code different from your iPhone passcode and your Guided Access passcode."
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
            // Item 106: 4 digits by default with 6 one tap away; the easy-to-guess warning below
            // replaced R1-L1 and R2's "6 recommended" nudge, since people's 6-digit choices are
            // barely harder to guess; the lockout remains the real defense (SECURITY.md).
            // Item 108 (the owner's decision 3, 2026-10-13): a code shared with the iPhone or Guided
            // Access falls with it, to one glance over the owner's shoulder.
            Text(advice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .reportedOnScreen(advice)

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            PINPad(digits: stage == .create ? $first : $confirm,
                   maxLength: length, onComplete: advance)

            if stage == .create {
                Button(length == 4 ? "Use 6 digits" : "Use 4 digits") {
                    length = length == 4 ? 6 : 4
                    first = ""
                }
                .font(.footnote)
            }
        }
        .padding()
        // Item 82: scrolls when taller than the screen (the iPhone Duo's outer display, an iPhone SE,
        // large text) instead of cutting the explanation short; laid out as before where it fits.
        .scrollingIfNeeded()
        // Match PINEntryView's dark treatment so setup and disarm-entry look like one flow.
        // (Entry must stay black — it doubles as the disarm pad on the covert armed screen.)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onChange(of: first) { _, _ in error = nil }
        .onChange(of: confirm) { _, _ in error = nil }
        .alert("This PIN is easy to guess", isPresented: $easyToGuess) {
            Button("Use Anyway") { withAnimation { stage = .confirm } }
            Button("Choose Another", role: .cancel) { first = "" }
        } message: {
            Text("PINs like 1234, repeated digits and years are among the first an intruder tries.")
        }
    }

    private func advance() {
        switch stage {
        case .create:
            guard first.count == length else { return }
            if PINStrength.isEasilyGuessed(first) { easyToGuess = true; return }   // item 106
            withAnimation { stage = .confirm }
        case .confirm:
            guard confirm.count == first.count else { return }
            guard first == confirm else {
                error = "PINs didn't match. Try again."
                first = ""; confirm = ""
                withAnimation { stage = .create }
                return
            }
            if savePIN(first) {
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

/// Ephemeral permission granted only by the device-owner authentication callback. The
/// view revokes it on background/dismissal. Credentials remain intact until a successful
/// replacement write; unreadable Keychain state never authorizes replacement. Main-actor isolated, which
/// its guarded save needs since item 144 (a): `KeychainService.setPIN` lives with the lockout's state there.
@MainActor
final class PINResetPermission: ObservableObject {
    @Published private(set) var authorized = false

    @discardableResult
    func authenticationFinished(success: Bool) -> Bool {
        authorized = success && KeychainService.pinPresence != .sealedByLock
        return authorized
    }

    func revoke() { authorized = false }

    func savePIN(_ pin: String) -> Bool {
        guard authorized else { return false }
        guard KeychainService.pinPresence != .sealedByLock else { revoke(); return false }
        guard KeychainService.setPIN(pin) else { return false }
        revoke()
        return true
    }
}

/// Local recovery for a missing setup marker or damaged credential. A surviving PIN
/// resumes access without a new device-auth policy for ordinary disarm. The explicit
/// forgotten-PIN route instead requests device-owner authentication before replacement.
struct PINContinuityView: View {
    private static let keptExplanation = "Enter your existing PIN to resume. If you forgot it, verify with Face ID, Touch ID, or your device passcode to choose a new one."
    let kind: KeychainService.RecoveryKind
    var onDone: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var permission = PINResetPermission()
    @State private var showPIN = false
    @State private var requestedReset = false
    @State private var error: String?

    var body: some View {
        Group {
            if permission.authorized {
                VStack {
                    PINSetupView(savePIN: permission.savePIN, onDone: onDone)
                    Button("Cancel reset") { permission.revoke(); requestedReset = false }
                        .padding(.bottom)
                }
            } else if kind == .lostHash || requestedReset {
                PINRecoveryView(kind: .lostHash, replacingExistingPIN: kind == .lostSetupFlag, onAuthenticated: {
                    if !permission.authenticationFinished(success: true) {
                        error = "PIN storage is unavailable. Unlock this device and try again."
                    }
                }, onCancel: kind == .lostSetupFlag ? { requestedReset = false } : nil)
            } else {
                VStack(spacing: 24) {
                    Image(systemName: "lock.shield").font(.system(size: 54))
                    Text("Your Malinois PIN was kept").font(.title2.weight(.semibold))
                        .reportedOnScreen("Your Malinois PIN was kept")
                    Text(Self.keptExplanation)
                        .multilineTextAlignment(.center)
                        .reportedOnScreen(Self.keptExplanation)
                    if let error { Text(error).foregroundStyle(.orange) }
                    Button { showPIN = true } label: { Text("Use existing PIN").reportedOnScreen("Use existing PIN") }
                        .buttonStyle(.borderedProminent)
                    Button("Forgot PIN?") { requestedReset = true }
                }
                .padding(32)
                .scrollingIfNeeded()   // its text was cut off at the largest text sizes (BACKLOG 128)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showPIN) {
            PINEntryView(title: "Enter your existing Malinois PIN", onSuccess: {
                showPIN = false
                if KeychainService.markSetupCompleted() { onDone() }
                else { error = "PIN storage is unavailable. Unlock this device and try again." }
            }, onCancel: { showPIN = false })
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { permission.revoke(); requestedReset = false }
        }
        .onDisappear { permission.revoke() }
    }
}

/// Requests the existing device-owner policy, never changing credentials itself. A
/// dismissed/backgrounded prompt cannot deliver a late authorization to a replacement view.
struct PINRecoveryView: View {
    let kind: KeychainService.RecoveryKind
    var replacingExistingPIN = false
    var onAuthenticated: () -> Void
    var onCancel: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var context: LAContext?
    @State private var requestID: UUID?
    @State private var failed = false
    @State private var authUnavailable = false
    @State private var guidedAccessBlocked = false

    private var title: String {
        replacingExistingPIN ? "Reset Malinois PIN" : (kind == .lostHash ? "PIN unavailable" : "Verify it's you")
    }
    private var explanation: String {
        if replacingExistingPIN {
            return "Verify with Face ID, Touch ID, or your device passcode to choose a new Malinois PIN. Your existing PIN stays in place until the new one is saved."
        }
        switch kind {
        case .lostHash:
            return "Your Malinois PIN can't be read on this device. Authenticate with Face ID, Touch ID, or your device passcode to set a new one."
        case .lostSetupFlag:
            return "Your Malinois PIN was kept. Authenticate with Face ID, Touch ID, or your device passcode to continue."
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
            if guidedAccessBlocked {
                Text("End Guided Access first (triple-click the side button) - iOS won't show the verification screen while it's on. Then tap Try Again.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Try Again", action: authenticate)
                    .buttonStyle(.borderedProminent)
            } else if authUnavailable {
                Text(BiometricKind.current.recoveryNeedsPasscode)
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
            if let onCancel { Button("Cancel") { cancelAuthentication(); onCancel() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())   // same dark treatment as setup/entry
        .environment(\.colorScheme, .dark)
        .onAppear(perform: authenticate)
        .onDisappear(perform: cancelAuthentication)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { cancelAuthentication(); failed = true }
        }
    }

    private func cancelAuthentication() {
        requestID = nil
        context?.invalidate()
        context = nil
    }

    private func authenticate() {
        cancelAuthentication()
        guard UIApplication.shared.applicationState == .active else { failed = true; return }
        // Same OS behavior as the gate's Face ID offer (BACKLOG 44): under Guided Access
        // the system auth sheet is DEFERRED, not refused — canEvaluatePolicy still says
        // yes, and the request queues silently until GA ends. Recovery is fail-closed
        // (sixth review F4), so without this branch that hang reads as a dead-end. The
        // owner ends GA (it is their session) and taps Try Again.
        guard !UIAccessibility.isGuidedAccessEnabled else {
            guidedAccessBlocked = true
            return
        }
        guidedAccessBlocked = false
        let ctx = LAContext()
        context = ctx
        let id = UUID()
        requestID = id
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
                guard requestID == id else { return }
                requestID = nil
                context = nil
                if ok { onAuthenticated() }
                failed = true // If storage refused recovery, the still-visible view offers retry.
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
    /// A wrong guess, after `KeychainService.verifyEntry` has counted it; never a refusal that compared no PIN
    /// (item 153's MAL-14 (a)). The armed screen's pad hands it to the engine, which records the attempt (item 49);
    /// every other pad leaves it nil and stays lockout-only.
    var onFailure: (() -> Void)? = nil

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var digits = ""
    @State private var error = false
    @State private var shakes: CGFloat = 0   // bumped on a wrong PIN to shake the pad
    /// The Face ID or Touch ID request this pad made, if one is out (item 153's MAL-12).
    @State private var biometricRequest = BiometricRequest()
    @State private var lockoutRemaining: TimeInterval = KeychainService.lockoutRemaining()
    /// Item 106: read once per presentation; nil keeps the explicit submit.
    @State private var autoSubmitLength = KeychainService.confirmedPINLength
    @State private var gaActive = UIAccessibility.isGuidedAccessEnabled
    /// Why the biometric was not offered although the owner had turned it on (ADR 0056): the unlock is no longer bound
    /// to the enrolled faces or fingers, or never was. The pad says so; the unlock is off until Settings turns it on.
    @State private var bindingLapse: BiometricBinding.Verdict?

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var isLocked: Bool { lockoutRemaining > 0 }
    private var lockoutMessage: String { "Too many attempts. Try again in \(Int(lockoutRemaining.rounded(.up)))s" }
    /// The offer was wanted in every respect except an active Guided Access session —
    /// the one case worth a caption, so the missing Face ID prompt reads as iOS policy,
    /// not a breakage (BACKLOG 44).
    private var biometricsVetoedByGuidedAccess: Bool {
        allowBiometrics && settings.biometricUnlock && !isLocked && gaActive
    }

    var body: some View {
        // Item 126: the pad scrolls when it is taller than the room, as at the largest text sizes on a
        // short screen, instead of squeezing its title and lockout message to a line or two. Laid out
        // at least as tall as the room, it sits centred as before wherever it fits, and does not move
        // under a finger then. One pad throughout (the recovery PIN's fix from 1.7, W1, now every PIN
        // screen's), so the digits typed and the lockout survive a change of size.
        GeometryReader { room in
            ScrollView {
                VStack(spacing: 28) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .reportedOnScreen(title)
                    if isLocked {
                        Text(lockoutMessage)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .reportedOnScreen(lockoutMessage)
                    } else if error {
                        Text("Incorrect PIN")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if let lapse = bindingLapse {
                        Text(BiometricKind.current.bindingCaption(for: lapse))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .reportedOnScreen(BiometricKind.current.bindingCaption(for: lapse))
                    } else if biometricsVetoedByGuidedAccess {
                        Text(BiometricKind.current.guidedAccessCaption)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    PINPad(digits: $digits, maxLength: 6, conceal: true, scramble: settings.scramblePINPad,
                           autoSubmitLength: autoSubmitLength, onActivity: onActivity, onComplete: check)
                        .environment(\.colorScheme, .dark)
                        .disabled(isLocked)
                        .opacity(isLocked ? 0.35 : 1)
                        .modifier(Shake(animatableData: shakes))
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(40)
                .frame(maxWidth: .infinity, minHeight: room.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.black.ignoresSafeArea())
        .sensoryFeedback(.error, trigger: shakes)   // buzz on a wrong PIN
        .onChange(of: digits) { _, _ in error = false }
        .onReceive(ticker) { _ in
            lockoutRemaining = KeychainService.lockoutRemaining()
        }
        // Ending Guided Access mid-gate lifts the caption AND makes the offer the owner
        // originally wanted — the clean version of what iOS did by itself pre-fix (the
        // deferred sheet popping the moment GA ended, from behind the privacy cover).
        .onReceive(NotificationCenter.default.publisher(
            for: UIAccessibility.guidedAccessStatusDidChangeNotification)) { _ in
            gaActive = UIAccessibility.isGuidedAccessEnabled
            tryBiometrics()
        }
        .onAppear(perform: tryBiometrics)
        .onDisappear { biometricRequest.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { biometricRequest.cancel() }
        }
    }

    /// Pure (unit-tested): whether the pad may offer Face ID / Touch ID. All four gates
    /// must agree — the caller allows it (write surfaces never do), the owner opted in,
    /// no lockout stands (the pad is the locked thing; a face opening a locked gate would
    /// read as the lockout being decorative), and NO Guided Access session is active:
    /// iOS defers the biometric sheet under GA without erroring (BACKLOG 44), which left
    /// the request queued behind the privacy cover — a dead-end covering the very pad
    /// that could have answered. Under GA the pad simply stands.
    nonisolated static func shouldOfferBiometrics(allow: Bool, optedIn: Bool,
                                                  locked: Bool, guidedAccess: Bool) -> Bool {
        allow && optedIn && !locked && !guidedAccess
    }

    /// Offers Face ID / Touch ID over the pad per `shouldOfferBiometrics`, and only while the unlock is still bound to
    /// the faces or fingers enrolled when the owner turned it on (ADR 0056): a changed set, or none on record, turns
    /// the unlock off until Settings turns it on again, and the pad says why. PIN counters are untouched either way —
    /// a biometric open neither spends nor resets attempts.
    private func tryBiometrics() {
        biometricRequest.cancel()   // a new offer ends any earlier request (item 153's MAL-12)
        guard Self.shouldOfferBiometrics(allow: allowBiometrics,
                                         optedIn: settings.biometricUnlock,
                                         locked: isLocked,
                                         guidedAccess: UIAccessibility.isGuidedAccessEnabled)
        else { return }
        let ctx = LAContext()
        guard BiometricBinding.canEvaluateBiometrics(ctx) else { return }
        let verdict = BiometricBinding.checkBeforeOffer(context: ctx, settings: settings)
        guard verdict == .bound else { bindingLapse = verdict; return }
        let request = biometricRequest.begin(ctx)
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: BiometricKind.unlockPromptReason) { ok, _ in
            // Only the request still out opens the screen: a late answer to an earlier one, or one that came after
            // the pad went away or the app went to the background, opens nothing (item 153's MAL-12).
            Task { @MainActor in if biometricRequest.finish(request), ok { onSuccess() } }
        }
    }

    /// Pure (unit-tested): whether a refused entry goes on the armed pad's record (item 153's MAL-14 (a)): a real wrong
    /// guess only. A refusal that compared no PIN (a lockout the ticker had not shown yet, a sealed Keychain) is no
    /// attempt, and recording one put a false "Wrong PIN entered" in the log.
    nonisolated static func recordsAttempt(_ result: KeychainService.PINEntryResult) -> Bool {
        result == .wrong
    }

    private func check() {
        guard !isLocked else { digits = ""; return }
        // Fires on the explicit ✓ or, with a confirmed length, once that many digits are typed
        // (item 106). Either way `verifyEntry` counts a wrong guess, and the armed pad's `onFailure`
        // records it: auto-submit gives no free guesses.
        let result = KeychainService.verifyEntry(digits)
        if result == .correct {
            // `verifyEntry` itself cleared the failure counter (the service owns BOTH halves of
            // the rate-limit contract — seventh review #1); nothing to reset here.
            onSuccess()
        } else {
            error = true
            digits = ""
            // The rest of this entry submits with ✓ (item 108, F10): were the confirmed length
            // ever wrong, auto-submit would fire at it on every try and the owner could never
            // enter the real PIN. The next presentation reads the length again.
            autoSubmitLength = nil
            withAnimation(.linear(duration: 0.4)) { shakes += 1 }   // shake + error haptic
            // `verifyEntry` already counted a wrong guess (F2 — the service owns rate limiting;
            // counting here too would escalate the lockout at double rate). Just read the
            // authoritative remaining time back from the Keychain (the ticker's source too)
            // so the display always reflects stored state, never a local copy that drifts.
            lockoutRemaining = KeychainService.lockoutRemaining()
            if Self.recordsAttempt(result) { onFailure?() }   // the armed pad's attempt goes on the record (item 49)
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

/// The biometric this iPhone has, for the words on screen (item 82, fix 3). The biometric unlock
/// accepts whichever the phone has (`.deviceOwnerAuthenticationWithBiometrics`), but four texts
/// named Face ID on every iPhone, wrong on the Touch ID iPhones the app supports (iPhone SE, 2nd
/// and 3rd generation). Pure apart from `current`, and unit-tested.
enum BiometricKind: Equatable, CaseIterable {
    case faceID, touchID, opticID, none

    init(_ type: LABiometryType) {
        switch type {
        case .faceID:  self = .faceID
        case .touchID: self = .touchID
        case .opticID: self = .opticID
        default:       self = .none   // no biometric, or one a later iOS adds
        }
    }

    /// This iPhone's, read once per launch. `biometryType` is set by `canEvaluatePolicy`
    /// whatever it returns, so a phone with nothing enrolled, or no passcode, still names its
    /// hardware.
    static let current: BiometricKind = {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return BiometricKind(context.biometryType)
    }()

    /// As iOS names it.
    var name: String {
        switch self {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none:    return "Face ID or Touch ID"
        }
    }

    /// The arming screen's line on an iPhone without a device passcode (1.8.2's step 34, item 155's F3): the owner's
    /// wording (2026-10-23), naming this phone's Settings screen.
    var noPasscodeWarning: String {
        "This iPhone has no passcode, so a forced restart opens it and ends Guided Access. Set one in Settings → \(settingsScreen)."
    }

    /// The iOS Settings screen that holds the device passcode.
    var settingsScreen: String {
        // With no biometry reported (a phone without a passcode can read that way), name both
        // real screens: every supported iPhone has one or the other, and none has a plain
        // "Passcode" screen (item 89, C2).
        self == .none ? "Face ID & Passcode (or Touch ID & Passcode)" : "\(name) & Passcode"
    }

    /// What can be held up to it: why a biometric never opens a write surface.
    private var presentable: String {
        switch self {
        case .faceID:  return "a face"
        case .touchID: return "a finger"
        case .opticID: return "an eye"
        case .none:    return "a face or a finger"
        }
    }

    /// Settings: the opt-in toggle and its caption.
    var unlockToggleTitle: String { "\(name) unlock" }
    var unlockToggleCaption: String {
        "Open the Event Log and Test Sensors with \(name) instead of the PIN. Settings, disarming, and changing "
            + "the PIN always require the PIN: \(presentable) can be presented; a PIN has to be given. Tied to "
            + "\(enrolledPlural) now: if one is added or removed, this turns off until you turn it on again."
    }
    /// PIN recovery on a phone without a device passcode.
    var recoveryNeedsPasscode: String {
        "Recovery requires a device passcode. Set one in iOS Settings → \(settingsScreen), then tap Try Again."
    }
    /// The PIN pad's caption when Guided Access keeps the biometric from being offered.
    var guidedAccessCaption: String { "\(name) is unavailable during Guided Access - enter your PIN." }

    /// The enrolled set, plural: what the unlock is tied to (ADR 0056).
    private var enrolledPlural: String {
        switch self {
        case .faceID:  return "the faces enrolled"
        case .touchID: return "the fingers enrolled"
        case .opticID: return "the eyes enrolled"
        case .none:    return "the faces or fingers enrolled"
        }
    }

    /// The PIN pad's caption when the unlock is no longer bound to the enrolled biometrics, or never was (ADR 0056):
    /// what happened, and that Settings (behind the PIN) turns it on again. Nothing while bound.
    func bindingCaption(for verdict: BiometricBinding.Verdict) -> String {
        switch verdict {
        case .bound:
            return ""
        case .changed:
            return "\(name) unlock turned off: a face or finger was added or removed on this iPhone since you turned it "
                + "on. Enter your PIN; to use \(name) again, turn it on in Settings."
        case .unbound:
            return "\(name) unlock is off until you turn it on again in Settings, which now ties it to \(enrolledPlural) "
                + "on this iPhone. Enter your PIN."
        }
    }

    /// The reason line under a Touch ID prompt (Face ID shows none): only what a biometric can
    /// open. Settings, disarming and changing the PIN never accept one.
    static let unlockPromptReason = "Open the Event Log or Test Sensors"
}
