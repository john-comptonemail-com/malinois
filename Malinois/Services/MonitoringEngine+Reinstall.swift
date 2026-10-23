//
//  MonitoringEngine+Reinstall.swift
//  Malinois
//
//  The reinstall record (BACKLOG 148's 5, item 145 step 9): a launch that recognises a reinstall (a PIN survived in the
//  Keychain while the setup flag and the log did not) owes one status entry in the new log, written at the first
//  successful Verify iCloud access or the first watch, whichever comes first. Kept apart from MonitoringEngine.swift,
//  which sits at the lint size limit.
//

import Foundation
import UIKit

extension MonitoringEngine {
    /// Set while this install owes its reinstall record. In UserDefaults, which a reinstall empties, so an install owes
    /// at most one.
    nonisolated static let reinstallRecordOwedKey = "com.malinois.recovery.reinstallRecordOwed"

    /// Pure (unit-tested): whether a finished launch recovery owes the record. Only a recognised reinstall: a PIN
    /// survived in the Keychain while the setup flag did not (`.lostSetupFlag`), and no earlier log survived either,
    /// or the record's words would be false. A damaged credential (`.lostHash`) is not a reinstall, and a fresh install
    /// has no recovery.
    nonisolated static func reinstallRecordOwed(recovery: KeychainService.RecoveryKind?, priorLocalEvidence: Bool) -> Bool {
        recovery == .lostSetupFlag && !priorLocalEvidence
    }

    /// Whether a PIN recovery is pending (item 152's lead 18), or might be: the Keychain's answer, unless a test injects
    /// one, and a sealed Keychain counts as pending (item 155's A5: nothing is known about the PIN, so the watch waits and
    /// the re-arm stays owed; the next foreground asks again). No automatic re-arm runs while it is (`performRecoveryReArm`).
    var pinRecoveryPending: Bool {
        #if DEBUG
        if let injected = Self.recoveryPendingForTesting { return injected }
        #endif
        return KeychainService.pendingRecovery != nil || KeychainService.pinPresence == .sealedByLock   // sealed: not known usable (item 155's A5)
    }

    #if DEBUG
    /// A test's answer to whether a PIN recovery is pending; nil reads the Keychain. `TestIsolation.setUp` sets false,
    /// since the Keychain and the test host's own log are shared by every test in the process, and a test of the
    /// recovery itself sets nil.
    nonisolated(unsafe) static var recoveryPendingForTesting: Bool?
    #endif

    /// RootView's launch recovery finished: the existing PIN was entered, or a new one set after device authentication.
    /// `priorLocalEvidence` is the container's own answer unless a test passes one.
    func noteRecoveryFinished(_ recovery: KeychainService.RecoveryKind?,
                              priorLocalEvidence: Bool = EventStore.containerHasPriorEvents) {
        if Self.reinstallRecordOwed(recovery: recovery, priorLocalEvidence: priorLocalEvidence) {
            UserDefaults.standard.set(true, forKey: Self.reinstallRecordOwedKey)
        }
        // The owed automatic re-arm waited for this (item 152's lead 18): run it now, as the entitlement's resolution
        // and the foreground pass do, with the same guards (a launch recovery still waiting runs it itself).
        if state == .disarmed, !launchRecoveryWaiting, UserDefaults.standard.bool(forKey: Self.pendingReArmKey),
           UIApplication.shared.applicationState != .background {
            performRecoveryReArm()
        }
    }

    /// Writes the owed record, once: at a successful Verify iCloud access, where it binds to the verified account and,
    /// with Pro, uploads as a silent fact the owner's other devices see; or at the first watch, where an install that
    /// has not verified keeps it on this phone (a record made before verifying is tied to no account for good). Never
    /// a siren or an alert. The flag is cleared after the write, so a kill between the two writes the record again
    /// rather than never, as for the interruption record (item 144 (d)).
    func writeOwedReinstallRecord() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.reinstallRecordOwedKey) else { return }
        logStateChange("reinstalled")
        defaults.removeObject(forKey: Self.reinstallRecordOwedKey)
    }

    /// The watch's first records: an owed reinstall record, then the explicit "armed" audit entry, once per continuous
    /// watch.
    func logWatchStart() -> Event {
        writeOwedReinstallRecord()
        return logStateChange("armed")
    }
}
