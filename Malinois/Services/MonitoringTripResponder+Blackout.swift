// Trip coordination owned by MonitoringTripResponder.
import Foundation
import UIKit
import OSLog

extension MonitoringTripResponder {

    /// The frame grab for a blackout record already in the log, pushed under the cloud
    /// authorization decided with that record (P-01's live-session no-downgrade).
    func captureBlackoutEvidence(for logged: Event, cloudAllowed sessionAllowed: Bool) async {
        let session = armSession
        var event = logged

        if settings.isEnabled(.camera),
           Self.mayRunCadenceCapture(handlingTrigger: isHandlingTrigger,
                                     capturingUntilClear: isCapturingUntilClear,
                                     cadenceBusy: cadenceCaptureBusy) {
            cadenceCaptureBusy = true
            defer { cadenceCaptureBusy = false }
            let cam: CameraChoice
            switch effectiveCameraPosition {
            case .rear: cam = .rear
            case .auto: cam = resolveAutoCamera()
            default:    cam = .front   // front / both → a single grab is enough here
            }
            // A still by construction (ADR 0003): a frame answers this record's purpose, and
            // a still cannot contend for the movie output. In practice the blackout already
            // forces stills via the escalation (F4); this makes it structural, not incidental.
            let outcome = await capturePipeline.capture(from: cam, mode: .photo, illumination: settings.illumination, preservation: .init(event: event, store: eventStore))
            if let cap = outcome.capture, let stored = await eventStore.store(cap.source, ext: cap.ext,
                    attachingTo: event, camera: cap.camera.rawValue) {
                event.mediaFilename = stored.filename
                event.primaryCamera = cam.rawValue
                event.thumbnailData = stored.thumbnail
            } else {
                event.captureFailure = (outcome.failure ?? .storageFailed).rawValue   // the why, on the record (54)
            }
            event.endDate = Date()
            eventStore.updateAndReopenForReupload(event)   // the same for the blackout still (item 155's A1), in one write (S1)
            #if DEBUG
            await captureStoredForTesting?(event.id)
            #endif
            // Only this watch may stand its camera down. Storage may have suspended while
            // the owner disarmed and started a replacement watch.
            if session == armSession { standDownCameraIfNeeded() }
        } else if settings.isEnabled(.camera) {
            // A trigger capture owns the camera (34.H10) — the blackout RECORD above stands
            // either way; only the frame grab yields.
            Log.engine.info("Blackout frame skipped — a trigger capture owns the camera")
        }
        // Re-read the stored copy (monotonic-field preservation, sixth-review F2) and push
        // under the authorization decided at creation.
        let ev = eventStore.events.first { $0.id == event.id } ?? event
        exfiltrateInBackground(ev, cloudAllowedOverride: sessionAllowed)   // .localOnly now; retried on reconnect
    }
}
