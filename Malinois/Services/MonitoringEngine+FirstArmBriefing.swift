//
//  MonitoringEngine+FirstArmBriefing.swift
//  Malinois
//
//  The root-owned writable briefing binding, shared with its arming flow through a narrow host bridge.
//  MonitoringArmingFlow+Briefing owns acknowledgment, countdown choice and the actual timeout.
//

import Foundation

extension MonitoringEngine {
    var armingFirstArmBriefing: FirstArmBriefing.Parts? { firstArmBriefing }
    func armingSetFirstArmBriefing(_ parts: FirstArmBriefing.Parts?) { firstArmBriefing = parts }

    // MARK: - The screen's minute (ADR 0050's decision 8)

}
