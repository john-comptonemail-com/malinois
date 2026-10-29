//
//  AlertBurst.swift
//  MalinoisNotificationService
//
//  A burst of tamper alerts arrives quietly after its first three (BACKLOG 163's step 16, item 153's MAL-04; ADR 0061).
//  After "Delete Data from iCloud" the phone uploads its records again and each one fires the tamper subscription: on
//  the owner's iPad, one Time Sensitive alert per record, 334 of them (check C on 1.8.1, 2026-10-27). The alert
//  extensions cannot tell a re-upload from a trip, since they read no record (ADR 0039), and marking the records would
//  change what the pushes carry, which in 1.6 stopped them (ADR 0046); so each alert path counts the tamper alerts it
//  has seen arrive, in a short record of its own (item 169's codex-3: the notification list it first counted is emptied
//  by the owner's clearing and, on the watch, by the app's own tidy-up). Compiled into the iPhone's and the watch's
//  alert extensions, the watch app and the iPhone app's tests. Pure but for the record's reads and writes of defaults.
//

import Foundation

/// When a tamper alert is one of many arriving at once (ADR 0061).
enum AlertBurst {
    /// How many tamper alerts within `window` start a burst; they alert as before.
    static let size = 3
    /// The span that `size` alerts must fall within to start a burst.
    static let window: TimeInterval = 60
    /// A burst lasts while each tamper alert follows the one before by less than this: longer than the longest wait the
    /// sending phone's upload queue makes between passes (two minutes), so that one re-upload stays one burst.
    static let gap: TimeInterval = 150

    /// How long the record of arrivals keeps one, and how many it keeps (item 169's codex-3): well past `gap`.
    static let memory: TimeInterval = 3600
    static let memoryLimit = 50
    /// Where each alert path keeps its record of tamper arrivals, in its own defaults (item 169's codex-3).
    static let arrivalsKey = "com.malinois.alertBurst.arrivals"

    /// Pure (unit-tested; item 169's codex-3): the record after an arrival at `now`: the arrivals still within `memory`
    /// of it, none dated after it, then this one, at most `memoryLimit` kept.
    static func remembering(_ now: Date, in arrivals: [Date]) -> [Date] {
        Array((arrivals.filter { $0 <= now && now.timeIntervalSince($0) < memory } + [now]).suffix(memoryLimit))
    }

    /// The record kept in `defaults` under `key` (each alert path's own; item 169's codex-3): adds an arrival at `now`
    /// (`arrive`) and returns the record as it stood before, for the extensions' decision.
    static func recordArrival(at now: Date, defaults: UserDefaults, key: String) -> Record {
        let before = record(defaults: defaults, key: key)
        commit(arrive(now, after: before).record, defaults: defaults, key: key)
        return before
    }

    /// Where an earlier 1.8.2 build kept the running burst's last apart from the arrivals (item 170's codex-5): read
    /// from a record in that form, and removed when the record is next written (item 171's codex-2).
    static func burstKey(_ key: String) -> String { key + ".burstLast" }

    /// A path's record as it stands: the arrivals kept, and the running burst's last, if one runs.
    struct Record: Equatable {
        var arrivals: [Date]
        var burstLast: Date?
    }

    /// Pure (unit-tested; items 170's codex-5 and 171's codex-1): whether an arrival at `now` comes quietly, and the
    /// record after it. A burst starts by the record (`isQuiet`: the fourth of a run whose three came within `window`)
    /// and then lasts while each arrival follows the burst's last by less than `gap`, however long it runs: the
    /// record's bounds (an hour, fifty) cannot end it. An arrival dated before any the record holds means the clock
    /// moved back: nothing in the record can be measured against it, so the record starts afresh from it, and it taps.
    static func arrive(_ now: Date, after before: Record) -> (quiet: Bool, record: Record) {
        let latest = (before.arrivals + [before.burstLast].compactMap { $0 }).max()
        if let latest, latest > now { return (false, Record(arrivals: [now], burstLast: nil)) }
        let continuing = before.burstLast.map { now.timeIntervalSince($0) < gap } ?? false
        let quiet = continuing || isQuiet(earlierArrivals: before.arrivals, now: now)
        return (quiet, Record(arrivals: remembering(now, in: before.arrivals), burstLast: quiet ? now : nil))
    }

    /// The record kept in `defaults` under `key` (each path's own), as it stands: one value, its arrivals and its burst
    /// together (item 171's codex-2). A record in the earlier form, a list of arrivals with the burst's last under
    /// `burstKey`, reads the same.
    static func record(defaults: UserDefaults, key: String) -> Record {
        func dates(_ value: Any?) -> [Date] { (value as? [Double] ?? []).map(Date.init(timeIntervalSince1970:)) }
        func date(_ value: Any?) -> Date? { (value as? Double).map(Date.init(timeIntervalSince1970:)) }
        if let stored = defaults.dictionary(forKey: key) {
            return Record(arrivals: dates(stored["arrivals"]), burstLast: date(stored["burstLast"]))
        }
        return Record(arrivals: dates(defaults.array(forKey: key)), burstLast: date(defaults.object(forKey: burstKey(key))))
    }

    /// Writes `record` under `key` as one value, so no write keeps its arrivals without its burst (item 171's codex-2),
    /// and drops the earlier form's separate key.
    static func commit(_ record: Record, defaults: UserDefaults, key: String) {
        var stored: [String: Any] = ["arrivals": record.arrivals.map(\.timeIntervalSince1970)]
        if let burstLast = record.burstLast { stored["burstLast"] = burstLast.timeIntervalSince1970 }
        defaults.set(stored, forKey: key)
        defaults.removeObject(forKey: burstKey(key))
    }

    /// The words of a tamper alert that arrives quietly (item 163's step 16, the owner's "16 - 1", 2026-10-27).
    static let quietBody = "Tamper detected on your device - one of many alerts arriving at once. The Event Log has each one."

    /// Pure (unit-tested). Whether a tamper alert arriving `now` comes quietly, given when the path's earlier tamper
    /// alerts arrived, by its record: once `size` have come within `window`, the rest come quietly while each follows the
    /// one before by less than `gap`. `arrive` adds the running burst and a clock moved back.
    static func isQuiet(earlierArrivals: [Date], now: Date) -> Bool {
        // The run this alert joins: back from now, each arrival less than `gap` before the next.
        var run: [Date] = []
        var next = now
        for arrival in earlierArrivals.filter({ $0 <= now }).sorted(by: >) {
            guard next.timeIntervalSince(arrival) < gap else { break }
            run.append(arrival)
            next = arrival
        }
        guard run.count >= size else { return false }
        // It is a burst once `size` of them came within `window`.
        let oldestFirst = Array(run.reversed())
        return (0...(oldestFirst.count - size)).contains { start in
            oldestFirst[start + size - 1].timeIntervalSince(oldestFirst[start]) <= window
        }
    }
}
