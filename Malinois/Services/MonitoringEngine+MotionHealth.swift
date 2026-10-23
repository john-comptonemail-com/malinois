//
//  MonitoringEngine+MotionHealth.swift
//  Malinois
//
//  The Motion tripwire's stall record (BACKLOG 144 (g), item 145 step 5): the first time a live watch's motion stream
//  stalls and is restarted, the log gets a quiet status entry. Kept apart from MonitoringEngine.swift, which sits at
//  the lint size limit.
//

import Foundation

extension MonitoringEngine {
    /// The Motion tripwire's monitor, with its stall reports wired to the log.
    func makeMotionMonitor() -> MotionMonitor {
        let motion = MotionMonitor()
        motion.onStall = { [weak self] count in self?.handleMotionStall(count: count) }
        return motion
    }

    /// A stall the monitor has already answered by restarting its stream (BACKLOG 5). Every stall goes to the system
    /// log; the first of a live watch also leaves a status entry in the owner's log. Like the Sound and heat records,
    /// it rides the silent audit type: never a siren or a cross-device alert, since a stall comes from iOS (a throttle
    /// under pressure, an interruption nothing reports), not from someone handling the phone.
    func handleMotionStall(count: Int) {
        Log.engine.warning("Motion stream stalled while watching (#\(count)); restarted")
        guard armedSince != nil, Self.motionStallRecordDue(count: count) else { return }
        logStateChange("motionStalled")
    }

    /// Pure (unit-tested): whether a stall report writes the record. Only the first of a watch: the monitor counts
    /// afresh at each start, and a stream that keeps stalling would otherwise fill the status history.
    nonisolated static func motionStallRecordDue(count: Int) -> Bool { count == 1 }
}
