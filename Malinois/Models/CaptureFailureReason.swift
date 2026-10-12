//
//  CaptureFailureReason.swift
//  Malinois
//
//  Why a capture produced no media (item 54). On its own, with nothing but Foundation, so the
//  alert extension can compile `Event` and word an alert the way the Event Log words the record
//  (item 76). The mappings from the camera's own errors stay in EvidenceCapturePipeline.swift.
//

import Foundation

/// Why a capture produced no media — the record's honest "why" (item 54). Raw values ride
/// `Event.captureFailure` and the cloud payload, allow-listed on the way back in.
enum CaptureFailureReason: String, Sendable, CaseIterable {
    /// Camera permission is denied in iOS Settings.
    case unauthorized
    /// The session could not be configured for the requested lens.
    case cameraUnavailable
    /// The bounded warm-up gave up (34's H10 deadline).
    case warmUpTimedOut
    /// The shot or clip itself failed, with no interruption seen.
    case captureFailed
    /// Whole-attempt clock expired; shutdown may still be queued.
    case captureTimedOut
    /// A previous camera worker still owns the device after a deadline.
    case cameraBusy
    /// Saved footage ended early or the recording delegate reported incomplete output.
    case clipPartial
    /// Bytes are preserved but playable/completed footage could not be established.
    case clipUnverified
    case interruptedInBackground
    case interruptedByAnotherApp
    case interruptedByAudioClient
    case interruptedBySystemPressure
    /// Interrupted for a reason this build does not know.
    case interrupted
    /// The media could not be written to the store.
    case storageFailed
    /// The owner disarmed while the shot or clip was in flight; the disarm stopped the
    /// camera, so there is nothing to report as a fault (item 63 leg 6 on 1.3 (39)).
    case disarmed

    /// An interruption-class failure is the one the engine retries once when the
    /// interruption ends (item 54); the others have nothing to wait for.
    var isInterruption: Bool {
        switch self {
        case .interruptedInBackground, .interruptedByAnotherApp, .interruptedByAudioClient,
             .interruptedBySystemPressure, .interrupted:
            return true
        case .unauthorized, .cameraUnavailable, .warmUpTimedOut, .captureFailed, .storageFailed,
             .captureTimedOut, .cameraBusy, .clipPartial, .clipUnverified,
             .disarmed:
            return false
        }
    }

    /// Owner-facing wording for the record.
    var summary: String {
        switch self {
        case .unauthorized:                return "camera access is denied in iOS Settings"
        case .cameraUnavailable:           return "the camera could not be started"
        case .warmUpTimedOut:              return "the camera did not start in time"
        case .captureTimedOut:             return "the camera response timed out; recovery may still be pending"
        case .cameraBusy:                  return "the camera is still recovering from an earlier capture"
        case .clipPartial:                 return "partial footage was saved; recording ended early or incompletely"
        case .clipUnverified:              return "the original file was saved, but its recording could not be fully verified"
        case .captureFailed:               return "the camera failed while capturing"
        case .interruptedInBackground:     return "iOS took the camera away because the app was no longer in the foreground"
        case .interruptedByAnotherApp:     return "another app was using the camera"
        case .interruptedByAudioClient:    return "another app was using the microphone"
        case .interruptedBySystemPressure: return "iOS shed the camera under system pressure (heat or load)"
        case .interrupted:                 return "the camera session was interrupted"
        case .storageFailed:               return "the capture could not be written to storage"
        case .disarmed:                    return "monitoring was disarmed during the capture"
        }
    }
}
