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
