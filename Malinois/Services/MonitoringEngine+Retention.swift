//
//  MonitoringEngine+Retention.swift
//  Malinois
//
//  Item 114 (from item 108, F5): when the event limit removes evidence this phone was meant to upload
//  and had not, the log keeps a quiet status entry saying so. Kept apart from MonitoringEngine.swift,
//  which sits at the lint size limits. The store's side, uploads in flight, is in EventStore.
//

import Foundation

extension MonitoringEngine {
    /// Hears the store's event-limit removals, once the Pro check has answered (until then the
    /// store keeps them; item 116, R6), each with the watch it was made in (N2).
    func watchCountEvictions() {
        eventStore.evictionWatch = { [weak self] in self?.armedSince }
        eventStore.onCountEviction = { [weak self] removed, watch in self?.noteCountEviction(removed, inWatch: watch) }
    }

    /// `noteCountEviction(_:inWatch:)` for a removal made now, in the watch under way.
    func noteCountEviction(_ removed: [Event]) { noteCountEviction(removed, inWatch: armedSince) }

    /// Records, once per watch (once a day while disarmed), that the event limit removed events
    /// this phone was meant to upload. `watch` is the watch the removal was made in, read when it
    /// was made: a disarm before this runs leaves it a loss of that watch (item 116, N2). Pro only
    /// (read now, when the Pro check has answered): a free install's events never go to iCloud, so
    /// removal at the limit is ordinary retention there. Like the heat warnings, a silent status
    /// entry: never a siren or a cross-device alert.
    func noteCountEviction(_ removed: [Event], inWatch watch: Date?) {
        guard entitlements.proActive || armedPro else { return }
        let missed = Self.missedUploads(in: removed) { [cloud] in cloud.enrollment.uploadHoldReason(for: $0) }
        let now = Date()
        guard !missed.isEmpty,
              Self.unsyncedRemovalMarkerIsDue(last: lastUnsyncedRemovalMarker, armedSince: watch, now: now)
        else { return }
        lastUnsyncedRemovalMarker = (now, watch)
        Log.store.warning("The event limit removed \(missed.count, privacy: .public) event(s) not fully backed up to iCloud")
        logStateChange("unsyncedRemoved")
    }

    /// Pure (unit-tested): the removed events this phone was meant to upload. First-hand records not
    /// yet synced count, pending or waiting for iCloud verification, status entries and interruptions
    /// included since 1.8.2 (item 169's codex-1); floods (expendable by design), mirrors and events
    /// held for good (no verified account, a different account, recorded while iCloud backup was off)
    /// do not.
    nonisolated static func missedUploads(in removed: [Event],
                                          holdReason: (Event) -> CloudEnrollment.UploadHoldReason?) -> [Event] {
        removed.filter { event in
            guard event.mayBeAMissedUpload else { return false }   // the store keeps these for us too (item 116, Q1)
            switch holdReason(event) {
            case .unknownAccount?, .differentAccount?, .backupOff?: return false   // held for good
            default: return true
            }
        }
    }

    /// Pure (unit-tested): whether a marker is due. Once per watch while armed; once a day while
    /// disarmed, so a long offline backlog cannot flood the 100 status entries. A last marker later
    /// than now means the clock was moved back: due, rather than waiting out the difference (item
    /// 116, R9).
    nonisolated static func unsyncedRemovalMarkerIsDue(last: (at: Date, watch: Date?)?, armedSince: Date?, now: Date) -> Bool {
        guard let last else { return true }
        if let armedSince { return last.watch != armedSince }
        return now < last.at || now.timeIntervalSince(last.at) >= 86_400
    }

    /// When the last event-limit marker was written, and in which watch. Kept on this device
    /// across launches (item 116, R9), so the daily limit holds when the app is relaunched.
    var lastUnsyncedRemovalMarker: (at: Date, watch: Date?)? {
        get {
            let defaults = UserDefaults.standard
            guard let at = defaults.object(forKey: Self.lastMarkerAtKey) as? Double else { return nil }
            let watch = (defaults.object(forKey: Self.lastMarkerWatchKey) as? Double).map(Date.init(timeIntervalSince1970:))
            return (Date(timeIntervalSince1970: at), watch)
        }
        set {
            let defaults = UserDefaults.standard
            guard let newValue else {
                defaults.removeObject(forKey: Self.lastMarkerAtKey)
                defaults.removeObject(forKey: Self.lastMarkerWatchKey)
                return
            }
            defaults.set(newValue.at.timeIntervalSince1970, forKey: Self.lastMarkerAtKey)
            if let watch = newValue.watch {
                defaults.set(watch.timeIntervalSince1970, forKey: Self.lastMarkerWatchKey)
            } else {
                defaults.removeObject(forKey: Self.lastMarkerWatchKey)
            }
        }
    }

    nonisolated static let lastMarkerAtKey = "com.malinois.retention.lastUnsyncedMarker.at"
    nonisolated static let lastMarkerWatchKey = "com.malinois.retention.lastUnsyncedMarker.watch"
}
