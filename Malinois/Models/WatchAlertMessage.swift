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
    enum Kind: String, Codable, Sendable { case tamper, disarm }

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

    /// A payload this app sent, or nil for anything else, a time that is not a finite number included
    /// (ADR 0051).
    init?(userInfo: [String: Any]) {
        guard let raw = userInfo["malinoisAlert"] as? String, let kind = Kind(rawValue: raw),
              let idText = userInfo["id"] as? String, let id = UUID(uuidString: idText),
              let seconds = userInfo["at"] as? Double, seconds.isFinite else { return nil }
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

    /// The text the watch shows for an alert shown on its own: the iCloud alert's fixed text with its
    /// event's time, on time or late ("... at 9:04 PM."), and its date if that was another day
    /// (BACKLOG 134, ADR 0051; until 1.8 (73) only when more than a minute late). Alert text: no
    /// em-dash (B16).
    func body(deliveredAt now: Date) -> String {
        "\(body.dropLast()) at \(Self.when(at, now: now))."
    }

    /// A relayed alert whose event is more than this old when the watch handles it is not shown on
    /// its own: the watch sums it up with the others (BACKLOG 134, ADR 0051). A fixed hour.
    static let summarizedAfter: TimeInterval = 3600

    /// Pure (unit-tested). Whether the watch sums this alert up rather than showing it on its own: its
    /// event is more than an hour old at `now`, by the watch's clock. An event time ahead of that clock
    /// counts as new.
    func isSummarized(handledAt now: Date) -> Bool {
        now.timeIntervalSince(at) > Self.summarizedAfter
    }

    /// Pure (unit-tested). An event's time as the watch's texts give it: the time alone on the day
    /// `now` falls on ("9:04 PM"), otherwise with its date ("Oct 15, 3:42 PM").
    static func when(_ date: Date, now: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDate(date, inSameDayAs: now)
            ? time
            : "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    /// Whether the watch shows this alert Time Sensitive (the owner's ruling, 2026-10-12; ADR 0045):
    /// the tamper alert breaks through Focus and Sleep, as on the iPhone; the disarm alert does not.
    var isTimeSensitive: Bool { kind == .tamper }

    /// One alert per event: a repeated delivery is recognized rather than shown again.
    var notificationIdentifier: String { "malinois-relay-\(kind.rawValue)-\(eventID.uuidString)" }
}
