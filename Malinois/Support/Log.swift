//
//  Log.swift
//  Malinois
//
//  Structured diagnostics via OSLog (BACKLOG 7). Replaces print(): levels, categories, and
//  privacy markers, retrievable post-hoc from a sysdiagnose or Console — which is what lets
//  a field issue be debugged from a user's device without a debugger attached.
//
//  Privacy rule: nothing that reaches a log may identify evidence, the PIN, or CloudKit
//  record contents. Sensor names, counts and filenames (UUID-based) are marked public so
//  they survive redaction; everything else stays at OSLog's private default. Error text is
//  split (ninth review, R1-L3): `Log.ref` (domain#code) is public — always diagnosable —
//  while the full description is `.private`, because CKError text can embed record/zone
//  IDs carrying event UUIDs, which would otherwise reach any sysdiagnose. Private text is
//  still visible live in Xcode's console, so the on-device incident workflow (ADR 0004's
//  diagnosis) keeps working during development.
//

import Foundation
import OSLog

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.johncompton.Malinois"

    /// App lifecycle, push registration.
    static let app    = Logger(subsystem: subsystem, category: "app")
    /// The monitoring state machine: arming, capture, sensors.
    static let engine = Logger(subsystem: subsystem, category: "engine")
    /// The on-device evidence store.
    static let store  = Logger(subsystem: subsystem, category: "store")
    /// CloudKit exfiltration and subscriptions.
    static let cloud  = Logger(subsystem: subsystem, category: "cloud")
    /// The alarm player.
    static let siren  = Logger(subsystem: subsystem, category: "siren")
    /// Camera session plumbing — in particular the vision tap, whose failure mode is
    /// silence (frames simply never arrive), so it has to say what happened out loud.
    static let camera = Logger(subsystem: subsystem, category: "camera")

    /// Pure (unit-tested): the public, identifier-free half of an error log line —
    /// "domain#code" (e.g. "CKErrorDomain#4"). Log this `.public` and the description
    /// `.private` (R1-L3): the code alone classifies the failure in any sysdiagnose,
    /// while identifier-bearing text stays redacted.
    static func ref(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }
}
