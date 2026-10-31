// Trip coordination owned by MonitoringTripResponder.
import Foundation
import UIKit
import OSLog

extension MonitoringTripResponder {

    /// A wrong PIN on the armed screen's disarm pad (item 49): the attempt to defeat the alarm is
    /// itself evidence. `KeychainService.verify` has already counted it for the lockout, which
    /// this never touches. While a capture is running the attempt joins that record, like any
    /// trip during a capture (the typing is its Touch); otherwise it mints its own record through
    /// the trigger response — the fact first, pushed like any trip, then one front still.
    /// Armed sessions only (the calibration review included, like `handleTrip`): the Home gate
    /// and the other PIN pads stay lockout-only. The alarm and the flash keep their rule —
    /// no fresh alarm or flash while the owner is typing (A-02); a running alarm is kept up.
    func noteWrongDisarmPIN() {
        guard !dryRunActive else { return }
        if state == .triggered || capturePipeline.isCapturingUntilClear {
            // An until-clear recording treats the attempt as activity, like any trip.
            if capturePipeline.isCapturingUntilClear { capturePipeline.noteActivity() }
            tripsDuringCapture[armSession, default: []].insert(.touch)
            wrongPINsDuringCapture[armSession, default: 0] += 1
            extendAlertWindow()
            return
        }
        guard state == .armed || (state == .calibrating && showingCalibrationReview),
              !isHandlingTrigger else { return }
        if showingCalibrationReview { goCovert() }
        isHandlingTrigger = true
        host?.tripEnterTriggeredState()
        tripsDuringCapture[armSession] = nil
        wrongPINsDuringCapture[armSession] = nil
        let startDate = Date()
        host?.tripStampTrigger(at: startDate)
        let session = armSession
        let lifetime = retainHostForFiniteWork()
        Task { defer { lifetime.keepAlive() }; await respond(triggeredSensors: [.touch], startDate: startDate, session: session, wrongPIN: true) }
    }
}
