//
//  MonitoringEngine+ClockWatch.swift
//  Malinois
//
//  Item 113 (from item 108, F4): a clock jump during a live watch leaves a quiet status entry. Kept
//  apart from MonitoringEngine.swift, which sits at the lint size limits.
//

import Foundation

extension MonitoringEngine {
    /// Times the watch from go-live against a clock no setting can move (`ClockWatch`).
    func startClockWatch() {
        clockWatch.start { [weak self] seconds in self?.recordClockChange(seconds) }
    }

    /// A jump the clock watch saw. Like the heat warnings it rides the silent audit type, never a
    /// siren or a cross-device alert: an automatic time correction looks the same as a deliberate
    /// change. Recorded only while a watch is live (the owner's ruling: nothing while disarmed).
    func recordClockChange(_ seconds: Int) {
        guard armedSince != nil else { return }
        logStateChange(Event.clockChangeKind(seconds: seconds))
    }
}
