//
//  WatchAlertMessage.swift
//  Malinois
//
//  One alert the armed iPhone sends straight to its paired Apple Watch (item 57, ADR 0043). Shared
//  by the iPhone app and the watch app; pure and Foundation-only.
//

import Foundation

/// The alert and nothing more: which of the iCloud alerts' fixed texts to show, the event's ID (so
/// the watch shows each event once however often it arrives) and when it happened. No device, sensor
/// or evidence detail leaves the iPhone this way.
struct WatchAlertMessage: Equatable, Sendable {
    enum Kind: String, Sendable { case tamper, disarm }

    let kind: Kind
    let eventID: UUID
    let at: Date

    init(kind: Kind, eventID: UUID, at: Date) {
        self.kind = kind
        self.eventID = eventID
        self.at = at
    }

    /// The WatchConnectivity payload: property-list values only.
    var userInfo: [String: Any] {
        ["malinoisAlert": kind.rawValue, "id": eventID.uuidString, "at": at.timeIntervalSinceReferenceDate]
    }

    /// A payload this app sent, or nil for anything else.
    init?(userInfo: [String: Any]) {
        guard let raw = userInfo["malinoisAlert"] as? String, let kind = Kind(rawValue: raw),
              let idText = userInfo["id"] as? String, let id = UUID(uuidString: idText),
              let seconds = userInfo["at"] as? Double else { return nil }
        self.init(kind: kind, eventID: id, at: Date(timeIntervalSinceReferenceDate: seconds))
    }

    var title: String { "Malinois" }

    /// The iCloud alerts' own texts; a test keeps them equal to the subscriptions'.
    var body: String {
        switch kind {
        case .tamper: "Tamper detected on your device."
        case .disarm: "Malinois was disarmed on one of your devices."
        }
    }

    /// A relayed alert arriving more than this long after its event says when the event happened:
    /// a copy that waited for the watch to come back in range must not read as a new event.
    static let lateAfter: TimeInterval = 60

    /// The text the watch shows: the iCloud alert's fixed text when on time; when late, the same
    /// text with the event's time ("... at 9:04 PM."), and its date if that was another day.
    /// Alert text: no em-dash (B16).
    func body(deliveredAt now: Date) -> String {
        guard now.timeIntervalSince(at) > Self.lateAfter else { return body }
        let time = at.formatted(date: .omitted, time: .shortened)
        let when = Calendar.current.isDate(at, inSameDayAs: now)
            ? time
            : "\(at.formatted(.dateTime.month(.abbreviated).day())), \(time)"
        return "\(body.dropLast()) at \(when)."
    }

    /// Whether the watch shows this alert Time Sensitive (the owner's ruling, 2026-10-12; ADR 0045):
    /// the tamper alert breaks through Focus and Sleep, as on the iPhone; the disarm alert does not.
    var isTimeSensitive: Bool { kind == .tamper }

    /// One alert per event: a repeated delivery is recognized rather than shown again.
    var notificationIdentifier: String { "malinois-relay-\(kind.rawValue)-\(eventID.uuidString)" }
}
