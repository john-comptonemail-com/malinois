//
//  Heartbeat.swift
//  Malinois
//
//  The heartbeat (item 52): while a watch is live on Pro, the phone sends a small encrypted record
//  to its owner's iCloud every few minutes, so another of the owner's devices can tell when it
//  was last heard from, and a silence becomes a fact with a time: "armed 14:02, heard from until
//  14:37, nothing after" is a dark moment on the record (a restart, a Faraday bag, destruction),
//  readable even if this phone never comes back.
//

import Foundation

/// One beat.
struct HeartbeatBeat: Equatable, Sendable {
    /// The session: the id of the watch's "armed" audit record, which is how a reader looking at
    /// that record finds its beats.
    let session: UUID
    /// 1 for the beat at go-live, then one more per interval. A beat that cannot be sent is
    /// dropped, never sent late, so a gap in the numbers is a gap in the trail.
    let sequence: Int
    let deviceName: String
    /// 0 to 1, or nil when iOS does not know it.
    let batteryLevel: Double?
    let charging: Bool
    /// iOS's thermal state as the beat went out, in the tamper records' words (nominal, fair,
    /// serious, critical; item 52's follow-up 1, from item 38), or nil for a state a later iOS
    /// adds. Context for a phone that went quiet: heat can shut one down.
    var thermalState: String? = nil
}

/// When another phone was last heard from, as the reader found it.
enum LastHeard: Equatable, Sendable {
    /// The server's time of the session's latest beat.
    case at(Date)
    /// No beat on record for the session (a phone on 1.3.x, the free tier, or offline throughout).
    case never
    /// iCloud could not be asked.
    case unknown
}

/// A watch this phone ran with the heartbeat, kept until the retention pass has trimmed its
/// trail (item 52's follow-up 2): its session (the arm record's id) and when it began. Kept
/// apart from the event log, whose cap drops an old watch's arm record before it comes due.
struct BeatSession: Codable, Equatable, Sendable {
    let id: UUID
    let start: Date
}

/// What one watch's trim came to (item 52's follow-up 2).
enum BeatTrimOutcome: Equatable, Sendable {
    /// Nothing of the trail is left: deleted, already gone, or the watch never beat.
    case trimmed
    /// The watch's last beat is newer than the cutoff: its trail waits for a later pass.
    case notYet
    /// iCloud could not be asked, or a delete failed: asked again at a later pass.
    case failed
}

/// A beat record as a trim reads it (item 52's follow-up 2): the server's time of it and the
/// number it carries, each nil when the record came back without it.
struct FetchedBeat: Equatable, Sendable {
    let modified: Date?
    let sequence: Int?
}

/// What one watch's latest record tells a trim to do (item 52's follow-up 2).
enum BeatTrimStep: Equatable, Sendable {
    /// Stop here, with this outcome.
    case stop(BeatTrimOutcome)
    /// Look at the numbers past the latest record's, then delete the trail from 1 through this.
    case deleteThrough(Int)
}

/// What a trim found at one number past the latest record's (item 52's follow-up 2): the two
/// records of a beat save separately, so a watch's last beats may have trail records its latest
/// record never counted.
enum BeatTailRecord: Equatable, Sendable {
    /// No such record, the usual answer.
    case absent
    /// A beat the latest record never counted, and the server's time of it.
    case at(Date)
    /// Its fetch failed.
    case unreadable
}

/// The heartbeat's pure rules (unit-tested).
enum Heartbeat {
    /// Whether a beat goes out now: a Pro session, online.
    static func beatAllowed(sessionPro: Bool, online: Bool) -> Bool {
        sessionPro && online
    }

    /// iOS's battery level as a beat carries it: nil when iOS does not know it (it says -1).
    static func batteryLevel(fromIOS level: Float) -> Double? {
        level < 0 ? nil : Double(level)
    }

    /// Whether an Event Log record shows when its phone was last heard from: an arm record from
    /// another phone, on Pro.
    static func showsLastHeard(for event: Event, pro: Bool) -> Bool {
        pro && event.stateChange == "armed" && event.isMirrored
    }

    /// The detail row's words (nil: the reader has not answered yet).
    static func lastHeardText(_ heard: LastHeard?) -> String {
        switch heard {
        case .at(let date)?: return date.formatted(date: .abbreviated, time: .standard)
        case .never?:        return "No heartbeat on record"
        case .unknown?:      return "Could not check iCloud"
        case nil:            return "Checking iCloud"
        }
    }
}

/// Shared storage for this phone's heartbeat-cleanup registry. EventStore seeds a
/// readable legacy log before count migration can discard arm rows; the engine uses
/// the same keys and one-time marker when registering watches or trimming trails.
@MainActor
enum BeatSessionRegistry {
    private static let sessionsKey = "com.malinois.beats.sessions"
    private static let seededKey = "com.malinois.beats.sessionsSeeded"

    static func read() -> [BeatSession] {
        guard let data = UserDefaults.standard.data(forKey: sessionsKey),
              let sessions = try? JSONDecoder().decode([BeatSession].self, from: data) else { return [] }
        return sessions
    }

    @discardableResult
    static func save(_ sessions: [BeatSession]) -> Bool {
        guard let data = try? JSONEncoder().encode(sessions) else { return false }
        UserDefaults.standard.set(data, forKey: sessionsKey)
        return true
    }

    /// Pure: add only first-hand armed records not already registered.
    nonisolated static func addingLegacyWatches(_ sessions: [BeatSession], from events: [Event]) -> [BeatSession] {
        let known = Set(sessions.map(\.id))
        let fromLog = events
            .filter { $0.stateChange == "armed" && !$0.isMirrored && !known.contains($0.id) }
            .map { BeatSession(id: $0.id, start: $0.startDate) }
        return sessions + fromLog
    }

    /// Call only after the store successfully read its complete on-disk log. Do not
    /// mark a sealed or fresh log as migrated; unlock will retry with the real history.
    static func seedIfNeeded(from events: [Event]) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: seededKey) else { return }
        guard save(addingLegacyWatches(read(), from: events)) else { return }
        defaults.set(true, forKey: seededKey)
    }
}
