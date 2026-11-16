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
    /// written when nothing was deleted, nor for a log that was gone already. Since 1.13 a note comes first (item 235's
    /// A11): should Malinois be stopped between the delete and its entry, the next launch writes the entry the note owes
    /// (`watchSetAsideDeletesOwed`). The entry is written under the note's ID, and the note goes only once a saved log
    /// holds it (item 243's gpt6-astra-1: retired as the entry was written, stored or not, a note could go while no save
    /// had kept its entry); a Delete that removed nothing owes no entry, and its note goes at once.
    @discardableResult
    func deleteSetAsideLog(_ log: SetAsideLog) async -> SetAsideLogDeletion {
        let owed = eventStore.oweSetAsideDeleteEntry(for: log)
        let report = await eventStore.deleteSetAsideLogReporting(log)
        if report.removedLog {
            logStateChange(Event.setAsideDeletedKind(Event.SetAsideDeleted(
                setAsideAt: log.setAsideAt, records: report.records, mediaRemoved: report.mediaRemoved,
                mediaLeft: report.outcome == .deletedMediaLeft)), id: owed.id)   // its note goes with the save that keeps it
        } else {
            eventStore.retireSetAsideDeleteOwed(owed.id)   // nothing deleted, no entry owed
        }
        return report.outcome
    }

    /// Writes the entries owed by Deletes a launch before was stopped in (item 235's A11), which the store hands over at
    /// launch and at the unlock's reload: each at the moment of its Delete, under its note's ID, with no counts ("...
    /// was deleted; Malinois was stopped before it could count what went with it", the owner's W3).
    func watchSetAsideDeletesOwed() {
        eventStore.onSetAsideDeleteOwed = { [weak self] owed in
            self?.logStateChange(Event.setAsideDeletedKind(Event.SetAsideDeleted(
                setAsideAt: owed.setAsideAt, records: nil, mediaRemoved: nil, mediaLeft: nil)), id: owed.id, at: owed.at)
        }
    }

    /// Settings' "Free up iCloud space..." (the Manual retention mode, Pro): iCloud's full photos and clips of the events
    /// older than `months` are deleted, never newer than 30 days, and since 1.13 the Event Log records it, as it records a
    /// set-aside log's Delete (item 235's A10; the owner's W4): a quiet status entry with the period and how many events'
    /// full media iCloud was asked to delete, and "some couldn't be deleted" when part of it failed. Written once the
    /// purge has sent its deletions; a name with nothing under it counts as deleted there, so the entry counts events, not
    /// files. The daily automatic retention writes none: it follows a setting whose every change is recorded (D4).
    @discardableResult
    func freeUpICloudSpace(monthsOld months: Int) async -> CloudExfiltrator.CloudPurgeResult {
        let result = await cloud.purgeFullMedia(monthsOld: months)
        if result.recordsDeleted > 0 {
            logStateChange(Event.iCloudMediaPurgedKind(Event.ICloudMediaPurged(
                months: months, events: result.eventsExamined, failed: result.failed)))
        }
        return result
    }

    /// Guided Access went from on to off while the watch was live (armed, triggered, or the calibration review, when
    /// the sensors already watch; not the countdown): one "guidedAccessEnded" record, written at iOS's notice or at
    /// the resume re-sample. The watch keeps running; a re-sample with the same value records nothing.
    func noteGuidedAccessChange(from wasOn: Bool, to isOn: Bool) {
        guard wasOn, !isOn, state == .armed || state == .triggered || (state == .calibrating && showingCalibrationReview) else { return }   // 155's A6: the review is live
        logStateChange("guidedAccessEnded")
    }
}
