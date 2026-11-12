//
//  MonitoringEngine+AuditRecords.swift
//  Malinois
//
//  Item 153's MAL-03 and MAL-05 (1.8.1; ADR 0057). Two things left no trace in the log: a PIN change in Settings, so
//  a PIN-holder could lock the owner out without a record, and Guided Access ending while the watch was live, the
//  earliest sign of its passcode-holder, given while the phone is still online. Both are now quiet status entries on
//  the silent audit type, like "disarmed" and "gaLifted": pushed to the owner's other devices on Pro, no alert.
//  Since item 234 (1.12) a set-aside log's Delete is a third: it removes records and photos from the phone.
//

import Foundation

extension MonitoringEngine {
    /// Settings' Change PIN saved a new PIN (the current one entered first): one "pinChanged" record, written by
    /// `changePIN`. The recovery flows keep their own record ("reinstalled"), or none for a damaged credential
    /// (ADR 0040).
    func notePINChanged() {
        logStateChange("pinChanged")
    }

    /// Settings' Change PIN saves the new PIN through here (item 162's G1): the save and its record are one step, so a
    /// failed save changes nothing and records nothing, and a saved one is on the record before the view goes. `save`
    /// is the Keychain's, or a test's. Returns whether the PIN was saved.
    func changePIN(to pin: String, save: @MainActor (String) -> Bool = KeychainService.setPIN) -> Bool {
        guard save(pin) else { return false }
        notePINChanged()
        return true
    }

    /// The owner's Delete of a set-aside log (item 234's A1; the owner, 2026-11-11: "1"): the store's delete and its
    /// record are one step, as a PIN change and its record are, so the app has no Delete that leaves none. The entry
    /// says when the log was set aside, how many records it could read, and how many photos and clips went with it or
    /// that they were left; it is a status entry like the others, uploaded on Pro and signed with the log. Nothing is
    /// written when nothing was deleted, nor for a log that was gone already.
    @discardableResult
    func deleteSetAsideLog(_ log: SetAsideLog) async -> SetAsideLogDeletion {
        let report = await eventStore.deleteSetAsideLogReporting(log)
        if report.removedLog {
            logStateChange(Event.setAsideDeletedKind(Event.SetAsideDeleted(
                setAsideAt: log.setAsideAt, records: report.records, mediaRemoved: report.mediaRemoved,
                mediaLeft: report.outcome == .deletedMediaLeft)))
        }
        return report.outcome
    }

    /// Guided Access went from on to off while the watch was live (armed, triggered, or the calibration review, when
    /// the sensors already watch; not the countdown): one "guidedAccessEnded" record, written at iOS's notice or at
    /// the resume re-sample. The watch keeps running; a re-sample with the same value records nothing.
    func noteGuidedAccessChange(from wasOn: Bool, to isOn: Bool) {
        guard wasOn, !isOn, state == .armed || state == .triggered || (state == .calibrating && showingCalibrationReview) else { return }   // 155's A6: the review is live
        logStateChange("guidedAccessEnded")
    }
}
