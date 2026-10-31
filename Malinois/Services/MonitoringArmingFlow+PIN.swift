// Arming progression owned by MonitoringArmingFlow.
import Foundation
import AVFoundation
import LocalAuthentication

extension MonitoringArmingFlow {

    /// Pure (unit-tested; ADR 0054's decision 4): whether the ARM tap asks for the PIN first. Due with no correct entry
    /// on record (an install updating to 1.8.1 is asked once: option A), once the interval has passed since the last
    /// one, or when the stored time lies ahead of the clock (it went back: ask rather than trust). A clock moved
    /// forward only brings the ask sooner, and one moved back can only postpone it, which costs nothing: arming is the
    /// safe direction.
    nonisolated static func armPINCheckDue(lastEntry: Date?, now: Date, interval: TimeInterval = armPINCheckInterval) -> Bool {
        guard let lastEntry else { return true }
        return lastEntry > now || now.timeIntervalSince(lastEntry) >= interval
    }

    /// What Home's ARM tap leads to (item 162's G1).
    enum ArmTapOutcome: Equatable {
        /// The PIN check is due: Home opens the arm gate's pad, and nothing starts until a correct PIN.
        case askForPIN
        /// The arming has begun (`armAfterPINCheck`).
        case arming
    }

    /// Home's ARM tap (ADR 0054): the PIN first when the check is due, and otherwise the arming at once, as after a
    /// correct PIN at the arm gate. Decided here rather than in HomeView, so its tests drive it (item 162's G1).
    @discardableResult
    func armTapped() -> ArmTapOutcome {
        guard !armPINCheckIsDue else { return .askForPIN }
        armAfterPINCheck()
        return .arming
    }

    /// The ARM tap's work once the PIN check, when it was due, has passed: the camera question on the first tap that
    /// needs the camera (item 69, ADR 0011), then the arming screen (`beginArming`). Asked while still on Home, so
    /// never under Guided Access, where iOS records a blocked question as a refusal; a refusal still arms, with the
    /// existing "Camera access is denied" notice. Vision needs the camera as much as capture does.
    func armAfterPINCheck() {
        let lifetime = retainHostForFiniteWork()
        Task {
            defer { lifetime.keepAlive() }
            refreshGuidedAccess()
            if CameraController.cameraPromptIsDue(cameraNeeded: settings.isEnabled(.camera) || settings.isEnabled(.vision),
                                                  undetermined: camera.videoPermission == .notDetermined,
                                                  guidedAccessOn: guidedAccessEnabled) {
                _ = await camera.requestVideoAccess()
            }
            beginArming()
        }
    }

    /// Reads again whether this iPhone has no device passcode, for the arming screen's line: when the screen appears,
    /// and when the app is back on it (from Settings, where the owner may just have set one).
    func refreshDevicePasscode() {
        guard let host else { return }
        host.armingSetDevicePasscodeMissing(host.armingDevicePasscodeMissingNow)
    }

    /// Pure (unit-tested): whether iOS's answer says no device passcode is set. Only that answer counts: a check that
    /// cannot run for another reason (the biometrics locked out, no screen to show it on) says nothing about it.
    nonisolated static func passcodeMissing(canEvaluate: Bool, error: NSError?) -> Bool {
        !canEvaluate && error?.domain == LAErrorDomain && error?.code == LAError.Code.passcodeNotSet.rawValue
    }
}
