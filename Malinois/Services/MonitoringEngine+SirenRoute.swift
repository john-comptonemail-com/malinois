//
//  MonitoringEngine+SirenRoute.swift
//  Malinois
//
//  Where the siren plays (1.8.2's step 26, item 155's A12; ADR 0062, in place of ADR 0053's countdown warning): in
//  Siren mode from this iPhone's speaker whatever is connected, and an alarm that plays anywhere else is logged. Kept
//  apart from MonitoringEngine.swift, which sits at the lint size limits.
//

import Foundation

extension MonitoringEngine {
    /// Whether an alarm sounded now plays from this iPhone's speaker: in Siren mode. The suspected-attack alarm in Alert
    /// and Stealth keeps the playback setting, which plays wherever the iPhone's sound goes (the owner's ruling,
    /// 2026-10-28).
    var sirenOnSpeaker: Bool { settings.responseMode == .siren }

    /// Logs where an alarm played when that was not this iPhone's speaker: a status entry, silent on the other devices as
    /// every status entry is. The siren tells it once an alarm (`SirenPlayer.onPlayingElsewhere`).
    func noteSirenPlayedElsewhere(_ output: SirenOutput) {
        logStateChange(Event.sirenElsewhereKind(device: output.name))
    }

    #if DEBUG
    /// Test-only (1.8.2's step 26): where the siren plays, in place of iOS's route (the siren's own seam).
    var sirenOutputsForTesting: [SirenOutput]? {
        get { siren.outputsForTesting }
        set { siren.outputsForTesting = newValue }
    }
    #endif
}
