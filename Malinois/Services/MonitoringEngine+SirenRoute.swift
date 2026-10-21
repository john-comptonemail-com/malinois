//
//  MonitoringEngine+SirenRoute.swift
//  Malinois
//
//  Fable's fable-2 on 1.8 (75) (BACKLOG 141; ADR 0053): the siren plays wherever the iPhone's sound goes, so with
//  headphones or a Bluetooth device connected it is not heard in the room. The countdown says so while it is true.
//  Kept apart from MonitoringEngine.swift, which sits at the lint size limits.
//

import Foundation

extension MonitoringEngine {
    /// Recomputes the countdown's warning that the siren would play away from this iPhone: Siren mode only. Sampled with
    /// the volume warning and at each tick of the countdown, so it comes and goes with the headphones.
    func refreshSirenRouteWarning() {
        guard settings.responseMode == .siren else {
            if sirenRouteWarning != nil { sirenRouteWarning = nil }
            return
        }
        #if DEBUG
        let outputs = sirenOutputsForTesting ?? SirenPlayer.currentOutputs()
        #else
        let outputs = SirenPlayer.currentOutputs()
        #endif
        let warning = SirenPlayer.awayWarning(outputs: outputs)
        if warning != sirenRouteWarning { sirenRouteWarning = warning }
    }
}
